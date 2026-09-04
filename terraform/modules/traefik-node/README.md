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
reachable at `docker_host` once `null_resource.docker` has run — the same
`ssh_user`/SSH key is what the `kreuzwerker/docker` provider connects with.

## Why one Pi per module call, not a `pi_hosts` map

Every other project in this repo (`pi-hardening`, `caddy-deploy`,
`pihole-deploy`) takes a `pi_hosts` map and `for_each`s over it to handle any
number of Pis from one root module. This module can't do that, because it
owns its own `provider "docker" { host = var.docker_host }"` — and Terraform
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
  │    └─ null_resource.traefik_static  ─┐
  │    └─ null_resource.traefik_dynamic ─┼─ docker_image.traefik ─ docker_container.traefik
  │                                      ┘
```

`null_resource.docker` installs Docker via `get.docker.com` and adds
`ssh_user` to the `docker` group (the install script does not do this
automatically). `null_resource.traefik_static` and `.traefik_dynamic` push
`traefik.yml` and each service's dynamic config file over SSH via `file`/
`remote-exec` provisioners rather than the `hashicorp/local` provider's
`local_file`, which writes to wherever Terraform itself runs rather than to
the remote Docker host the container is on. `docker_image`/`docker_container`
are real typed resources from `kreuzwerker/docker`, connected to that Pi's
daemon over SSH via the module's own `provider "docker"` block (see
`providers.tf`).

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

## Known gaps, not yet resolved

- **`docker_container`'s `/etc/traefik` volume mount is `read_only = true`**,
  but `traefik.yml`'s ACME resolver writes to `/etc/traefik/acme.json` at
  runtime — Traefik can't actually obtain or renew a cert with this mount as
  currently set.
- **This module only ever configures Let's Encrypt's HTTP-01 challenge** in
  `traefik.yml` (`httpChallenge`), regardless of `use_acme` — that resolver
  block is static, unconditional config, not something the `use_acme` flag
  removes. `use_acme = false` only changes what a *router* asks for: with it
  false, `dynamic-service.yml.tftpl` renders `tls: {}` instead of
  `tls: { certResolver: letsencrypt }`, so the router picks up whatever
  static certificate matches via SNI instead of requesting one from ACME.
  This module doesn't supply that static certificate itself — see
  `internal-traefik-deploy/README.md` for how it generates and pushes one
  via `mkcert`, entirely as that root module's own resource, outside this
  one.
- **No drift detection** on `traefik_static`/`traefik_dynamic` — unlike
  `pi-hardening`'s file-hash `data "external"` + `check` pattern, these two
  `null_resource`s only re-push their file when their own `triggers` hash
  changes; nothing here notices if the file drifts on the Pi itself.
- **Docker-published ports bypass UFW.** `pi-hardening`'s `application_ufw_*`
  variables are deliberately *not* passed from either root wrapper, because
  Docker writes its own `iptables` `DNAT`/`FORWARD` rules for published
  container ports that never traverse UFW's `INPUT` chain — a UFW app
  profile for 80/443 here would be a no-op.

## Files

- `main.tf` — the `module "pi_hardening"` call, `null_resource.docker`,
  `null_resource.traefik_static`, `null_resource.traefik_dynamic`
  (`for_each = var.services`), `docker_image.traefik`,
  `docker_container.traefik`.
- `providers.tf` — the module's own `provider "docker"` block (see above for
  why it has to live here rather than the calling root module).
- `variables.tf` — every input: the hardening fields (`static_ip`, `gateway`,
  `dns`, `interface`, `bootstrap_ip`) plus this module's own
  (`docker_host`, `config_path`, `dashboard_enabled`, `services`,
  `acme_email`, `use_acme`), plus pass-through fields for
  `module.pi_hardening` (`fail2ban_*`, `unattended_upgrades_*`,
  `auto_upgrades_days`, `ssh_user`, `ssh_private_key_path`).
- `versions.tf` — `hashicorp/null` and `kreuzwerker/docker`.
- `templates/traefik.yml.tftpl` — static config (entry points, ACME
  resolver, optional dashboard).
- `templates/dynamic-service.yml.tftpl` — one router + service per file;
  rendered once per `services` entry, since Traefik's file provider watches
  a directory and merges every file it finds there.
