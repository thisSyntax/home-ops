# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A personal learning project for Terraform and Kubernetes, managing real home infrastructure:

```
terraform/
├── modules/
│   ├── pi-hardening/       reusable child module: static IP, UFW, Fail2Ban, disabled X11 forwarding, unattended-upgrades over SSH
│   └── traefik-node/       reusable child module: Docker install + a Traefik reverse-proxy container, for one Pi
├── pihole-deploy/          root module: Pi-hole DNS on two Pis (calls pi-hardening)
├── external-traefik-deploy/  root module: Traefik on the internet-facing Pi (calls traefik-node)
├── internal-traefik-deploy/  root module: Traefik on the LAN-only Pi (calls traefik-node)
└── k3s-deploy/             root module, early/in-progress: k3s cluster VMs on Proxmox (Telmate/proxmox provider)
```

`pihole-deploy` is an independent root module with its own Terraform state, calling the shared `modules/pi-hardening` module for the common hardening baseline. (An earlier `caddy-deploy` project used the same pattern; it was removed once the two Traefik projects replaced Caddy — don't recreate it.) `external-traefik-deploy` and `internal-traefik-deploy` are two independent root modules, each calling `modules/traefik-node` — split into separate directories/state rather than one `pi_hosts`-map project because that module owns its own Docker provider connection, and Terraform provider configurations can't be created dynamically from a `for_each` (see that module's own section below). `k3s-deploy` is a different paradigm again — it targets Proxmox's typed `proxmox_vm_qemu` resource rather than SSH-driving pre-existing hardware, and is still being written from scratch (see its own section below).

See each directory's own README for full prerequisites, usage, and design notes:
- [`terraform/modules/pi-hardening`](terraform/modules/pi-hardening/README.md)
- [`terraform/modules/traefik-node`](terraform/modules/traefik-node/README.md)
- [`terraform/pihole-deploy`](terraform/pihole-deploy/README.md)
- [`terraform/external-traefik-deploy`](terraform/external-traefik-deploy/README.md)
- [`terraform/internal-traefik-deploy`](terraform/internal-traefik-deploy/README.md)
- [`terraform/k3s-deploy`](terraform/k3s-deploy/README.md)

## How Claude Code is used here

This is a personal learning project for Terraform and Kubernetes. **Write Terraform/Kubernetes code only when explicitly asked to for the purpose of examples.** Otherwise, the role is documentation and guidance: help find what's next, explain how a pattern or resource works, review code the user writes, run read-only verification (`terraform validate`/`plan`), and diagnose issues — but let the user write the actual `.tf`/config changes themselves. This applies to code that's part of the learning build; live infrastructure debugging/troubleshooting (SSH, checking real Pi/VM state, fixing a live misconfiguration) is a different mode where taking direct action is expected.

## Commands

Each project directory is applied independently, with its own state — there's no root-level command spanning all of them.

```bash
cd terraform/pihole-deploy     # or external-traefik-deploy, internal-traefik-deploy, or (once further along) k3s-deploy
terraform init
terraform plan
terraform apply
```

- `modules/pi-hardening` and `modules/traefik-node` have no state or `terraform.tfvars` of their own and are never applied directly — each is only invoked via a `module` block from a root module (`pihole-deploy` for `pi-hardening`; `external-traefik-deploy`/`internal-traefik-deploy` for `traefik-node`, which itself calls `pi-hardening`).
- `pihole-deploy`, `external-traefik-deploy`, and `internal-traefik-deploy` all load real secrets/IPs via [direnv](https://direnv.net/): each has an `.envrc` that points `TF_CLI_ARGS_plan`/`TF_CLI_ARGS_apply` at an external tfvars file under `C:\terraform-local\`, so `plan`/`apply` need no `-var-file=` flag — but only from Git Bash (direnv's PowerShell hook has reproducible bugs on this setup; see the root `README.md`'s "Secrets and direnv" section for the full setup). `k3s-deploy` uses a local `terraform.tfvars` in its own directory instead (gitignored the same way), with no direnv wiring.
- `terraform validate` — fast syntax/type check, doesn't touch real infrastructure. Safe to run freely, unlike `apply`.
- No CI, test suite, lint, or build step beyond Terraform's own tooling.
- `apply` is not simulated: for `pihole-deploy`/`external-traefik-deploy`/`internal-traefik-deploy` it makes live SSH connections to real Pis and changes their actual configuration (installs packages, rewrites files, can reboot a Pi); the two Traefik projects also make live connections to each Pi's Docker daemon over SSH. For `k3s-deploy` it will create/destroy real Proxmox VMs. Treat accordingly.

## Architecture

### The `pi-hardening` pattern (pihole-deploy directly; traefik-node wraps it)

None of these Pis are provisioned by Terraform — they're physical hardware that already exists. Every resource is `null_resource` + `remote-exec`/`file` provisioners driving imperative SSH commands, since there's no Terraform provider that models "a UFW rule on an arbitrary SSH host" as a real typed resource.

**Dependency graph** inside `modules/pi-hardening` (from `main.tf`'s `depends_on`, not file order):
```
static_ip
  ├─ disable_x11_forwarding
  └─ ufw
       └─ fail2ban
            └─ unattended_upgrades
```
`ufw`, `fail2ban`, and `unattended_upgrades` are serialized because they all call `apt-get`, and two concurrent `apt-get` invocations on the same Pi would race on the dpkg lock. `disable_x11_forwarding` and `ufw` don't share `apt-get` state with each other, so they only depend on `static_ip` and run in parallel. A calling root module's own resources (e.g. `pihole-deploy`'s `pihole`) depend on the *whole module* (`depends_on = [module.pi_hardening]`), since child-module internals aren't individually addressable from outside.

**Drift detection**: every hardening resource has a matching `data "external"` + `check` block placed immediately before it in `main.tf`. Two comparison strategies, reused by the calling root modules for their own project-specific resource:
- **File-hash** (`fail2ban`, `disable_x11_forwarding`, `unattended_upgrades`): `scripts/remote-file-hash.sh` SSHes in, hashes the deployed file, and compares it against a hash computed locally from the same `templatefile()` call that renders it (see each module's `locals` block).
- **Condition-based** (`ufw`, `static_ip`; also `pihole-deploy`'s `pihole`): no single file to hash — the drift-relevant state is live command output (`ufw status verbose`, `nmcli`, `pihole-FTL --config`) rather than something rendered locally, so each has its own script returning named `"true"`/`"false"` fields.
- Checks are informational only — a failed check prints a warning naming the drifted host(s), never blocks `apply`, taints a resource, or self-heals anything. Fix real drift with `terraform apply -replace='<address>["<host-key>"]'` (module-prefixed for hardening resources, e.g. `module.pi_hardening.null_resource.ufw["my-pi"]`).
- `check` blocks don't support `for_each`, so the `data` sources live at the top level of `main.tf` rather than nested inside `check` — meaning they miss the "read as the final step of apply" timing guarantee a nested data source gets. A `-replace` that genuinely fixes drift can still record `"fail"` in that same apply's `check_results`; a follow-up plain `apply` is what records an accurate pass.

**Windows-specific gotcha**: every `data "external"` block invokes its drift-check script via an explicit path to Git for Windows' `bash.exe` (`C:/Program Files/Git/usr/bin/bash.exe`), not a bare `"bash"` — if WSL is also installed, ambient `PATH` resolution can silently pick WSL's `bash.exe` instead, a different filesystem where Windows-style paths (like the SSH key path) don't resolve.

**The static-IP resource's SSH session dying mid-run is expected**: `nmcli con up` tears down the SSH connection the instant the IP actually changes, so Terraform never sees that provisioner's exit code. `on_failure = continue` on it is intentional, not a bug signal.

**No separate reboot resource**: `unattended_upgrades_auto_reboot`/`unattended_upgrades_auto_reboot_time` let `unattended-upgrades` reboot a Pi autonomously, only when an installed update actually needs it, rather than forcing it down on every `apply`.

**Optional fixed IPv6 interface ID**: `pi_hosts[*].ipv6_token` (e.g. `"::53"`) adds `ipv6.method auto` + `addr-gen-mode eui64` + `ipv6.token` to the static-IP script, giving `<router-advertised /64>::53`. It's merged into the `static_ip` triggers only when set, so hosts without one keep identical triggers and nothing re-runs on them; the drift check's `ipv6_ok` is always true for them. The check reads the token with `nmcli -e no -g` - plain `-g` escapes its colons (`\:\:53`). IPv6 is currently disabled at the router, so the tokens set on the Pi-holes are inert.

### pihole-deploy: production Pi-holes, Nebula Sync

`pihole-deploy` manages the two production Pi-holes, a primary and a replica, kept in sync by Nebula Sync running on the primary only (hourly systemd timer, full sync from primary to replica). The template renders byte-for-byte what production runs, apart from values Pi-hole writes itself; verify that by diffing a `terraform console` render of the template against the live `/etc/pihole/pihole.toml` before any apply.

- `pihole_app_pwhashes` - sensitive map of each Pi-hole's existing `webserver.api.app_pwhash`, keyed by `pi_hosts` key, so a rebuild keeps the app password Homepage uses. Each Pi-hole has its own (Nebula Sync doesn't copy it). It's a separate map, not a `pi_hosts` field, because `pi_hosts` drives `for_each`, which rejects sensitive values.
- `pi_hosts[*].app_sudo` - `true` on the replica: Nebula Sync writes the primary's config to it with an app-password session.
- `pi_hosts[*].nebula_sync_primary` - marks the one Pi that gets `null_resource.nebula_sync` (a validation rejects two). It installs a pinned release (`nebula_sync_version`/`nebula_sync_sha256`, the linux_arm64 tarball's checksum from the release's `checksums.txt`; the install aborts on mismatch) plus the service/timer units. The env file (Pi-hole passwords) comes from `nebula_sync_env_path` and is pushed with `source`, so only its hash is in state.
- `pwhash` is set by `pihole setpassword` from `pihole_password`, so it never appears in the template; the drift check only compares upstreams, interface and `dns.hosts`.
- Local DNS records are added by hand on the primary (Nebula Sync carries them to the replica) - keep `local_hosts` in the tfvars in step or the `hosts` check warns.
- **State history**: an earlier test that *replaced* the `pi_hosts` entries with a test Pi dropped both production Pi-holes from state (destroying a `null_resource` touches nothing on the Pi, so nobody noticed). For tests, add a host to `pi_hosts`, or use a separate directory/workspace - never replace the production entries. Rebuild production one Pi at a time, replica first, by commenting out the other entry; the replica has been rebuilt on Pi OS Lite, the primary is still on the desktop image and pending.
- Fresh Pi OS images don't give the first user passwordless sudo - do the README prerequisite before the first plan, or the static-IP step's `on_failure = continue` records a "successful" create that did nothing.

### The `traefik-node` pattern (external-traefik-deploy, internal-traefik-deploy)

`modules/traefik-node` wraps `pi-hardening` and adds Docker + a Traefik reverse-proxy container on top, via `kreuzwerker/docker`'s typed `docker_image`/`docker_container` resources rather than another `null_resource`. It's called from exactly one Pi per root module (`external-traefik-deploy`, `internal-traefik-deploy`) instead of a `pi_hosts` map, because it owns its own `provider "docker" { host = "ssh://${var.ssh_user}@${var.static_ip}:22" }` block, and Terraform provider configurations can't be created dynamically from a `for_each`/`count` — a hard constraint in the language itself, not something a cleverer variable shape works around. See `modules/traefik-node/README.md` for the full dependency graph and known gaps.

Optionally, `dashboard_enabled` exposes Traefik's own dashboard via a router on `dashboard_hostname` gated by a `basicAuth` middleware (Traefik v3 has no built-in auth of its own) — not a published loopback-only port. See `modules/traefik-node/README.md`'s "Dashboard" section for the mechanism. `dashboard_allowed_ips` adds an `ipAllowList` checked before the login; the external Pi sets it to the LAN ranges, because its dashboard router shares the public 443 entrypoint (anything else gets a 403). Both Pis use the same htpasswd file, so Homepage logs in to both dashboards with one credential.

`services[*].request_headers` (optional map) adds a `customRequestHeaders` middleware to that router; an empty value removes the header. The internal Pi uses it for an embed-only Grafana route that sets Grafana's auth-proxy header (Grafana trusts it only from the internal Pi's IP), and the external Pi blanks that header on its public Grafana route.

**Root `variables.tf` files are copies of `modules/traefik-node/variables.tf`** - Terraform has no variable inheritance, and a root that doesn't declare a new object field silently drops it (no error). Copy the module's file to both roots whenever it changes.

**Changing a template?** Routes without the new feature must render byte-for-byte as before, or every route on both Pis is replaced at once. Check by rendering with `terraform console` and comparing `md5()` to the `content_hash` triggers in state (`terraform state show`). Watch `%{ }~` whitespace - spaces before a directive are output literally.

Both root modules leave `use_acme = true` and get real Let's Encrypt certificates via Traefik's ACME **DNS-01** challenge against Cloudflare, configured in `traefik.yml.tftpl`'s `dnsChallenge` block — validation happens by Cloudflare answering a DNS TXT-record lookup, not by anything connecting to the Pi, so it works identically for the LAN-only Pi as for the internet-facing one. Every hostname passed to either project has to be a real name in a Cloudflare-managed DNS zone (`.internal`-style names don't work). The Cloudflare API token is never a Terraform value beyond a local file path (`cf_api_token_path`): `modules/traefik-node`'s `null_resource.cf_token` pushes it to the Pi as a root-owned file, read by Traefik via `CF_DNS_API_TOKEN_FILE` (every `lego`-based DNS provider supports reading a credential from a file via a `_FILE`-suffixed env var), so the token itself never lands in Terraform state or a plain `docker_container.env` entry. "External" vs "internal" is now purely about which traffic reaches each Pi's proxied services — the external Pi has a real WAN port-forward for actual visitor traffic, the internal Pi deliberately doesn't and relies on internal-only DNS resolution instead — not about how either gets its certificate. See `modules/traefik-node/README.md`'s "Certificates" section for the full mechanism.

### k3s-deploy (new, in progress)

Targets Proxmox directly via the `Telmate/proxmox` provider (`~> 3.0`) — a different paradigm from the SSH-driven projects above: `proxmox_vm_qemu` is a real typed resource, not a `null_resource` wrapper. As of this writing it's just getting started (`main.tf` has a first-draft `provider`/`resource` block, `variables.tf` is still empty) — nothing here is an established pattern yet the way the hardening module's conventions are. One live gotcha already found: the provider's `disk`/`network` configuration is nested-block-based in `~> 3.0` (`disk { }`/`network { }`, or the combined `disks { }` block), not flat attributes, and there's no top-level `iso` attribute at all — ISO attachment lives inside a `disks { ide { ide2 { cdrom { iso = ... } } } }` block. A common gotcha when porting examples written against the older v2.x schema.

## Prerequisites

- Terraform >= 1.5 (required for `check` blocks, used by every SSH-driven project)
- SSH key auth already trusted on each Pi, with passwordless `sudo` for the relevant commands — see each project's README for the exact command list
- `external-traefik-deploy`/`internal-traefik-deploy` also need Docker reachable at `docker_host` over the same SSH key, once `pi-hardening` and the Docker-install step have run
- `external-traefik-deploy`/`internal-traefik-deploy` also need a Cloudflare-managed DNS zone and an API token scoped to `Zone:DNS:Edit` on it (not broader account access), used for the ACME DNS-01 challenge — see `modules/traefik-node/README.md`'s "Certificates" section
- Real secrets/IPs live outside this repo: `pihole-deploy`/`external-traefik-deploy`/`internal-traefik-deploy` read theirs from `C:\terraform-local\<project>.tfvars` via direnv; `k3s-deploy` uses a local `terraform.tfvars` in its own directory instead. Nothing sensitive is committed here (`.gitignore` excludes all `*.tfvars` except `*.tfvars.example`). `C:\terraform-local\` also holds the files those tfvars point at: one Cloudflare token file per Traefik Pi, the shared dashboard htpasswd, and the Nebula Sync env file; `archive\` there keeps retired state and config copies (e.g. caddy-deploy's).
- **This repo is public** - never copy a live config, tfvars value, password hash or real hostname/IP into it. Secret-scan `git diff` and untracked files before every commit.

## Conventions

- `terraform fmt` style (2-space indent, aligned `=`) across the repo; `terraform fmt -recursive -check` should pass.
- `.gitattributes` forces LF (`* text=auto eol=lf`). Git for Windows' default `core.autocrlf=true` once checked files out with CRLF, and since templates render byte-for-byte onto the Pis, every route showed as changed. If a plan unexpectedly wants to replace everything, check for `\r` in the templates first.
- Plans that will be applied are saved with `-out` to `C:\terraform-local\` (plan files contain variable values, including sensitive ones) and deleted after use.
