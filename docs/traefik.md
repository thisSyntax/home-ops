# Traefik — design notes

Runbooks: [`traefik-node`](../terraform/modules/traefik-node/README.md),
[`external-traefik-deploy`](../terraform/external-traefik-deploy/README.md),
[`internal-traefik-deploy`](../terraform/internal-traefik-deploy/README.md).

## One Pi per root module, not a `pi_hosts` map

Every other project takes a `pi_hosts` map and `for_each`s over it.
`traefik-node` can't, because it owns a `provider "docker" { host =
"ssh://..." }` block, and Terraform can't create provider configurations
dynamically — not from `for_each`/`count` on the provider, nor on a module
call that would pass a different one per instance. That's a hard language
constraint, not something a cleverer variable shape works around.

The SSH-driven resources avoid it because their target lives in the
*resource's* `connection` block, which may differ per instance; only
`provider` blocks are static. `kreuzwerker/docker` puts "which daemon" in the
provider because Docker has no fleet-wide API the way Proxmox or Azure do
(which is why `k3s-deploy` *can* use one provider plus `for_each`).

Result: `external-traefik-deploy/` and `internal-traefik-deploy/`, each one
Pi with its own state. Their `variables.tf` files are copies of the module's,
because Terraform has no variable inheritance — and a root that doesn't
declare a new object field drops it silently.

## "External" vs "internal"

Purely about which traffic reaches the Pi. The external Pi has a WAN
port-forward (set up on the router, outside Terraform) and sits in the DMZ;
the internal Pi has none, and its hostnames resolve to it only through the
LAN's DNS. Both get certificates the same way.

## Certificates: ACME DNS-01 via Cloudflare

Let's Encrypt validates DNS-01 by looking up a TXT record Traefik creates
through Cloudflare's API — it never connects to the Pi. So the LAN-only Pi
gets a real, publicly trusted certificate with no inbound reachability. The
cost: every hostname must be a real name in a Cloudflare-managed zone;
`.internal`-style names can't be validated.

### The token as a file

`cf_api_token_path` points at a local file holding just the token.
`null_resource.cf_token` copies it to the Pi as a root-owned `0600` file, and
the container reads it through `CF_DNS_API_TOKEN_FILE` — every lego-based DNS
provider (lego is Traefik's ACME library) accepts a `_FILE` variant of its
credential variables. So the token is never a Terraform value or a plain
container `env` entry. The real access boundary is "root, or anyone in the
Pi's `docker` group" — docker group membership is root-equivalent, so that
group is what needs to stay tight.

One token per Pi, so the internet-facing Pi's can be revoked alone.

### ACME storage

`acme.json` lives in `${config_path}/acme`, mounted read-write inside the
otherwise read-only config mount: Traefik must create and rewrite that file
(and set its own `0600` mode), but config, `dynamic/` and the token stay
read-only.

## Why the container has an `env` entry nothing reads

`traefik.yml` is static config — read once at startup, never hot-reloaded
(only the watched `dynamic/` directory is). Pushing a new `traefik.yml`
doesn't change any container argument, so nothing would restart Traefik.
`TRAEFIK_STATIC_CONFIG_HASH` in `env` fixes that: `env` is ForceNew in this
provider, so a changed static config recreates the container.

Dynamic files (routes, the dashboard) are picked up live without a restart.
Rotating the Cloudflare token re-pushes the file but doesn't recreate the
container — hence the manual `docker restart traefik` in the runbook.

## Pushing config with provisioners, not `local_file`

`hashicorp/local`'s `local_file` writes where Terraform runs, not on the Pi
running the container, so config files go over SSH with `file`/`remote-exec`.
`null_resource.docker` installs Docker with `get.docker.com` and adds the SSH
user to the `docker` group — the install script doesn't — so the provider can
reach the daemon over SSH as that user.
`docker_image` has an explicit `depends_on = [null_resource.docker]` —
nothing else guarantees Docker is installed before the provider connects.

## Dashboard: a router, not a published port

Traefik v3 has no built-in dashboard login, so instead of publishing a port
the dashboard is a normal file-provider router (`api@internal`) on
`dashboard_hostname`, on the same 443 entrypoint as everything else, behind
middlewares:

1. `dashboard_allowed_ips` → `ipAllowList` (optional), checked first.
2. `basicAuth` from the htpasswd file, pushed like the Cloudflare token.

On the internet-facing Pi the allow-list matters: anyone reaching the public
IP with the right `Host` header would otherwise get a login prompt. With it,
non-LAN sources get a 403 before authentication. Port-forwarded traffic keeps
its real public source address, so it can't match a LAN range.

## Request headers per route

`services[*].request_headers` renders a `customRequestHeaders` middleware for
that route; an empty value *removes* the header. The use case is Grafana's
auth proxy: an internal-only embed route sets a fixed user header, and
Grafana trusts that header only from the internal Pi's IP. The public Grafana
route on the external Pi blanks the header too, as defence in depth — the IP
whitelist already rejects it.

Routes without headers must render byte-for-byte as before; otherwise every
route on both Pis is replaced at once. See
[lessons-learned.md](lessons-learned.md).
