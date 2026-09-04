# external-traefik-deploy

Terraform root module for the internet-facing Traefik Pi. All of the actual
logic (Pi hardening, Docker install, Traefik container) lives in the shared
`../modules/traefik-node` child module this calls — **see that module's own
README** for the dependency graph, known gaps, and why this is a single-Pi
module rather than a `pi_hosts` map like `caddy-deploy`/`pihole-deploy` use.

Applied independently from this directory, with its own state:

```bash
cd terraform/external-traefik-deploy
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

## Why "external"

This Pi gets real Let's Encrypt certificates via Traefik's HTTP-01
challenge (`use_acme = true`, the default), which requires it to be
reachable on port 80 from the public internet — a WAN port-forward on the
router, set up out of band and not managed by this module. See
`../modules/traefik-node/README.md`'s "Known gaps" section for the current
state of that. Contrast with `internal-traefik-deploy`, which sets
`use_acme = false` and supplies its own certificate via `mkcert` instead —
see that directory's README.

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
