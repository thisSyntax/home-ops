# traefik-node

Reusable child module that hardens a single Raspberry Pi, installs Docker on
it, and runs Traefik as a reverse-proxy container on it. Called by
`../../external-traefik-deploy` and `../../internal-traefik-deploy` — two
thin root modules, each with its own state, each supplying this module with
one Pi's worth of variables.

This is a **child module** — it has no state or `terraform.tfvars` of its
own and is never applied directly.

## Prerequisites

This module's `module "pi_hardening"` call inherits every prerequisite of
`../pi-hardening` — SSH key trust, passwordless `sudo` (including how to set
it up), Terraform >= 1.5, and the Windows/Git-Bash `bash.exe` path gotcha for
the drift-check scripts. **See that module's own README** for all of it;
none of it is repeated here. On top of that, this module also needs Docker
reachable over SSH once `null_resource.docker` has run — `providers.tf`
computes the `kreuzwerker/docker` provider's connection string as
`"ssh://${var.ssh_user}@${var.static_ip}:22"`, so it's always the same
`ssh_user`/SSH key/host already used everywhere else in this module, with no
separate value to keep in sync.

## Why one Pi per module call, not a `pi_hosts` map

Every other project in this repo (`pi-hardening`, `caddy-deploy`,
`pihole-deploy`) takes a `pi_hosts` map and `for_each`s over it to handle any
number of Pis from one root module. This module can't do that, because it
owns its own `provider "docker" { host = "ssh://..." }` block — and Terraform
providers cannot be created dynamically from a `for_each`/`count`, on either
the provider block itself or the module call that would supply a different
one per instance. That's a hard constraint in Terraform's own language, not
something specific to `kreuzwerker/docker` or fixable with a cleverer
variable shape.

Every other resource in this repo (`null_resource` + `remote-exec` over SSH)
avoids this entirely, because the SSH target lives inside the *resource's*
`connection` block, which is allowed to be computed per `for_each` instance
— it's specifically `provider` blocks that are static-only. Docker hit this
because `kreuzwerker/docker`'s design puts "which Docker daemon" into the
provider config rather than into each resource, since Docker has no
fleet-wide management API the way Proxmox or Azure do.

The practical result: one Pi per directory, each with independent state —
`external-traefik-deploy/` and `internal-traefik-deploy/` — rather than one
`traefik-deploy/` with a `pi_hosts` map.

## What it applies, and in what order

```
module.pi_hardening
  ├─ null_resource.docker
  │    └─ null_resource.traefik_static   ─┐
  │    └─ null_resource.traefik_dynamic  ─┤
  │    └─ null_resource.cf_token         ─┼─ docker_image.traefik ─ docker_container.traefik
  │    └─ null_resource.dashboard_auth    │  (only when dashboard_enabled)
  │    └─ null_resource.dashboard_dynamic─┘  (only when dashboard_enabled)
```

`null_resource.docker` installs Docker via `get.docker.com` and adds
`ssh_user` to the `docker` group (the install script does not do this
automatically). `null_resource.traefik_static` and `.traefik_dynamic` push
`traefik.yml` and each service's dynamic config file over SSH via `file`/
`remote-exec` provisioners rather than the `hashicorp/local` provider's
`local_file`, which writes to wherever Terraform itself runs rather than to
the remote Docker host the container is on. `null_resource.cf_token` pushes
the Cloudflare API token used for ACME DNS-01 (see below) to the Pi the same
way, as a root-owned file — never through `docker_container`'s `env`, so the
token value itself never lands in Terraform state. `docker_image`/
`docker_container` are real typed resources from `kreuzwerker/docker`,
connected to that Pi's daemon over SSH via the module's own
`provider "docker"` block (see `providers.tf`); `docker_image` has an
explicit `depends_on = [null_resource.docker]` since nothing else ties the
two together — without it, nothing guarantees Terraform waits for Docker to
actually finish installing before the provider tries to reach it.

**Why `docker_container.traefik` has an `env` entry nothing reads:**
`traefik.yml` is Traefik's *static* config — read once, at process startup,
never hot-reloaded (only the `dynamic/` directory `providers.file.watch`
covers gets that). Pushing a new `traefik.yml` via `null_resource
.traefik_static` doesn't by itself give `docker_container` any reason to
restart, since none of its own arguments changed. `env` embeds
`traefik_static`'s content hash specifically to fix that: `env` is
`ForceNew` in this provider — changing it destroys and recreates the
container (Docker's API can't mutate a running container's environment in
place), which is what actually gets a changed `traefik.yml` picked up.

## Dashboard: router + basicAuth, not a built-in login

`dashboard_enabled` no longer opens a loopback-only port (8080) for the
dashboard — Traefik v3 has no built-in username/password auth to put behind
it anyway. Instead, when `dashboard_enabled = true`, `traefik.yml.tftpl`
enables the API/dashboard (`api: {}`), and `null_resource.dashboard_dynamic`
renders `templates/dashboard.yml.tftpl` into `dynamic/dashboard.yml` — a
normal file-provider router on `dashboard_hostname`'s `Host()` rule, on the
same `websecure` entrypoint as every proxied service, gated by a `basicAuth`
middleware. `null_resource.dashboard_auth` pushes the credentials file itself
(`dashboard_htpasswd_path`, an `htpasswd`-format `user:hash` file) to
`${config_path}/secrets/dashboard-users` the same way `cf_token` pushes the
Cloudflare token — via the `file` provisioner's `source`, never `content`, so
the hash never becomes Terraform state. The dashboard UI is served at
`/dashboard/` — note the trailing slash; Traefik 404s on `/dashboard` without
it rather than redirecting.

