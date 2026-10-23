# pihole-deploy

Terraform root module that installs and configures Pi-hole as the DNS
server on two Raspberry Pis. Base Pi hardening (static IP, UFW, Fail2Ban,
disabled X11 forwarding, unattended-upgrades) is handled by the reusable
`../modules/pi-hardening` module this calls — **see that module's own
README** for hardening prerequisites, its drift-detection design, and the
Windows/Git-Bash path gotcha, all of which apply here too and aren't
repeated below.

This exists to make the two existing production Pi-holes (kept in sync
with each other via [Nebula Sync](https://github.com/lovelaze/nebula-sync))
reproducible via Terraform — if either Pi ever needs replacing, `apply`
stands up a working replacement instead of redoing the setup by hand.

Applied independently from this directory, with its own state:

```bash
cd terraform/pihole-deploy
terraform init
terraform plan
terraform apply
```

## Usage

Real values (including the Pi-hole password) live **outside this repo** at
`C:\terraform-local\pihole-deploy.tfvars` — not in a local `terraform.tfvars` —
so they can't end up committed even if
`.gitignore` were ever misconfigured. `terraform.tfvars.example` here is the
placeholder-only field reference, never copied to a real `terraform.tfvars`.

This directory's `.envrc` (loaded automatically by
[direnv](https://direnv.net/) when you `cd` in, via its bash hook) sets
`TF_CLI_ARGS_plan`/`TF_CLI_ARGS_apply` to point at that external file — see
the root `README.md`'s "Secrets and direnv" section for the full direnv setup
instructions (installing it, the `~/.bashrc`/`~/.bash_profile` hook, why
this is Git-Bash-specific and not PowerShell), which apply identically
here.

## pi_hosts

Each entry needs `static_ip`/`gateway`/`bootstrap_ip` (same as the
hardening module expects) plus one thing specific to this project:

- **`dns`** does double duty here — it's both the Pi's own system resolver
  (used by the hardening module for `nmcli`)
  *and* the value passed to Pi-hole's own `dns.upstreams` setting (what
  Pi-hole itself forwards unresolved queries to). Reusing the same list for
  both is deliberate, not an oversight — this Pi should resolve through the
  same upstream it hands out to everyone else.

Optional per-Pi fields:

- **`ipv6_token`** — a fixed IPv6 interface ID (e.g. `"::53"`), passed to
  the hardening module; see its README. Only useful if the router
  advertises an IPv6 prefix on this network.
- **`app_sudo`** — `webserver.api.app_sudo`, letting app-password sessions
  change settings. Set `true` on the **replica**: Nebula Sync writes the
  primary's config to it through an app-password session.
- **`nebula_sync_primary`** — `true` on the **primary** only (a validation
  rejects two). That Pi gets Nebula Sync installed; see below.

## Passwords

Pi-hole v6 has two credentials per instance, handled differently:

**Web interface password (`pwhash`)** — `pihole_password` is a single
plaintext, `sensitive = true` variable shared across both Pis, applied
post-install via `pihole setpassword` rather than pre-seeded into
`pihole.toml`. Pi-hole's password hash (BALLOON-SHA256) is salted, so the
same password produces a different hash on each instance — a shared hash
variable can't represent "the same password on both Pis," but a shared
plaintext one (hashed fresh on each Pi at `setpassword` time) can. The
template leaves `webserver.api.pwhash` empty for that reason.

**App password (`app_pwhash`)** — what API clients use (Homepage's Pi-hole
cards, Nebula Sync on the replica). Pi-hole generates it and shows it once,
so it can't be chosen up front; what Terraform can do is **carry an
existing hash over** a rebuild via `pihole_app_pwhashes`, a sensitive map
keyed like `pi_hosts`. Each Pi-hole has its own — Nebula Sync doesn't copy
it. (It's a separate map rather than a `pi_hosts` field because `pi_hosts`
drives `for_each`, which can't take sensitive values.) A Pi with no entry
gets no app password.

### Greenfield: a brand-new Pi-hole

1. Leave the Pi out of `pihole_app_pwhashes` and apply. It comes up with
   the web password and no app password.
2. In that Pi-hole's web interface, create an app password (Settings → Web
   interface / API, with expert settings shown → *Configure app password*;
   the exact labels vary by Pi-hole version). Copy the password it shows
   into whatever uses it (Homepage, Nebula Sync) — it's shown only once.
3. Read the resulting hash from the Pi and add it to the tfvars, so future
   rebuilds keep that same app password:
   ```bash
   ssh <ssh_user>@<pi-ip> 'sudo pihole-FTL --config webserver.api.app_pwhash'
   ```
   ```hcl
   pihole_app_pwhashes = {
       <pi_hosts key> = "<that hash>"
   }
   ```
4. Plan. Adding the hash changes the rendered `pihole.toml`, so
   `null_resource.pihole` for that Pi is **replaced** — the install sequence
   below runs again (reinstall/repair plus `setpassword`). It writes the
   same values, so it's safe, just not instant.

### Rebuilding an existing Pi-hole

Before wiping it, copy its current hash into `pihole_app_pwhashes` (step 3
above). The rebuilt Pi-hole then accepts the same app password, and nothing
that uses it needs updating.

## Nebula Sync (primary only)

[Nebula Sync](https://github.com/lovelaze/nebula-sync) runs on the primary
and pushes its config to the replica(s) hourly (`templates/nebula-sync.service`
and `.timer`). `null_resource.nebula_sync` installs a pinned release —
`nebula_sync_version` plus `nebula_sync_sha256`, the `linux_arm64` tarball's
checksum from that release's `checksums.txt` — and aborts if the download
doesn't match. Bump both together.

Its settings come from a local env file at `nebula_sync_env_path` (outside
the repo, like the tfvars), pushed with `source` so only its hash is in
state. For example:

```ini
PRIMARY=http://<primary-ip>|<primary password>
REPLICAS=http://<replica-ip>|<replica password>
FULL_SYNC=true
RUN_GRAVITY=true
```

If the replica's credential is an app password, the replica needs
`app_sudo = true`. On a greenfield build, deploy both Pis first, create the
passwords (see above), write the env file, then set `nebula_sync_primary`
on the primary and apply.

## Pi-hole: install and config

`templates/pihole.toml.tftpl` is a full copy of Pi-hole v6's config file
format, with the handful of fields that differ from Pi-hole's own defaults
turned into template placeholders — everything else is left as Pi-hole's
stock default, verbatim, comments included, so the file stays readable
against Pi-hole's own documentation. The fields templated out:

- `dns.upstreams` — from `pi_hosts[k].dns` (see above), via `jsonencode()`.
- `dns.hosts` — the custom internal DNS records (`local_hosts`), the actual
  reason this whole redeployment capability matters — these are what make
  Pi-hole useful here beyond generic ad-blocking. Also via `jsonencode()` —
  bare list interpolation doesn't render as valid TOML array syntax.
- `dns.interface` — from `pi_hosts[k].interface`.
- `webserver.api.app_pwhash` — from `pihole_app_pwhashes[k]` (empty when
  unset), and `webserver.api.app_sudo` — from `pi_hosts[k].app_sudo`. See
  Passwords.

Everything else (`listeningMode = "ALL"`, `webserver.api.allow_destructive
= false`, etc.) is left as a static default in the template — not
host-specific or sensitive, just a deliberate configuration choice worth
understanding rather than a variable.

`null_resource.pihole`'s install sequence, in order:

1. Push the rendered `pihole.toml` to `/etc/pihole/pihole.toml` via
   `install -D` (creates `/etc/pihole` as needed — it doesn't exist yet on
   a fresh Pi).
2. `apt-get update`.
3. `curl -sSL https://install.pi-hole.net | sudo bash -s -- --unattended`.
   The pre-seeded `pihole.toml` from step 1 is what lets `--unattended`
   actually skip interactive dialogs — Pi-hole's installer decides
   fresh-install-vs-reinstall by checking whether `pihole.toml` already
   exists. `sudo` has to come before `bash`, not after `curl`, so the
   installer runs as root directly rather than needing to self-elevate.
4. `pihole setpassword` with the plaintext `pihole_password` (see Password
   above).

## Drift detection

Pi-hole's own `pihole-FTL` daemon rewrites `pihole.toml` into its own
canonical, timestamped format on every start, so comparing it against a
Terraform-rendered file byte-for-byte (the file-hash approach the hardening
module uses for its own config files) would report drift on every single
check regardless of actual state. Instead, `data "external" "pihole"` runs
`scripts/pihole-config-check.sh`, which SSHes in and queries Pi-hole's
*live* effective config directly via `pihole-FTL --config` — the same
condition-based approach the hardening module uses for `ufw`/`static_ip` —
comparing `dns.upstreams`, `dns.interface`, and `dns.hosts` against what
`pi_hosts`/`local_hosts` expect and returning named `"true"`/`"false"`
fields.

Non-blocking, same as every other check in this project: `check
"pihole_check"` prints a warning naming the drifted Pi(s) without stopping
`apply`. Fix real drift with:

```bash
terraform apply -replace='null_resource.pihole["Site-NI-DNS01"]'
```

## Files

- `main.tf` — the `module "pi_hardening"` call,
  plus `null_resource.pihole` (install) and its `data.external`/`check`
  drift detection (see above).
- `variables.tf` — inputs for the hardening module pass-through
  (`application_ufw_*`, `fail2ban_*`, `unattended_upgrades_*`,
  `auto_upgrades_days`, `ssh_private_key_path`) plus this project's own:
  `pi_hosts`, `local_hosts` (sensitive), `pihole_password` (sensitive),
  `pihole_app_pwhashes` (sensitive), and the `nebula_sync_*` settings.
- `templates/nebula-sync.service` / `nebula-sync.timer` — the systemd units
  installed on the primary (see Nebula Sync).
- `versions.tf` — `hashicorp/null` and `hashicorp/external`.
- `templates/pihole.toml.tftpl` — see Pi-hole section above.
- `scripts/pihole-config-check.sh` — the live-config drift check described
  above; executed locally, never pushed to a Pi.
- `terraform.tfvars.example` — placeholder-only field reference; real
  values live outside the repo (see Usage above).
- `.envrc` — direnv config, points `TF_CLI_ARGS_plan`/`TF_CLI_ARGS_apply`
  at `C:\terraform-local\pihole-deploy.tfvars`. Gitignored.
