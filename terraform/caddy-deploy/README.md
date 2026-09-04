# caddy-deploy

Terraform root module that installs and configures Caddy as a reverse proxy
on two Raspberry Pis (one internet-facing, one internal-LAN). Base Pi
hardening (static IP, UFW, Fail2Ban, disabled X11 forwarding,
unattended-upgrades) is handled by the reusable `../modules/pi-hardening`
module this calls — **see that module's own README** for hardening
prerequisites, its drift-detection design, and the Windows/Git-Bash path
gotcha, all of which apply here too and aren't repeated below.

Applied independently from this directory, with its own state:

```bash
cd terraform/caddy-deploy
terraform init
terraform plan
terraform apply
```

Each Pi in `pi_hosts` gets a `role` — `"external"` (internet-facing, Let's
Encrypt via Cloudflare DNS-01 per site) or `"internal"` (LAN-only, Caddy's
own internal CA) — and a `sites` list of hostname → upstream pairs. `role`
and `sites` exist only here, not in the hardening module, since they're
purely a Caddy concern.

## Usage

Real values (including the Cloudflare API token) live **outside this repo**
at `C:\tfvars\caddy-deploy.tfvars` — not in a local `terraform.tfvars` —
specifically so they can't end up committed even if `.gitignore` were ever
misconfigured. `terraform.tfvars.example` in this directory is just the
placeholder-only template for reference/onboarding; it's never copied to a
real `terraform.tfvars` here.

This directory's `.envrc` (loaded automatically by [direnv](https://direnv.net/)
when you `cd` in, via its bash hook) sets `TF_CLI_ARGS_plan` and
`TF_CLI_ARGS_apply` to point at that external file, so `plan`/`apply` pick
it up with no `-var-file=` flag needed:

```bash
cd terraform/caddy-deploy   # .envrc auto-loads here (Git Bash + direnv)
terraform init
terraform plan
terraform apply
```

First time setting this up on a new machine: create `C:\tfvars\caddy-deploy.tfvars`
with real values (use `terraform.tfvars.example` as the field reference),
install direnv, add `eval "$(direnv hook bash)"` to `~/.bashrc` (Git Bash
also needs a `~/.bash_profile` that sources it, or interactive shells won't
read `.bashrc` at all — Git Bash offers to create one automatically the
first time it notices this), then `direnv allow` in this directory once to
approve its `.envrc`.

This setup is Git-Bash-specific by design, not an oversight — direnv's
PowerShell hook has real, reproducible bugs on Windows (a missing-`$HOME`
issue, and a separate bug where `direnv export pwsh` mangles its own path
while shelling out to bash to parse `.envrc`), while the bash hook works
cleanly. Run the Terraform commands above from Git Bash, not PowerShell.

`main.tf` calls `module "pi_hardening"`, deriving its leaner `pi_hosts`
shape (just `static_ip`/`gateway`/`dns`/`interface`/`bootstrap_ip`) from
this module's richer one. The `caddy` resource declares
`depends_on = [module.pi_hardening]` so it only runs once every hardening
step has completed on a Pi — module internals aren't individually
addressable from the calling module, so this depends on the whole module
rather than a specific resource inside it.

## Caddy: install, config, and certs

Caddy is installed from its official apt repo (Cloudsmith — covers
Raspberry Pi OS's arm64/armhf, not just amd64), then `/etc/caddy/Caddyfile`
is rendered from each host's `role` and `sites`:

- **`role = "external"`**: each site gets Caddy's automatic HTTPS via
  Let's Encrypt DNS-01 through Cloudflare (`cloudflare_api_token`). This
  *requires* the site's `hostname` to be a real domain whose DNS you
  control via that Cloudflare account, and (if you want it actually
  reachable) a WAN port-forward on your router pointed at this Pi's
  `static_ip`. **This module does not manage that port-forward** (it's
  UniFi-side config, out of scope here).
- **`role = "internal"`**: each site gets `tls internal` — Caddy's built-in
  CA issues and renews the cert with no external dependency. Point your
  internal DNS (e.g. PiHole) at each internal hostname → this Pi's
  `static_ip`. Browsers/OSes will flag the cert as untrusted until you trust
  Caddy's root once: pull `/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt`
  off the Pi and add it to your admin devices' trusted root store.

Either way, `caddy validate` runs against the rendered Caddyfile before
Caddy is reloaded, so a bad config fails the `apply` instead of silently
leaving the proxy on stale config.

## Drift detection

Same mechanism the hardening module uses (see its README for the full
explanation) — a `data "external" "caddy"` + `check "caddyfile_check"`
block SSHes in, hashes the live `/etc/caddy/Caddyfile`, and compares it
against a hash computed locally from the same `templatefile()` call that
renders it. Non-blocking; a failed check prints a warning naming the
drifted Pi(s) and doesn't stop `apply`. Fix real drift with:

```bash
terraform apply -replace='null_resource.caddy["caddy-proxy-internal"]'
```

(Note this one isn't module-prefixed — `caddy` lives directly in this root
module, unlike the hardening resources.)

## Files

- `main.tf` — the `module "pi_hardening"` call, then the `caddy`
  `null_resource` (one instance per host in `pi_hosts` via `for_each`)
  paired with its own `data "external"` + `check` block for drift
  detection. A `locals` block computes the expected Caddyfile hash once,
  shared between the resource's `triggers` and its check.
- `variables.tf` — every input this module needs, including ones only used
  to pass through into the `module` block (`application_ufw_*`,
  `fail2ban_*`, `unattended_upgrades_*`, `auto_upgrades_days`,
  `ssh_private_key_path`) plus the ones used directly here (`pi_hosts` with
  its `role`/`sites`, `acme_email`, `cloudflare_api_token`).
- `versions.tf` — `hashicorp/null` and `hashicorp/external`.
- `templates/` — `Caddyfile.tftpl` and `caddy-env-override.conf.tftpl`
  (the Cloudflare API token override for external-role Pis) — the only
  templates left here, since the hardening ones moved to the module.
- `scripts/remote-file-hash.sh` — the same drift-check script the
  hardening module uses, kept here too since this module's own Caddyfile
  check needs it independently.
- `terraform.tfvars.example` — placeholder-only field reference; real
  values live outside the repo (see Usage above), this is never copied to
  a real `terraform.tfvars` here.
- `.envrc` — direnv config, sets `TF_CLI_ARGS_plan`/`TF_CLI_ARGS_apply` to
  point at `C:\tfvars\caddy-deploy.tfvars`. Gitignored along with
  everything direnv generates locally.
