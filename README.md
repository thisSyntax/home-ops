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
├── caddy-deploy/                installs and configures Caddy as a reverse proxy on two Pis
├── pihole-deploy/               installs and configures Pi-hole as DNS on two Pis
├── external-traefik-deploy/     installs Traefik on the internet-facing Pi (calls modules/traefik-node)
├── internal-traefik-deploy/     installs Traefik on the LAN-only Pi (calls modules/traefik-node)
└── k3s-deploy/                  early/in-progress: k3s cluster VMs on Proxmox
```

`caddy-deploy` and `pihole-deploy` are independent root modules, each with
its own Terraform state, and each calls the shared `modules/pi-hardening`
module for the common hardening baseline. `external-traefik-deploy` and
`internal-traefik-deploy` are two more independent root modules — split into
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
- [`terraform/caddy-deploy`](terraform/caddy-deploy/README.md)
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
- Real secrets/IPs are never committed — `caddy-deploy`/`pihole-deploy` keep
  theirs in an external `.tfvars` file outside this repo (via direnv); the
  Traefik/k3s projects use a local `terraform.tfvars`, gitignored the same
  way (see each project's Usage section for specifics)

No CI or test suite — everything is validated with `terraform
validate`/`terraform plan` before any real `apply`, which makes live SSH
connections to real Pis and changes their actual configuration.
