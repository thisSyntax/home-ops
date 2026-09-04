# internal-traefik-deploy

Terraform root module for the LAN-only Traefik Pi. All of the actual logic
(Pi hardening, Docker install, Traefik container) lives in the shared
`../modules/traefik-node` child module this calls — **see that module's own
README** for the dependency graph, known gaps, and why this is a single-Pi
module rather than a `pi_hosts` map like `caddy-deploy`/`pihole-deploy` use.

Applied independently from this directory, with its own state:

```bash
cd terraform/internal-traefik-deploy
cp terraform.tfvars.example terraform.tfvars   # first time only; fill in real values
terraform init
terraform plan
terraform apply
```

## Usage

Unlike `caddy-deploy`/`pihole-deploy`, this directory doesn't have direnv
wired up yet — `terraform.tfvars` lives locally in this directory
(gitignored via the repo's `*.tfvars` rule) rather than at an external
`C:\tfvars\...` path. `terraform.tfvars.example` is the placeholder-only
field reference.

## Certificates: mkcert, not Let's Encrypt

This Pi is LAN-only, so it can't satisfy Let's Encrypt's HTTP-01 challenge
(needs the Pi reachable on port 80 from the public internet — fine for
`external-traefik-deploy`, not for this one). Instead: `use_acme = false` is
set in `terraform.tfvars`, which makes `traefik-node` render every router
with `tls: {}` instead of requesting a cert from ACME (see that module's
README), and this directory's own `null_resource.mkcert` supplies the actual
certificate those routers pick up via SNI matching:

1. Downloads `mkcert` (arm64 Linux build) and generates a certificate
   covering `local.mkcert_domains` directly on the Pi — the CA's private key
   never leaves the Pi, deliberately: it's the one piece of key material
   that could impersonate any hostname trusted on your devices, so it
   doesn't flow through Terraform tooling or a `.tfvars` file at all.
2. Pushes the resulting cert/key into `${config_path}/certs/`, and a
   generated `tls.yml` (from `templates/tls.yml.tftpl`) into
   `${config_path}/dynamic/` alongside the other dynamic config — Traefik's
   file provider merges every file it finds there, regardless of which
   Terraform resource wrote it.

`main.tf`'s `locals.mkcert_domains` derives the covered hostnames directly
from `[for k, v in var.services : v.hostname]` — there's no separate
`mkcert_domains` variable to keep in sync with `services` by hand, so a new
internal hostname only ever needs adding in one place. This can't be a
wildcard (`*.internal`) even though that'd be convenient: NSS (and so
Firefox) rejects any wildcard certificate whose suffix has fewer than two
dots — the same rule that blocks `*.com` — and `.internal` has exactly one,
so `*.internal` is always rejected regardless of intent (see Mozilla bug
806281). Every hostname has to be listed explicitly in the resulting
certificate's SAN.

**Retrieving the CA** (one-time, same idea as `caddy-deploy`'s
`role = "internal"` Caddyfile note about pulling Caddy's own root cert off
its Pi): `mkcert -CAROOT` prints the directory the CA lives in (mkcert
auto-creates it there on first use — no `mkcert -install` step is run by
this module, since nothing browses *from* the Pi itself), then stream the
cert out over the same `ssh` connection rather than `scp` — Windows' native
`scp.exe` has long-standing bugs around the local file it writes to,
especially when invoked from Git Bash, where `cat`-and-redirect avoids the
issue entirely since it only relies on plain `ssh`:

```bash
ssh piuser@<static_ip> 'cat "$(mkcert -CAROOT)/rootCA.pem"' > rootCA.pem
```

**Trusting it, per device:** on Windows, `certutil -addstore -f "ROOT" rootCA.pem`
from an elevated prompt (or double-click the file → *Install Certificate* →
*Local Machine* → *Trusted Root Certification Authorities*). Other
OSes/browsers each have their own trusted-root-store import step — this
repo is Windows-centric so that's the one spelled out here, same as the
Git-Bash-specific notes elsewhere.

If you add a second internal Pi later: it'll generate its *own* separate
mkcert CA unless you deliberately copy this Pi's CA key material to it —
each one trusted separately on every client device, rather than one root
trusted everywhere. An ACME DNS-01 challenge against a real internal DNS
zone is the alternative worth considering if that becomes a problem: it
gets a single cert trusted through the normal public CA chain instead of a
per-Pi local root, at the cost of needing a DNS provider API Traefik can
drive.

## Files

- `main.tf` — the `module "traefik" { source = "../modules/traefik-node" ... }`
  call (forwarding every variable through), `locals.mkcert_domains` (derived
  from `var.services`), and `null_resource.mkcert` (see above).
- `variables.tf` — mirrors `../modules/traefik-node/variables.tf` exactly;
  no directory-specific variables of its own.
- `templates/tls.yml.tftpl` — the static-certificate declaration pushed into
  Traefik's `dynamic/` directory; the only template that lives here rather
  than in `traefik-node`, since it's specific to this Pi's cert strategy.
- `terraform.tfvars.example` — placeholder-only field reference for this
  specific Pi.

No `versions.tf` here — this directory has no resources or `provider` blocks
of its own, so Terraform resolves the required providers transitively
through the module it calls.
