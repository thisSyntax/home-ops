# external-traefik-deploy

Terraform root module for the internet-facing Traefik Pi. All of the actual
logic (Pi hardening, Docker install, Traefik container) lives in the shared
`../modules/traefik-node` child module this calls — **see that module's own
README** for the dependency graph, known gaps, and why this is a single-Pi
module rather than a `pi_hosts` map like `caddy-deploy`/`pihole-deploy` use.

Applied independently from this directory, with its own state:

```bash
cd terraform/external-traefik-deploy   # .envrc auto-loads here (Git Bash + direnv)
terraform init
terraform plan
terraform apply
```

## Usage

Real values (including the Cloudflare API token path) live **outside this
repo** at `C:\tfvars\external-traefik-deploy.tfvars`, loaded the same way
`caddy-deploy`/`pihole-deploy` do — this directory's `.envrc` sets
`TF_CLI_ARGS_plan`/`TF_CLI_ARGS_apply` to point at it, auto-loaded by
[direnv](https://direnv.net/) when you `cd` in from Git Bash (direnv's
PowerShell hook has real bugs on this setup — see `caddy-deploy/README.md`'s
Usage section for the full explanation and first-time direnv setup).
`terraform.tfvars.example` here is the placeholder-only field reference,
never copied to a real `terraform.tfvars` in this directory.

## Why "external"

"External" here is about which traffic is allowed to reach this Pi's
proxied services, not about how its certificate is obtained — both this
project and `internal-traefik-deploy` use the same ACME DNS-01 mechanism
(see `../modules/traefik-node/README.md`'s "Certificates" section) and
neither depends on inbound reachability for that. This Pi still needs a real
WAN port-forward on the router (set up out of band, not managed by this
module) so real internet traffic can actually reach the services it proxies
to — `internal-traefik-deploy`'s Pi deliberately has no such port-forward,
which is the actual difference between the two.

## Files

- `main.tf` — a single `module "traefik" { source = "../modules/traefik-node" ... }`
  call, forwarding every variable through.
- `variables.tf` — mirrors `../modules/traefik-node/variables.tf` exactly,
  since this directory's only job is to accept a `terraform.tfvars` and pass
  it into the module.
- `terraform.tfvars.example` — placeholder-only field reference for this
  specific Pi.

No `versions.tf` here — this directory has no resources or `provider` blocks
of its own, so Terraform resolves the required providers transitively
through the module it calls.
