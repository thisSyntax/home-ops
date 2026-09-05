# internal-traefik-deploy

Terraform root module for the LAN-only Traefik Pi. All of the actual logic
(Pi hardening, Docker install, Traefik container) lives in the shared
`../modules/traefik-node` child module this calls — **see that module's own
README** for the dependency graph, known gaps, and why this is a single-Pi
module rather than a `pi_hosts` map like `caddy-deploy`/`pihole-deploy` use.

Applied independently from this directory, with its own state:

```bash
cd terraform/internal-traefik-deploy   # .envrc auto-loads here (Git Bash + direnv)
terraform init
terraform plan
terraform apply
```

## Usage

Real values (including the Cloudflare API token path) live **outside this
repo** at `C:\tfvars\internal-traefik-deploy.tfvars`, loaded the same way
`caddy-deploy`/`pihole-deploy` do — this directory's `.envrc` sets
`TF_CLI_ARGS_plan`/`TF_CLI_ARGS_apply` to point at it, auto-loaded by
[direnv](https://direnv.net/) when you `cd` in from Git Bash (direnv's
PowerShell hook has real bugs on this setup — see `caddy-deploy/README.md`'s
Usage section for the full explanation and first-time direnv setup).
`terraform.tfvars.example` here is the placeholder-only field reference,
never copied to a real `terraform.tfvars` in this directory.

## Certificates: same DNS-01 mechanism as external-traefik-deploy

This Pi is LAN-only, but it still gets a real, publicly-trusted certificate
via `use_acme = true` — see `../modules/traefik-node/README.md`'s
"Certificates" section for the DNS-01 mechanism itself (it doesn't need
inbound reachability, so a LAN-only Pi works exactly like an internet-facing
one here). Every hostname in `services` still has to be a real name in the
DNS zone your `cf_api_token_path` token can manage — `.internal`-style names
don't work with this mechanism.

What's specific to this Pi is **resolution, not certification**: these
hostnames should resolve to this Pi's `static_ip` only on your internal DNS
(e.g. Pi-hole), not via a public `A`/`CNAME` record that would actually
route internet traffic here. Cloudflare only needs to be able to answer the
ACME DNS-01 TXT-record challenge for the zone — it doesn't need (and
shouldn't get) a real public record pointing at this Pi.

## Dashboard

This Pi's `terraform.tfvars.example` turns on `dashboard_enabled` — see
`../modules/traefik-node/README.md`'s "Dashboard" section for the
router/`basicAuth` mechanism itself. `dashboard_hostname` needs internal-only
DNS resolution to this Pi's `static_ip`, the same as any `services` entry
(see "Certificates" above); remember the dashboard UI lives at
`/dashboard/` with a trailing slash.

## Files

- `main.tf` — a single `module "traefik" { source = "../modules/traefik-node" ... }`
  call, forwarding every variable through. Identical in shape to
  `external-traefik-deploy/main.tf` — the two directories exist separately
  because of the Docker-provider constraint explained in
  `../modules/traefik-node/README.md`, not because of any remaining
  difference in how certs are obtained.
- `variables.tf` — mirrors `../modules/traefik-node/variables.tf` exactly;
  no directory-specific variables of its own.
- `terraform.tfvars.example` — placeholder-only field reference for this
  specific Pi.
- `.envrc` — direnv config, sets `TF_CLI_ARGS_plan`/`TF_CLI_ARGS_apply` to
  point at `C:\tfvars\internal-traefik-deploy.tfvars`. Gitignored along with
  everything direnv generates locally.

No `versions.tf` here — this directory has no resources or `provider` blocks
of its own, so Terraform resolves the required providers transitively
through the module it calls.