## Certificates: ACME DNS-01 via Cloudflare

`traefik.yml.tftpl`'s ACME resolver uses the DNS-01 challenge
(`dnsChallenge.provider: cloudflare`) rather than HTTP-01. That's what makes
it work for both an internet-facing and a LAN-only Pi: Let's Encrypt
validates domain ownership by looking up a DNS TXT record Traefik creates
via Cloudflare's API, never by connecting to the Pi itself — so
`internal-traefik-deploy` can leave `use_acme = true` and still get a real,
publicly-trusted certificate despite having no inbound port-forward at all.
Every `hostname` handed to this module has to be a real name in a DNS zone
Cloudflare manages, for the same reason (`.internal`-style names don't
work — Cloudflare can't create a TXT record in a zone it doesn't host, and
Let's Encrypt won't issue for a name that isn't publicly registered).

The Cloudflare API token itself never becomes a Terraform *value* beyond a
local file path: `cf_api_token_path` points at a local file containing just
the token, `null_resource.cf_token` copies it to the Pi as a root-owned file
(`chmod 600`) at `${config_path}/secrets/cf-token`, and
`docker_container.traefik` reads it via the `CF_DNS_API_TOKEN_FILE` env var
— every `lego`-based DNS provider (`lego` is what Traefik uses internally
for ACME) accepts a `_FILE`-suffixed variant of its credential env vars that
reads from a path instead of embedding the value, so the token is never a
plain `env` entry and never lands in Terraform state. The real access
boundary this leaves is "root, or anyone in the Pi's `docker` group" —
Docker group membership is root-equivalent regardless of file permissions,
so that group is what actually needs to stay tight, not the file mode alone.

`certificatesResolvers.letsencrypt.acme.storage` points at
`/etc/traefik/acme/acme.json`, not directly under `/etc/traefik` — Traefik
needs to create and rewrite that file itself, including setting its own
`0600` permissions on it, which a read-only mount can't support.
`docker_container.traefik` layers a second `volumes` block mounting just
`${config_path}/acme` read-write inside the otherwise-`read_only = true`
`${config_path}` mount, so only ACME storage gets write access — config,
`dynamic/`, and the Cloudflare token stay locked read-only.

## Known gaps, not yet resolved

- **No drift detection** on `traefik_static`/`traefik_dynamic`/`cf_token`/
  `dashboard_auth`/`dashboard_dynamic` — unlike `pi-hardening`'s file-hash
  `data "external"` + `check` pattern, these `null_resource`s only re-push
  their file when their own `triggers` hash changes; nothing here notices if
  a file drifts on the Pi itself.
- **Docker-published ports bypass UFW.** `pi-hardening`'s `application_ufw_*`
  variables are deliberately *not* passed from either root wrapper, because
  Docker writes its own `iptables` `DNAT`/`FORWARD` rules for published
  container ports that never traverse UFW's `INPUT` chain — a UFW app
  profile for 80/443 here would be a no-op.

## Files

- `main.tf` — the `module "pi_hardening"` call, `null_resource.docker`,
  `null_resource.traefik_static`, `null_resource.traefik_dynamic`
  (`for_each = var.services`), `null_resource.cf_token`,
  `null_resource.dashboard_auth`/`null_resource.dashboard_dynamic`
  (`count = var.dashboard_enabled ? 1 : 0`), `docker_image.traefik`,
  `docker_container.traefik`.
- `providers.tf` — the module's own `provider "docker"` block, host computed
  as `"ssh://${var.ssh_user}@${var.static_ip}:22"` (see above for why the
  provider block has to live here rather than the calling root module).
- `variables.tf` — every input: the hardening fields (`static_ip`, `gateway`,
  `dns`, `interface`, `bootstrap_ip`) plus this module's own (`config_path`,
  `dashboard_enabled`, `dashboard_hostname`, `dashboard_htpasswd_path`,
  `services`, `acme_email`, `use_acme`, `cf_api_token_path`), plus
  pass-through fields for `module.pi_hardening` (`fail2ban_*`,
  `unattended_upgrades_*`, `auto_upgrades_days`, `ssh_user`,
  `ssh_private_key_path`).
- `versions.tf` — `hashicorp/null` and `kreuzwerker/docker`.
- `templates/traefik.yml.tftpl` — static config (entry points, the ACME
  resolver and its Cloudflare `dnsChallenge`, `api: {}` when
  `dashboard_enabled`).
- `templates/dynamic-service.yml.tftpl` — one router + service per file;
  rendered once per `services` entry, since Traefik's file provider watches
  a directory and merges every file it finds there.
- `templates/dashboard.yml.tftpl` — the dashboard's own router + `basicAuth`
  middleware, rendered only when `dashboard_enabled` (see "Dashboard" above).
