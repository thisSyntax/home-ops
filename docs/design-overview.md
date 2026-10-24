# Design overview

This repo is a personal project for learning Terraform's
`for_each`/`depends_on`/provisioner/`data`/`check`/module mechanics against
real, physical infrastructure rather than a sandbox. It's public so anyone
curious about the pattern can see a working example end to end.

## SSH-driven configuration with `null_resource`

None of the Raspberry Pis are provisioned by Terraform — they're physical
hardware that already exists. There's no Terraform provider that models "a
UFW rule on an arbitrary SSH host" as a real typed resource, so every
hardening and install step is a `null_resource` with `file`/`remote-exec`
provisioners driving imperative SSH commands.

What that costs, compared with a purpose-built config-management tool:

- `null_resource` has no real `Read`. Terraform only re-runs a step when the
  resource's own `triggers` change; it never looks at the Pi by itself.
- `terraform plan` can't show what a `remote-exec` block will do — it's
  opaque shell, not a typed diff.
- A step that changes the Pi's IP kills its own SSH session (see
  [pi-hardening.md](pi-hardening.md)). Ansible, which reconnects between
  plays, wouldn't have that problem.

Two places use real typed resources instead, and get Terraform's native
drift detection for free: the Traefik container (`kreuzwerker/docker`'s
`docker_image`/`docker_container`) and `k3s-deploy`'s Proxmox VMs
(`proxmox_vm_qemu`).

**When to outgrow it:** if the pattern starts feeling constraining, Ansible
is the natural next step. The modules' `templates/` translate almost
directly into Ansible task content.

## Drift detection: `data "external"` + `check`

Because `null_resource` can't notice drift, a hand-built layer sits on top:
every SSH-driven resource has a matching `data "external"` source that SSHes
into the Pi on each `plan`/`apply`, plus a `check` block that compares the
result with what Terraform expects.

Two comparison strategies, depending on what's actually drift-relevant:

- **File hash** — when the resource renders a file that should stay as
  rendered (Fail2Ban jail, sshd drop-in, unattended-upgrades conf). A script
  hashes the deployed file and compares it to a hash computed locally from
  the same `templatefile()` call that renders it.
- **Conditions** — when the meaningful state is live command output rather
  than a file: `ufw status verbose`, `nmcli` for the static IP,
  `pihole-FTL --config` for Pi-hole. Each script returns named
  `"true"`/`"false"` fields.

The check scripts live in `scripts/` and run locally (on the machine running
Terraform); `templates/` holds files rendered and pushed *to* a Pi. Different
roles, kept in different folders.

**Checks are informational, not enforcement.** A failed check prints a
warning naming the drifted Pi — it never blocks `apply`, taints a resource,
or fixes anything. Fixing drift is a deliberate `terraform apply -replace=...`.

**Timing quirk:** `check` blocks don't support `for_each`, so the `data`
sources live at the top level of `main.tf` rather than inside each `check`
(nesting would mean giving up per-Pi checking). A data source nested in a
`check` is read as the last step of an apply; a top-level one isn't. So an
`apply -replace` that genuinely fixes drift can still record the check as
failed in that same apply — the data was read before the fix landed. A plain
follow-up `apply` records the accurate pass.

**Windows detail:** every `data "external"` invokes its script through an
explicit path to Git for Windows' `bash.exe`
(`C:/Program Files/Git/usr/bin/bash.exe`). A bare `"bash"` can resolve to
WSL's `bash.exe` instead — a different filesystem where Windows paths like
the SSH key path don't resolve.

## Where secrets live

- Real values never go in the repo. Each project's tfvars lives outside it,
  in `C:\terraform-local\<project>.tfvars`, not in a gitignored
  `terraform.tfvars` — so a misconfigured `.gitignore` can't leak them.
- Secret *files* (Cloudflare tokens, htpasswd, the Nebula Sync env file) are
  Terraform values only as **paths**. They're pushed to the Pi with the
  `file` provisioner's `source`, never `content`, and triggered on
  `filemd5()` — so only a hash ever reaches state.
- Values that must be in a rendered file (Pi-hole app password hashes) are
  `sensitive = true` variables.

### direnv on Git Bash, not PowerShell

Each project's `.envrc` sets `TF_CLI_ARGS_plan`/`TF_CLI_ARGS_apply` to the
external tfvars file, so no `-var-file` flag is needed. It's Git-Bash-only
by design: direnv's PowerShell hook has reproducible bugs on Windows (a
missing-`$HOME` issue, and `direnv export pwsh` mangling its own path while
shelling out to bash to parse `.envrc`), while the bash hook works cleanly.

## Why the projects are split the way they are

Each root module has its own directory and state, applied independently, so
a mistake in one can't touch another's Pis. The two Traefik projects are
split for a harder reason — Terraform can't create provider configurations
per `for_each` instance; see [traefik.md](traefik.md).
