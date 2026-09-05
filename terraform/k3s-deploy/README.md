# k3s-deploy

Terraform root module for a k3s cluster's VMs on Proxmox, via the
`Telmate/proxmox` provider — a different paradigm from every other project
in this repo. Those SSH-drive pre-existing Raspberry Pi hardware with
`null_resource` + `remote-exec`, since there's no Terraform provider that
models "a UFW rule on an arbitrary SSH host" as a real typed resource. Here,
`proxmox_vm_qemu` *is* a real typed resource — Proxmox exposes a genuine
fleet-wide API (`pm_api_url`), so one `provider "proxmox"` block plus
`for_each` over a `vms` map can create any number of VMs from one state, no
per-VM directory needed (unlike `external-traefik-deploy`/
`internal-traefik-deploy`, which are split because `kreuzwerker/docker` has
no such fleet-wide API — see `../modules/traefik-node/README.md` for that
constraint).

## Status: early / in progress

This is just getting started — `main.tf` has a first-draft
`provider`/`resource` block, `variables.tf` is empty, and nothing here
should be treated as an established pattern the way `pi-hardening`'s
conventions are.

Known issue not yet fixed: `resource "proxmox_vm_qemu" "create_vm"`'s
`disk`, `network`, and `iso` arguments are written as flat attributes, which
matches the `Telmate/proxmox` provider's older v2.x examples but not `~> 3.0`
(the version pinned in `versions.tf`). In `~> 3.0`:

- `disk` must be a repeatable `disk { }` block (or the alternative nested
  `disks { }` block), not a plain assignment — minimum required sub-fields
  are `slot` (e.g. `scsi0`) and `type` (e.g. `disk`).
- `network` must be a `network { }` block too, with required `id` and
  `model` sub-fields.
- There's no top-level `iso` attribute at all. ISO attachment lives inside
  `disks { ide { ide2 { cdrom { iso = "..." } } } }`.

`variables.tf` also needs writing — `main.tf` currently references
`var.proxmox_cluster`, `var.proxmox_token_id`, `var.proxmox_token_secret`,
and `var.vms`, none of which are declared yet.

Also not yet addressed: `provider "proxmox"` hardcodes `pm_tls_insecure =
true`, so `proxmox_token_secret` is sent with TLS verification disabled
unconditionally. Fine for a first draft against a self-signed Proxmox host on
a trusted LAN, but worth turning into an explicit variable (defaulting to
`false`) once this module is otherwise ready, so disabling verification is a
conscious choice rather than a silent hardcode.

## Files

- `main.tf` — `provider "proxmox"` and a first-draft `proxmox_vm_qemu`
  resource (see "Known issue" above).
- `versions.tf` — `Telmate/proxmox`.
- `variables.tf` — currently empty.
