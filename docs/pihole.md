# Pi-hole — design notes

Runbook: [`terraform/pihole-deploy/README.md`](../terraform/pihole-deploy/README.md).

`pihole-deploy` exists to make the two production Pi-holes reproducible: if
either Pi needs replacing, `apply` stands up a working replacement instead of
redoing the setup by hand. The custom local DNS records are the real reason —
they're what make the Pi-holes more than generic ad-blockers.

## The template is Pi-hole's own config file

`templates/pihole.toml.tftpl` is a full copy of Pi-hole v6's `pihole.toml`,
comments included, with only the fields that differ from Pi-hole's defaults
turned into placeholders (upstreams, hosts, interface, the app password hash,
`app_sudo`). Everything else is the stock default, verbatim, so the file stays
readable against Pi-hole's documentation. Static non-default choices like
`listeningMode = "ALL"` stay static — deliberate configuration, not variables.

Lists go through `jsonencode()`: plain list interpolation isn't valid TOML.

`null_resource.pihole` runs, in order: install the rendered `pihole.toml` at
`/etc/pihole/pihole.toml` (`install -D` creates the directory on a fresh Pi),
`apt-get update`, the official installer
(`curl -sSL https://install.pi-hole.net | sudo bash -s -- --unattended`), then
`pihole setpassword`. The pre-seeded `pihole.toml` is what lets
`--unattended` skip the installer's dialogs — it decides fresh install vs
reinstall by whether that file exists. `sudo` goes before `bash`, not
`curl`, so the installer runs as root instead of trying to elevate itself.

## `dns` does double duty

Each Pi's `dns` list is both its own system resolver (via the hardening
module's `nmcli`) and Pi-hole's `dns.upstreams`. Deliberate: the Pi should
resolve through the same upstream it hands to everyone else.

## Two passwords, two mechanisms

**Web password.** Pi-hole's hash (BALLOON-SHA256) is salted, so one password
produces a different hash on each instance. A shared *hash* variable can't
express "same password on both Pis"; a shared *plaintext* one, applied with
`pihole setpassword` and hashed fresh on each Pi, can. So `pwhash` stays empty
in the template.

**App password.** Pi-hole generates it and shows it once, so it can't be
chosen in advance. What Terraform can do is carry an *existing* hash over a
rebuild, so API clients (Homepage, Nebula Sync) keep working. Each Pi-hole has
its own, and Nebula Sync doesn't copy it.

`pihole_app_pwhashes` is a separate sensitive map rather than a `pi_hosts`
field because `pi_hosts` drives `for_each`, and Terraform rejects sensitive
values there.

## Nebula Sync

Nebula Sync runs on the primary only and pushes the primary's config to the
replica hourly (full sync, including local DNS records and gravity). Changes
are therefore made on the primary; the replica's own edits would be
overwritten.

- It authenticates to the replica with the replica's credential. If that's
  an app password, the replica needs `app_sudo = true` so the session may
  change settings.
- The recipe installs a pinned release verified against its published
  SHA-256 — the hand-installed original was a locally built "dev" binary that
  a rebuild couldn't reproduce.
- Its env file holds the Pi-hole passwords, so it's pushed with `source` and
  only its hash reaches state.

## Why drift detection reads live config

`pihole-FTL` rewrites `pihole.toml` into its own canonical, timestamped format
on every start, so hashing the file would report drift on every check.
Instead the check queries the effective config (`pihole-FTL --config`) and
compares upstreams, interface and `dns.hosts`. Password fields aren't
checked, so Pi-hole writing its own hashes never shows as drift.

`dns.hosts` is the field that drifts in practice: records added by hand on the
primary (and synced to the replica) until `local_hosts` is updated to match.
