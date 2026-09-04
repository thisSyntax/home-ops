# pi-hardening

Reusable Terraform module that hardens a Raspberry Pi over SSH: static IP
via `nmcli`, disabled SSH X11 forwarding, UFW, Fail2Ban, and
unattended-upgrades. Originally written as part of a Caddy reverse-proxy
project (see `../../caddy-deploy`), then split out here so any future
Raspberry Pi project can reuse the same base hardening instead of
re-implementing it.

This is a **child module** — it has no state or `terraform.tfvars` of its
own and is never applied directly. A root module calls it:

```hcl
module "pi_hardening" {
    source = "../modules/pi-hardening"

    pi_hosts = {
        my-pi = {
            static_ip    = "192.168.1.50"
            gateway      = "192.168.1.1"
            bootstrap_ip = "192.168.1.200"   # the Pi's current IP before this apply
            # dns and interface are optional; see variables.tf for defaults
        }
    }
    ssh_user                     = "piuser"
    application_ufw_name         = "MyApp"
    application_ufw_description  = "My application"
    application_ufw_ports        = ["8080/tcp"]
}
```

The Pi itself isn't provisioned by Terraform — it already exists as physical
hardware. This module is pure SSH-driven configuration management via
`null_resource` + `remote-exec`, not a typed-resource cloud deployment.

## Prerequisites

- Raspberry Pi OS (or another Debian derivative) with `apt` and
  NetworkManager (`nmcli`) — the default on current Raspberry Pi OS images.
- SSH key auth already trusted on each Pi for `ssh_user` (this module does
  not bootstrap SSH keys).
