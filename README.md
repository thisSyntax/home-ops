# home-ops

Terraform code that hardens and configures my home Raspberry Pi fleet over
SSH — a personal project for learning Terraform's
`for_each`/`depends_on`/provisioner/`data`/`check`/module mechanics against
real, physical infrastructure rather than a sandbox. Public so anyone
curious about this pattern (SSH-driven config management via
`null_resource`, non-blocking drift detection with `check` blocks, a
reusable child module shared across projects) can see a working example
end to end.

## What's here

```
terraform/
├── modules/
│   ├── pi-hardening/  reusable module: static IP, UFW, Fail2Ban, disabled X11 forwarding, unattended-upgrades
│   └── traefik-node/  reusable module: Docker install + a Traefik reverse-proxy container, for one Pi
├── pihole-deploy/               installs and configures Pi-hole as DNS on two Pis
├── external-traefik-deploy/     installs Traefik on the internet-facing Pi (calls modules/traefik-node)
├── internal-traefik-deploy/     installs Traefik on the LAN-only Pi (calls modules/traefik-node)
└── k3s-deploy/                  early/in-progress: k3s cluster VMs on Proxmox
```

`pihole-deploy` is an independent root module with its own Terraform state,
calling the shared `modules/pi-hardening` module for the common hardening
baseline. (An earlier `caddy-deploy` project used the same pattern; it was
removed once the two Traefik projects replaced Caddy.)
`external-traefik-deploy` and `internal-traefik-deploy` are two independent
root modules — split into
separate directories/state rather than one `pi_hosts`-map project, because
the module they call owns its own Docker provider connection, and Terraform
provider configurations can't be created dynamically from a `for_each` (see
that module's README for the full explanation). `k3s-deploy` is a different
paradigm again — it targets Proxmox's typed `proxmox_vm_qemu` resource
rather than SSH-driving pre-existing hardware, and is still being written
from scratch. See each directory's own README for prerequisites, usage, and
design notes specific to it:

- [`terraform/modules/pi-hardening`](terraform/modules/pi-hardening/README.md)
- [`terraform/modules/traefik-node`](terraform/modules/traefik-node/README.md)
- [`terraform/pihole-deploy`](terraform/pihole-deploy/README.md)
- [`terraform/external-traefik-deploy`](terraform/external-traefik-deploy/README.md)
- [`terraform/internal-traefik-deploy`](terraform/internal-traefik-deploy/README.md)
- [`terraform/k3s-deploy`](terraform/k3s-deploy/README.md)

## How this is built

None of the Raspberry Pis are provisioned by Terraform — they're physical
hardware that already exists. Every hardening resource is `null_resource` +
`remote-exec`/`file` provisioners driving imperative SSH commands, since
there's no Terraform provider that models "a UFW rule on an arbitrary SSH
host" as a real typed resource. Drift detection is a hand-built layer on
top of that (`data "external"` + `check` blocks comparing live Pi state
against what Terraform expects), not something native to `null_resource`.

Two exceptions use real typed resources instead: `modules/traefik-node`'s
Traefik container comes from `kreuzwerker/docker`'s `docker_image`/
`docker_container`, and `k3s-deploy` targets Proxmox's `proxmox_vm_qemu`
directly — both get Terraform's native drift detection for free, since a
typed resource has a real `Read`, unlike `null_resource`.

## Prerequisites

- Terraform >= 1.5 (required for `check` blocks)
- SSH key auth already trusted on each Pi, with passwordless `sudo` for the
  relevant commands — see each project's README for the exact list
- Real secrets/IPs are never committed — `pihole-deploy`/
  `external-traefik-deploy`/`internal-traefik-deploy` keep theirs in an
  external `.tfvars` file outside this repo (via direnv, see below);
  `k3s-deploy` uses a local `terraform.tfvars`, gitignored the same way (see
  each project's Usage section for specifics)

No CI or test suite — everything is validated with `terraform
validate`/`terraform plan` before any real `apply`, which makes live SSH
connections to real Pis and changes their actual configuration.

## Secrets and direnv

Real values for `pihole-deploy`, `external-traefik-deploy` and
`internal-traefik-deploy` live **outside this repo** at
`C:\terraform-local\<project>.tfvars` — not in a local `terraform.tfvars` —
specifically so they can't end up committed even if `.gitignore` were ever
misconfigured. Each project's `terraform.tfvars.example` is just the
placeholder-only field reference; it's never copied to a real
`terraform.tfvars`.

Each of those directories has an `.envrc` (loaded automatically by
[direnv](https://direnv.net/) when you `cd` in, via its bash hook) that sets
`TF_CLI_ARGS_plan` and `TF_CLI_ARGS_apply` to point at that external file,
so `plan`/`apply` pick it up with no `-var-file=` flag needed:

```bash
cd terraform/pihole-deploy   # .envrc auto-loads here (Git Bash + direnv)
terraform init
terraform plan
terraform apply
```

First time setting this up on a new machine: create
`C:\terraform-local\<project>.tfvars` with real values (use the project's
`terraform.tfvars.example` as the field reference), install direnv, add
`eval "$(direnv hook bash)"` to `~/.bashrc` (Git Bash also needs a
`~/.bash_profile` that sources it, or interactive shells won't read
`.bashrc` at all — Git Bash offers to create one automatically the first
time it notices this), then `direnv allow` in each project directory once
to approve its `.envrc`.

This setup is Git-Bash-specific by design, not an oversight — direnv's
PowerShell hook has real, reproducible bugs on Windows (a missing-`$HOME`
issue, and a separate bug where `direnv export pwsh` mangles its own path
while shelling out to bash to parse `.envrc`), while the bash hook works
cleanly. Run the Terraform commands above from Git Bash, not PowerShell.
