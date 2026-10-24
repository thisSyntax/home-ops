# external-traefik-deploy

Traefik on the **internet-facing** Pi (DMZ): the public entry point for the
services that are exposed. One call to
[`traefik-node`](../modules/traefik-node/README.md) (inputs, token,
dashboard); design notes in [docs/traefik.md](../../docs/traefik.md).

Tfvars: `C:\terraform-local\external-traefik-deploy.tfvars` (start from
`terraform.tfvars.example`).

## Build or rebuild

1. Flash Raspberry Pi OS Lite (64-bit) with the SSH user and key; do
   [pi-hardening's prerequisites](../modules/pi-hardening/README.md#before-the-first-apply).
   Set `bootstrap_ip` to the address it boots with.
2. Make sure this Pi's own Cloudflare token file (`cf-token-external.txt`) and
   the dashboard htpasswd file exist in `C:\terraform-local\`.
3. **Dashboard:** if enabled, `dashboard_allowed_ips` must list the LAN
   ranges — the dashboard shares the public 443 entrypoint.
4. `terraform plan -out=...`, read it, apply it. Public services are down
   from the moment the old proxy stops until this apply finishes.
5. **Outside Terraform:** the router forwards WAN 443 (and 80, which
   redirects) to this Pi; public DNS for each hostname points at the WAN
   address. Any route used by an auth-proxy header elsewhere should blank
   that header here (`request_headers = { "<header>" = "" }`).

## Verify

```bash
ssh <ssh_user>@<static_ip> 'docker ps --format "{{.Names}} {{.Status}}"'
curl -s -o /dev/null -w '%{http_code}\n' https://<a public hostname>/     # from outside, or via public DNS
```

The dashboard should answer only from the LAN; from anywhere else it returns
403 before any login prompt.
