# pi-hardening

Child module that hardens Raspberry Pis over SSH: static IP (`nmcli`), SSH X11
forwarding off, UFW, Fail2Ban and unattended-upgrades. Called by
`pihole-deploy` and `traefik-node`; never applied directly. Why it's built
this way: [docs/pi-hardening.md](../../../docs/pi-hardening.md).

```hcl
module "pi_hardening" {
  source = "../modules/pi-hardening"

  pi_hosts = {
    my-pi = {
      static_ip    = "192.168.1.50"
      gateway      = "192.168.1.1"
      dns          = ["1.1.1.1", "1.0.0.1"]
      bootstrap_ip = "192.168.1.200" # the Pi's address before this apply
    }
  }
  ssh_user                    = "piuser"
  application_ufw_name        = "MyApp"
  application_ufw_description = "My application"
  application_ufw_ports       = ["8080/tcp"]
}
```

## Before the first apply

On each Pi (Raspberry Pi OS / Debian with NetworkManager):

1. Your SSH key is trusted for `ssh_user` (the module doesn't bootstrap keys).
2. **Passwordless sudo** — fresh Pi OS images don't have it. Over an
   interactive SSH session:
   ```bash
   sudo visudo -f /etc/sudoers.d/piuser-nopasswd
   # add:  piuser ALL=(ALL) NOPASSWD: ALL
   sudo -n true && echo ok
   ```
   Without it, the static-IP step fails *silently* — it's allowed to fail
   (see below), so Terraform records it as created.

## Inputs

| Variable | Default | Notes |
|----------|---------|-------|
| `pi_hosts` | — | Map of Pis. Each: `static_ip`, `gateway`, `dns`, `bootstrap_ip`; optional `interface` (`eth0`), `ipv6_token` (e.g. `"::53"`) |
| `ssh_user` | — | Needs passwordless sudo |
| `ssh_private_key_path` | `~/.ssh/id_ed25519` | |
| `application_ufw_name` / `_description` / `_ports` | none | One UFW app profile to open; omit for none |
| `fail2ban_maxretry` / `_bantime` / `_findtime` | `4` / `1h` / `10m` | SSH jail |
| `unattended_upgrades_auto_reboot` / `_time` | `true` / `03:00` | Reboot only when an update needs it |
| `auto_upgrades_days` | `1` | |

## Things to know while applying

- **The static-IP step looks like it fails** — changing the IP kills its own
  SSH session. That's expected; the apply carries on at `static_ip`.
- **Re-running against a Pi already at its address:** set
  `bootstrap_ip = static_ip`.
- **`ipv6_token`** only produces an address if the router advertises an IPv6
  prefix on that network.

## Drift

Each resource has a check that warns on drift (file hashes, `ufw status`,
`nmcli`). Fix from the calling root module:

```bash
terraform apply -replace='module.pi_hardening.null_resource.ufw["my-pi"]'
```

A fix can still show the check as failed in that same apply; the next plain
apply records the pass.
