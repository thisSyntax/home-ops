# docs

The *why* behind this repo. The READMEs next to the code are runbooks — what
to set and how to build or rebuild something. These pages explain the design
decisions behind them, so the runbooks can stay short.

| Page | Covers |
|------|--------|
| [design-overview.md](design-overview.md) | Cross-cutting patterns: SSH-driven `null_resource` config management, drift detection with `check` blocks, where secrets live, when to outgrow the approach |
| [pi-hardening.md](pi-hardening.md) | The hardening module: resource ordering, the static-IP step, reboots, unattended-upgrades, UFW scope, idempotency |
| [traefik.md](traefik.md) | One Pi per root module, DNS-01 certificates, the Cloudflare token file, the dashboard, request headers, config reload behaviour |
| [pihole.md](pihole.md) | The template approach, the password model, Nebula Sync, why drift detection reads live config |
| [lessons-learned.md](lessons-learned.md) | Things that went wrong once, and the habits that came out of them |