- `ssh_user` has passwordless `sudo` for at least `apt-get`, `ufw`,
  `systemctl`, `nmcli`, `install`, `fail2ban-client`, and
  `unattended-upgrade`. Without that, every `remote-exec` provisioner fails
  immediately on `sudo: a password is required` — and if that failure
  happens inside a provisioner with `on_failure = continue` (the static-IP
  step is the one place this module has that), Terraform can't tell that
  apart from the *expected* reason that provisioner can fail (see "The
  static-IP step is *supposed* to look like it fails" below), so the
  resource still gets recorded as successfully created even though nothing
  actually happened on the Pi.

  Set this up once per Pi, over an interactive SSH session — this needs the
  account's real login password, which Terraform never has and can't supply
  non-interactively:

  ```bash
  ssh piuser@<pi-ip>
  sudo visudo -f /etc/sudoers.d/piuser-nopasswd
  ```

  Add one line, then save and exit (`visudo` validates the syntax before
  writing the file, so a typo can't lock `sudo` out entirely):

  ```
  piuser ALL=(ALL) NOPASSWD: ALL
  ```

  Confirm it worked without leaving the session: `sudo -n true && echo ok`.
  Scoping the `NOPASSWD` entry to just the commands this module actually
  runs, instead of `ALL`, is more conservative but noticeably more fragile
  to get right (exact paths, wildcard argument matching per command) — `ALL`
  is what's shown here as the pragmatic default for a home-lab Pi that isn't
  multi-tenant.
- Terraform >= 1.5 — required for `check` blocks (see Drift detection
  below), not just recommended.
- **Windows only**: Git for Windows installed at
  `C:\Program Files\Git\usr\bin\bash.exe`. Every `data "external"` block in
  `main.tf` invokes the drift-check scripts via that exact path rather than
  a bare `"bash"` — if WSL is also installed, a bare `"bash"` can resolve to
  WSL's `C:\Windows\System32\bash.exe` instead, which is a different
  filesystem where Windows-style paths (like the SSH key path) don't
  resolve. If your Git for Windows lives somewhere else, update the
  `program` path in every `data "external"` block to match.

## What it applies, and in what order

```
static_ip
  ├─ disable_x11_forwarding
  └─ ufw
       └─ fail2ban
            └─ unattended_upgrades
```

`disable_x11_forwarding` and `ufw` only depend on `static_ip` and can run in
parallel. Everything from `ufw` onward is serialized on purpose: `ufw`,
`fail2ban`, and `unattended_upgrades` all call `apt-get`, and two concurrent
`apt-get` invocations on the same Pi would race on the dpkg lock. A caller
that adds its own resources on top (installing an actual application)
should depend on the whole module — `depends_on = [module.pi_hardening]` —
rather than on any resource inside it, since child-module internals aren't
addressable from outside.

## UFW is app-agnostic, not Caddy-specific

`application_ufw_name`, `application_ufw_description`, and
`application_ufw_ports` control the *one* UFW app profile this module opens
for whatever's running on the Pi — named generically so any caller can
point it at any app, not just Caddy. All three are optional: a caller with
no app-specific port to open (e.g. `traefik-node`, whose ports are
Docker-published and bypass UFW entirely) can omit them, leaving the
module's default-deny-incoming baseline as the only UFW config it applies.
If a Pi needs more than one UFW-opened application, this module would need
extending (currently only supports one profile per Pi).

## The static-IP step is *supposed* to look like it fails

`nmcli con up` re-applies the connection profile — the moment the IP
actually changes, it tears down the SSH session Terraform is running the
command over. The change has already succeeded on the Pi; Terraform just
never gets to read the exit code. `on_failure = continue` on that
provisioner is what lets `apply` carry on to the resources after it, which
connect at `static_ip` instead of `bootstrap_ip`.

If a Pi is already sitting at its target `static_ip` (re-running this
against an already-hardened Pi), set `bootstrap_ip == static_ip` — the
script still runs but changes nothing.

There's no separate reboot resource. `unattended_upgrades` reboots each Pi
itself, autonomously, only when an installed update actually requires it —
see `unattended_upgrades_auto_reboot` / `unattended_upgrades_auto_reboot_time`
in `variables.tf`. Rebooting a Pi unconditionally on *every* `apply` (an
option some designs use to guarantee any pending change takes effect) would
mean a trivial config tweak takes the Pi down for a reboot cycle every
time — letting the OS decide when a reboot is actually needed avoids that.

## unattended-upgrades

`unattended_upgrades_auto_reboot` (default `true`) and
`unattended_upgrades_auto_reboot_time` (default `"03:00"`) control whether
and when the Pi reboots itself if an installed update needs it — handled
entirely by `unattended-upgrades` on the Pi, not by Terraform.
`auto_upgrades_days` (default `1`) controls how often
`/etc/apt/apt.conf.d/20auto-upgrades` tells the daily apt-upgrade job to
actually run when its systemd timer fires — the timer's own schedule is
unrelated and untouched by this module.

The resource's `remote-exec` ends with `unattended-upgrade --dry-run --debug`,
which fails the `apply` if the rendered `Origins-Pattern` doesn't actually
match anything the Pi's configured repos advertise — the same "fail loud on
bad config" philosophy `caddy-deploy` uses for `caddy validate`. A clean
dry-run with zero matching packages doesn't prove much on its own (nothing
may be pending); check the `--debug` output's `Allowed origins are: ...`
line to confirm it's parsing real repo metadata, not silently matching
nothing.

## Idempotency

- `apt-get install` on an already-installed package is a no-op.
- `nmcli con mod` on an already-correct connection is a no-op.
- `ufw allow` on an already-present rule is a no-op (UFW dedupes).
- The UFW app profile, Fail2Ban jail, sshd drop-in, and unattended-upgrades
  conf files are only rewritten when their rendered content actually
  changes (tracked via the `triggers` block on each resource, most of which
  reference the shared `locals` block at the top of `main.tf`), so a repeat
  `apply` with no var changes plans clean.

## Drift detection

Every resource has a matching `data "external"` + `check` block placed
right before it in `main.tf`. On every `plan`/`apply`, each one SSHes into
its Pi, reads the *live* state, and reports — without blocking anything —
if it's drifted from what Terraform expects.

Two different comparison strategies, depending on what's actually
drift-relevant for that resource:

- **File-hash checks** (`fail2ban`, `disable_x11_forwarding`,
  `unattended_upgrades`) use the shared `scripts/remote-file-hash.sh` —
  SSHes in, hashes the deployed file, compares it against a hash Terraform
  computes locally from the same `templatefile()` call that renders it (see
  the `locals` block at the top of `main.tf`).
- **Condition checks** (`ufw`, `static_ip`) don't have a file to hash — UFW's
  actual drift-relevant state is its live rule table (`ufw status verbose`),
  not the static app-profile file, and static IP's is the interface's
  actual live address/gateway/DNS/method (`nmcli`), not something rendered
  locally. `scripts/ufw-status-check.sh` and `scripts/static-ip-check.sh`
  each check specific conditions and return named `"true"`/`"false"` fields
  instead of a single hash.

`scripts/` (executed locally, on whatever machine runs `terraform plan`) is
deliberately separate from `templates/` (assets rendered and pushed *to* a
Pi) — different roles, even though both are just files on disk here.

**These checks are informational, not enforcement.** A failed `check`
prints a `Warning:` naming the specific Pi(s) that drifted — it never
blocks `apply`, taints a resource, or fixes anything automatically. To
actually fix detected drift, force the affected resource to re-run
regardless of whether its own `triggers` changed, from the *calling* root
module (module resources are addressed with a `module.` prefix):

```bash
terraform apply -replace='module.pi_hardening.null_resource.ufw["my-pi"]'
```

**Known timing gotcha:** `check` blocks don't support `for_each`, so these
`data "external"` blocks live at the top level of `main.tf` rather than
nested inside their `check` (nesting would mean giving up per-Pi checking
entirely). The cost: a data source nested inside `check` gets a special
guarantee — Terraform reads it as the *last* step of an apply, specifically
so it reflects post-apply reality — and a top-level one doesn't get that
guarantee. In practice, an `apply -replace` that genuinely fixes drift can
still record that check as `"fail"` in *that same apply's* output and in
`terraform.tfstate`'s `check_results`, because the data source was read
before the fix landed. A plain follow-up `terraform apply` — now reading
against the already-fixed state — is what actually records an accurate
pass.

## Why null_resource + remote-exec, and when to outgrow it

There's no Terraform provider that models "a UFW rule on an arbitrary SSH
host" as a real managed resource — Pis aren't something Terraform
provisions, they already exist. `null_resource` + `remote-exec` is the
standard workaround: Terraform driving imperative SSH commands, which is a
thinner abstraction than a purpose-built config-management tool. A few
sharp edges worth knowing because of that:

- `null_resource` still has no real `Read`. Drift *detection* now exists
  (see above), but it's a hand-built workaround layered on top via
  `data "external"` + `check` — nothing about it is native to the resource
  type, and detection isn't correction: a failed check doesn't self-heal
  anything. Ansible's `ufw` module, by contrast, checks and reconciles
  actual state on every run without needing any of this scaffolding.
- The SSH-session-survives-its-own-IP-change problem above wouldn't exist
  with Ansible, which reconnects between plays rather than depending on one
  unbroken SSH pipe.
- `terraform plan` can't tell you what a `remote-exec` block will actually
  do — it's opaque shell, not a typed resource diff.

Good enough for learning Terraform's `for_each`/`depends_on`/provisioner/
`data`/`check`/module mechanics against real infrastructure. If this
pattern starts feeling constraining, Ansible is the natural next step, and
this module's `templates/` files translate almost directly into Ansible
task content.

## Files

- `main.tf` — the five hardening `null_resource`s (static IP, disabled X11
  forwarding, UFW, Fail2Ban, unattended-upgrades), one instance per host in
  `pi_hosts` via `for_each`. Each is paired with a `data "external"` +
  `check` block for drift detection. A `locals` block at the top computes
  each resource's expected config hash once, shared between its own
  `triggers` and its drift check.
- `variables.tf` — all inputs: the leaner `pi_hosts` map (no `role`/`sites`
  — those are `caddy-deploy`-specific, not hardening concerns), `ssh_user`,
  `ssh_private_key_path`, the `application_ufw_*` UFW profile settings, the
  `fail2ban_*` tunables, and the `unattended_upgrades_*`/`auto_upgrades_days`
  tunables.
- `versions.tf` — `hashicorp/null` and `hashicorp/external` (the latter
  used by the drift-detection `data` sources).
- `templates/` — config files rendered and pushed *to* a Pi (UFW app
  profile, Fail2Ban jail, static-IP script, the two unattended-upgrades
  conf files) plus the static sshd drop-in.
- `scripts/` — helper scripts executed *locally* by the drift-detection
  `data "external"` blocks (never pushed to a Pi).

No `terraform.tfvars`/`terraform.tfvars.example` here — this module takes
its inputs as arguments in the calling root module's `module` block, not
from its own tfvars file.
