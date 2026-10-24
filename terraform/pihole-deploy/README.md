# pihole-deploy

The two production Pi-holes: a **primary** and a **replica**, hardened with
[`pi-hardening`](../modules/pi-hardening/README.md), with Pi-hole installed
from a template of its own config file and **Nebula Sync** on the primary
pushing its config to the replica hourly. Design notes:
[docs/pihole.md](../../docs/pihole.md).

Tfvars: `C:\terraform-local\pihole-deploy.tfvars` (start from
`terraform.tfvars.example`).

## Inputs

| Variable | Notes |
|----------|-------|
| `pi_hosts` | Per Pi: `static_ip`, `gateway`, `dns` (also Pi-hole's upstreams), `bootstrap_ip`; optional `interface`, `ipv6_token`, `app_sudo` (**replica**: `true`), `nebula_sync_primary` (**primary**: `true`, only one) |
| `local_hosts` | Local DNS records, `"<ip> <hostname>"` — must match what's on the primary |
| `pihole_password` | Web password, the same on both Pis (applied with `pihole setpassword`) |
| `pihole_app_pwhashes` | Each Pi's existing app password hash, keyed like `pi_hosts` — keeps API clients working across a rebuild |
| `nebula_sync_env_path` | Local env file for Nebula Sync (required with a primary) |
| `nebula_sync_version` / `nebula_sync_sha256` | Pinned release and its `linux_arm64` checksum; bump together |
| `ssh_user`, `application_ufw_*` (DNS 53 tcp/udp, 80/443), `fail2ban_*`, … | Passed to pi-hardening |

## Rebuild one Pi-hole (disaster recovery)

Do one Pi at a time, **replica before primary**; the other keeps answering
DNS. Nebula Sync logs failures until the replica is back — harmless.

1. **Before wiping it** (if it still runs), save what the recipe can't
   recreate:
   ```bash
   ssh <ssh_user>@<pi> 'sudo pihole-FTL --config webserver.api.app_pwhash'   # into pihole_app_pwhashes
   ssh <ssh_user>@<pi> 'sudo pihole-FTL --config dns.hosts'                  # compare with local_hosts
   ```
2. Flash **Raspberry Pi OS Lite (64-bit)** with the same hostname, SSH user
   and key; do [pi-hardening's prerequisites](../modules/pi-hardening/README.md#before-the-first-apply).
   Remove the old host key: `ssh-keygen -R <ip>`.
3. In the tfvars, comment out the *other* Pi's `pi_hosts` entry and set this
   Pi's `bootstrap_ip` to the address it booted with.
4. Plan — expect only this Pi's resources (6 to add; 7 on the primary, with
   Nebula Sync). Apply.
5. Uncomment the other entry again.
6. [Verify](#verify).

Rebuilding the **primary** also reinstalls Nebula Sync from the recipe —
check the env file at `nebula_sync_env_path` is current first.

## Greenfield: brand-new Pi-holes

1. Prepare both Pis as in steps 2–3 above. Set `app_sudo = true` on the
   replica; **leave `nebula_sync_primary` off** and `pihole_app_pwhashes`
   empty for now.
2. Plan and apply. Both come up with the web password and no app password.
3. **App passwords:** in each Pi-hole's web interface, create one (Settings →
   Web interface / API, expert settings → *Configure app password*; labels
   vary by version). It's shown once — store it where it's used (Homepage,
   Nebula Sync). Then copy each hash into the tfvars:
   ```bash
   ssh <ssh_user>@<pi> 'sudo pihole-FTL --config webserver.api.app_pwhash'
   ```
   ```hcl
   pihole_app_pwhashes = {
     <pi_hosts key> = "<hash>"
   }
   ```
4. **Nebula Sync:** write the env file (keep it outside the repo):
   ```ini
   PRIMARY=http://<primary-ip>|<primary web or app password>
   REPLICAS=http://<replica-ip>|<replica app password>
   FULL_SYNC=true
   RUN_GRAVITY=true
   ```
   Set `nebula_sync_primary = true` on the primary.
5. Plan and apply. Adding the hashes changes the rendered config, so each
   Pi's Pi-hole step re-runs (same values, so safe).

## Day to day

- **New local DNS record:** add it on the **primary** (web interface → Local
  DNS); Nebula Sync copies it within the hour. Add it to `local_hosts` too,
  or the drift check warns.
- **Drift warning** on `hosts`/`dns`/`interface`:
  `terraform apply -replace='null_resource.pihole["<key>"]'` rewrites the
  config — make sure `local_hosts` is current first, or records are lost.
- **Testing a change on a spare Pi:** *add* it to `pi_hosts`; never replace
  the production entries (it drops them from state — see
  [lessons learned](../../docs/lessons-learned.md)).

## Verify

```bash
nslookup <a local record> <pi-ip>          # local DNS answers
nslookup example.com <pi-ip>               # upstream resolution works
ssh <ssh_user>@<pi> 'pihole -v; sudo pihole-FTL --config webserver.api.app_sudo'
# on the primary: run a sync now and read the result
ssh <ssh_user>@<primary> 'sudo systemctl start nebula-sync.service; journalctl -u nebula-sync -n 5 -o cat'
```

A healthy sync ends with `Sync completed`; afterwards
`sudo pihole-FTL --config dns.hosts` matches on both Pis.
