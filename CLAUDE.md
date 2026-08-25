# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single Terraform root module, `terraform/pi-caddy-hardening/`, that hardens and configures two Raspberry Pis (one internet-facing, one internal-LAN) as Caddy reverse proxies — a Terraform port of a manual runbook, built as a way to learn Terraform's `for_each`/`depends_on`/provisioner/`data`/`check` mechanics against real infrastructure. The Pis themselves aren't provisioned by Terraform (they already exist as physical hardware); this module is pure SSH-driven configuration management via `null_resource` + `remote-exec`, not a typed-resource cloud deployment.

This directory is not (yet) a git repository.

## How Claude Code is used here

This is a personal learning project for Terraform. **Write Terraform/Kubernetes code only when explicitly asked to for the purpose of example.** Otherwise, the role is documentation and guidance: help find what's next, explain how a pattern or resource works, review code the user writes, run read-only verification (`terraform validate`/`plan`), and diagnose issues — but let the user write the actual `.tf`/config changes themselves. This applies to code that's part of the learning build; live infrastructure debugging/troubleshooting (SSH, checking real Pi state, fixing a live misconfiguration) is a different mode where taking direct action is expected.

## Commands

```bash
cd terraform/pi-caddy-hardening
cp terraform.tfvars.example terraform.tfvars   # first time only; fill in real values
terraform init
terraform plan
terraform apply
```

- `terraform validate` — fast syntax/type check, doesn't touch real infrastructure.
- No test suite, lint, or build step beyond Terraform's own tooling. Validate changes with `terraform validate` and `terraform plan` before running a real `apply`.
- `plan`/`validate` are safe to run freely. `apply` is not simulated — it makes live SSH connections to the two Pis and changes their actual configuration (installs packages, rewrites config files, can reboot a Pi). Treat it accordingly.

## Architecture

**Dependency graph** (from `main.tf`'s `depends_on`, not the order resources happen to appear in the file):

```
static_ip
  ├─ disable_x11_forwarding
  └─ ufw
       └─ fail2ban
            └─ caddy
                 └─ unattended_upgrades
```

`ufw`, `fail2ban`, `caddy`, and `unattended_upgrades` are serialized specifically because they all call `apt-get`, and two concurrent `apt-get` invocations on the same Pi would race on the dpkg lock. `disable_x11_forwarding` and `ufw` don't touch `apt-get` state shared with each other, so they only depend on `static_ip` and can run in parallel.

**`null_resource` + `remote-exec` pattern**: there's no Terraform provider that models "a UFW rule on an arbitrary SSH host" as a real managed resource, so every resource here is imperative SSH commands gated by a `triggers` map — provisioners only re-run when a trigger value changes, which is a much thinner signal than a real typed-resource diff.

**Drift detection**: every resource has a matching `data "external"` + `check` block placed immediately before it in `main.tf`. Two comparison strategies depending on what's actually drift-relevant:
- **File-hash** (`caddy`, `fail2ban`, `disable_x11_forwarding`, `unattended_upgrades`): `scripts/remote-file-hash.sh` SSHes in, hashes the deployed file, and compares it against a hash computed locally from the same `templatefile()` call that renders it. The `locals` block at the top of `main.tf` is the single source of truth for these expected hashes, shared between each resource's own `triggers` and its drift check.
- **Condition-based** (`ufw`, `static_ip`): no file to hash — the drift-relevant state is live command output (`ufw status verbose`, `nmcli`/`ip addr`) rather than something rendered locally. `scripts/ufw-status-check.sh` and `scripts/static-ip-check.sh` check specific conditions and return named `"true"`/`"false"` fields instead of a single hash.
- Checks are informational only — a failed check prints a warning naming the drifted Pi(s), but never blocks `apply`, taints a resource, or self-heals anything. Fix real drift with `terraform apply -replace='null_resource.<name>["<pi-key>"]'`.
- `check` blocks don't support `for_each`, so these `data` sources live at the top level of `main.tf` rather than nested inside their `check` — which means they miss the "read as the final step of apply" timing guarantee a nested data source gets. A `-replace` that genuinely fixes drift can still record that check as `"fail"` in that same apply's `check_results` (a stale read from before the fix landed); a follow-up plain `apply` is what records an accurate pass.

**`templates/` vs `scripts/`**: `templates/` holds config rendered and pushed *to* a Pi via `provisioner "file"`. `scripts/` holds helpers executed *locally* by the `data "external"` drift checks and never pushed to a Pi — a deliberate separation even though both are just files on disk in this module.

**Role-based Caddy config**: each entry in the `pi_hosts` variable has a `role` of `"external"` (real Let's Encrypt certs via Cloudflare DNS-01 — requires a WAN port-forward set up out of band, not managed by this module) or `"internal"` (Caddy's own self-signed CA — requires manually trusting the root cert on client devices).

**Windows-specific gotcha**: `data "external"` blocks invoke the drift-check scripts via an explicit path to Git for Windows' `bash.exe` (`C:/Program Files/Git/usr/bin/bash.exe`), not a bare `"bash"`. If WSL is also installed, ambient `PATH` resolution can silently pick WSL's `bash.exe` instead, which is a different filesystem where Windows-style paths (like the SSH key path) don't resolve. The scripts themselves also explicitly export that same directory onto `PATH` as their first line, since Terraform invokes `bash.exe` non-interactively with no profile sourcing, so tools like `cat`/`grep`/`ssh` wouldn't otherwise be found.

**The static-IP resource's SSH session dying mid-run is expected**: `nmcli con up` tears down the SSH connection the instant the IP actually changes, so Terraform never sees that provisioner's exit code. `on_failure = continue` on it is intentional, not a bug signal.

**No separate reboot resource**: `unattended_upgrades_auto_reboot` / `unattended_upgrades_auto_reboot_time` (variables) let `unattended-upgrades` reboot each Pi autonomously, only when an installed update actually needs it, rather than forcing both proxies down on every `apply`.

## Prerequisites for a real `apply`

- SSH key auth already trusted on each Pi for `ssh_user` (this module does not bootstrap SSH keys).
- `ssh_user` has passwordless `sudo` for at least `apt-get`, `ufw`, `systemctl`, `nmcli`, `install`, `fail2ban-client`, and `unattended-upgrade`.
- Terraform >= 1.5 — required for `check` blocks, not just recommended.
