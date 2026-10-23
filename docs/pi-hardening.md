# pi-hardening — design notes

Runbook: [`terraform/modules/pi-hardening/README.md`](../terraform/modules/pi-hardening/README.md).

The module started inside a Caddy reverse-proxy project (since removed —
Traefik replaced Caddy) and was split out so every Pi project reuses the same
baseline instead of re-implementing it.

## Resource order

```
static_ip
  ├─ disable_x11_forwarding
  └─ ufw
       └─ fail2ban
            └─ unattended_upgrades
```

`disable_x11_forwarding` and `ufw` only depend on `static_ip` and run in
parallel. `ufw`, `fail2ban` and `unattended_upgrades` are serialized on
purpose: all three call `apt-get`, and two concurrent `apt-get` runs on one
Pi race for the dpkg lock.

A calling root module depends on the *whole* module
(`depends_on = [module.pi_hardening]`) rather than on a resource inside it —
child-module internals aren't addressable from outside.

## The static-IP step is supposed to look like it fails

`nmcli con up` re-applies the connection profile, and the moment the IP
changes it tears down the SSH session Terraform is running over. The change
has succeeded; Terraform just never reads the exit code. `on_failure =
continue` on that provisioner lets the apply carry on to the next resources,
which connect at `static_ip` instead of `bootstrap_ip`.

The catch: the same setting hides *real* failures in that step. If the SSH
user lacks passwordless sudo, the step fails immediately — and is recorded as
created anyway. That's why the sudo prerequisite is checked before any apply.

### Optional fixed IPv6 interface ID

`ipv6_token` (e.g. `"::53"`) adds `ipv6.method auto`, `addr-gen-mode eui64`
and `ipv6.token` to the same script, giving `<router-advertised /64>::53` — a
predictable address that follows the ISP prefix if it changes. NetworkManager
only applies a token to eui64-generated addresses, hence the mode.

It's merged into the `static_ip` triggers only when set, so hosts without one
keep identical triggers — adding the field didn't re-run the step (and drop
SSH) on every Pi. The drift check reads it with `nmcli -e no -g`; plain `-g`
escapes colons (`\:\:53`).

## No reboot resource

`unattended-upgrades` reboots a Pi itself, only when an installed update
needs it (`unattended_upgrades_auto_reboot`, `..._time`). Rebooting on every
apply would take a Pi down for any trivial config change.

## unattended-upgrades

`auto_upgrades_days` sets how often `20auto-upgrades` lets the daily apt job
actually run when its timer fires; the timer's own schedule is untouched.

The step ends with `unattended-upgrade --dry-run --debug`, which fails the
apply if the rendered `Origins-Pattern` matches nothing the Pi's repos
advertise — fail loud on bad config. A clean dry-run with nothing pending
proves little; the `Allowed origins are: ...` line in its output shows it's
parsing real repo metadata.

## UFW: one app profile per Pi

`application_ufw_*` defines the single UFW app profile the module opens, named
generically so any app can use it. All three are optional — a caller with no
port to open keeps only the default-deny-incoming baseline. More than one
profile per Pi would need the module extending.

Docker-published ports bypass UFW entirely (Docker writes its own `iptables`
rules that never traverse UFW's `INPUT` chain), which is why `traefik-node`
doesn't pass these variables.

## Idempotency

`apt-get install` of an installed package, `nmcli con mod` with the same
values and `ufw allow` of an existing rule are all no-ops. Config files are
only rewritten when their rendered content changes (tracked in `triggers`,
mostly via the shared `locals` block), so a repeat apply with no variable
changes plans clean.

## Passwordless sudo: why `ALL`

Scoping `NOPASSWD` to just the commands the module runs is more conservative
but fragile (exact paths, per-command argument wildcards). `ALL` is the
pragmatic default for a single-user home-lab Pi.
