# internal-traefik-deploy

Traefik on the **LAN-only** Pi: reverse proxy for internal services, with
real Let's Encrypt certificates via DNS-01. One call to
[`traefik-node`](../modules/traefik-node/README.md) (inputs, token,
dashboard); design notes in [docs/traefik.md](../../docs/traefik.md).

Tfvars: `C:\terraform-local\internal-traefik-deploy.tfvars` (start from
`terraform.tfvars.example`).

## Build or rebuild

1. Flash Raspberry Pi OS Lite (64-bit) with the SSH user and key; do
   [pi-hardening's prerequisites](../modules/pi-hardening/README.md#before-the-first-apply).
   Set `bootstrap_ip` to the address it boots with.
2. Make sure the Cloudflare token file and the dashboard htpasswd file exist
   in `C:\terraform-local\`.
3. `terraform plan -out=...`, read it, apply it.
4. **DNS:** every `services` hostname and `dashboard_hostname` resolves to
   this Pi's `static_ip` on the LAN's DNS (Pi-hole local records) — **no**
   public record. Cloudflare only needs to answer the ACME TXT challenge.

## Verify

```bash
ssh <ssh_user>@<static_ip> 'docker ps --format "{{.Names}} {{.Status}}"; ls /etc/traefik/dynamic'
curl -s -o /dev/null -w '%{http_code}\n' https://<a service hostname>/
```

A new hostname's certificate takes a minute or so to be issued after its
route is added.
