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
├── modules/pi-hardening/   reusable module: static IP, UFW, Fail2Ban, disabled X11 forwarding, unattended-upgrades
├── caddy-deploy/           installs and configures Caddy as a reverse proxy on two Pis
└── pihole-deploy/          installs and configures Pi-hole as DNS on two Pis
```

`caddy-deploy` and `pihole-deploy` are independent root modules, each with
its own Terraform state, and each calls the shared `modules/pi-hardening`
module for the common hardening baseline. See each directory's own README
for prerequisites, usage, and design notes specific to it:

- [`terraform/modules/pi-hardening`](terraform/modules/pi-hardening/README.md)
- [`terraform/caddy-deploy`](terraform/caddy-deploy/README.md)
- [`terraform/pihole-deploy`](terraform/pihole-deploy/README.md)

## How this is built

None of these Pis are provisioned by Terraform — they're physical hardware
that already exists. Every resource here is `null_resource` +
`remote-exec`/`file` provisioners driving imperative SSH commands, since
there's no Terraform provider that models "a UFW rule on an arbitrary SSH
host" as a real typed resource. Drift detection is a hand-built layer on
top of that (`data "external"` + `check` blocks comparing live Pi state
against what Terraform expects), not something native to `null_resource`.

## Prerequisites

- Terraform >= 1.5 (required for `check` blocks)
- SSH key auth already trusted on each Pi, with passwordless `sudo` for the
  relevant commands — see each project's README for the exact list
- Real secrets/IPs live outside this repo, in an external `.tfvars` file
  per project (see each project's Usage section) — nothing sensitive is
  committed here

No CI or test suite — everything is validated with `terraform
validate`/`terraform plan` before any real `apply`, which makes live SSH
connections to real Pis and changes their actual configuration.
