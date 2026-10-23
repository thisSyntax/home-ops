# traefik-node

Child module for **one** Pi: runs `pi-hardening`, installs Docker, and runs
Traefik in a container with routes from `services`. Called by
`internal-traefik-deploy` and `external-traefik-deploy`; never applied
directly. Why it's built this way: [docs/traefik.md](../../../docs/traefik.md).

Prerequisites are pi-hardening's ([before the first apply](../pi-hardening/README.md#before-the-first-apply)).
Docker is reached over the same SSH user and key.

## Inputs

| Variable | Default | Notes |
|----------|---------|-------|
| `pi_key`, `static_ip`, `gateway`, `dns`, `bootstrap_ip`, `interface` | `interface`: `eth0` | Passed to pi-hardening |
| `services` | — | Map: `hostname` (a real name in the Cloudflare zone), `target_url` (with `http://`), `entrypoint` (`websecure`), optional `request_headers` (map; `""` removes a header) |
| `acme_email` | — | Let's Encrypt contact |
| `cf_api_token_path` | — | Local file holding only the Cloudflare token |
| `use_acme` | `true` | `false` only for a manually supplied cert |
| `config_path` | `/etc/traefik` | |
| `dashboard_enabled` | `false` | |
| `dashboard_hostname` | — | Required with the dashboard |
| `dashboard_htpasswd_path` | — | Local htpasswd file; required with the dashboard |
| `dashboard_allowed_ips` | `[]` (any) | Source CIDRs allowed before the login — **set it on an internet-facing Pi** |
| `ssh_user`, `ssh_private_key_path`, `fail2ban_*`, `unattended_upgrades_*`, `auto_upgrades_days` | | Passed to pi-hardening |

## Cloudflare token (one per Pi)

1. Cloudflare → **My Profile → API Tokens → Create Token** → template
   **Edit zone DNS**, Zone Resources limited to the one zone.
2. Name it after the Pi; save the token alone (no quotes) in
   `C:\terraform-local\` and point `cf_api_token_path` at it.

**Rotate:** replace the file's contents, plan and apply (the new file is
pushed), then `docker restart traefik` on the Pi — the container isn't
recreated for a token change.

## Dashboard credentials

htpasswd format, e.g. `htpasswd -nB <user>` (or
`docker run --rm httpd:alpine htpasswd -nbB <user> '<password>'`). Both Pis
can share one file. The UI is at `https://<dashboard_hostname>/dashboard/` —
trailing slash required.

## What a change does on the Pi

| Change | Effect |
|--------|--------|
| A route (`services`) | its file in `dynamic/` is rewritten; picked up live |
| Dashboard settings | `dynamic/dashboard.yml` rewritten; live |
| Static config (`acme_email`, `dashboard_enabled`) | container **recreated** — a few seconds of downtime |
| Token file | pushed; needs `docker restart traefik` |

Before applying a template change, check that unchanged routes render
byte-for-byte as before — see [lessons learned](../../../docs/lessons-learned.md).
When this module's `variables.tf` changes, copy it to both root modules.
