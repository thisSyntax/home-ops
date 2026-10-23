# home-ops

Terraform that hardens and configures my home Raspberry Pi fleet over SSH —
Pi-hole DNS and two Traefik reverse proxies — plus an early k3s-on-Proxmox
project. A learning project, run against real hardware. The *why* behind it
lives in [`docs/`](docs/README.md); the READMEs are runbooks.

```
terraform/
├── modules/
│   ├── pi-hardening/          static IP, UFW, Fail2Ban, no X11 forwarding, unattended-upgrades
│   └── traefik-node/          pi-hardening + Docker + a Traefik container, for one Pi
├── pihole-deploy/             Pi-hole on the primary + replica (Nebula Sync between them)
├── internal-traefik-deploy/   Traefik on the LAN-only Pi
├── external-traefik-deploy/   Traefik on the internet-facing (DMZ) Pi
└── k3s-deploy/                early / in progress: k3s VMs on Proxmox
docs/                          design notes and lessons learned
```

Each project under `terraform/` is applied on its own, with its own state.
Modules are never applied directly.

## Set up a machine to run it

1. **Tools:** Terraform ≥ 1.5, Git for Windows (Git Bash at
   `C:\Program Files\Git\usr\bin\bash.exe` — the drift checks call it by that
   path), and [direnv](https://direnv.net/).
2. **direnv in Git Bash:** add `eval "$(direnv hook bash)"` to `~/.bashrc`, and
   make sure `~/.bash_profile` sources `~/.bashrc` (Git Bash offers to create
   it). Run Terraform from **Git Bash, not PowerShell**.
3. **Secrets, outside the repo:** create `C:\terraform-local\` with one
   `<project>.tfvars` per project (start from that project's
   `terraform.tfvars.example`) plus the files they point at:

   | File | Used by |
   |------|---------|
   | `cf-token.txt`, `cf-token-external.txt` | one Cloudflare token per Traefik Pi |
   | `dashboard-users.txt` | htpasswd shared by both Traefik dashboards |
   | `nebula-sync.env` | Nebula Sync on the primary Pi-hole |

4. **SSH key** (`~/.ssh/id_ed25519`) trusted on every Pi.
5. In each project directory, run `direnv allow` once and `terraform init`.

## Workflow

```bash
cd terraform/<project>          # .envrc points plan/apply at C:\terraform-local\<project>.tfvars
terraform plan -out=C:/terraform-local/<project>.tfplan
terraform apply C:/terraform-local/<project>.tfplan
rm C:/terraform-local/<project>.tfplan     # plan files hold variable values, sensitive ones too
```

- **`apply` is live.** It SSHes into real Pis, installs packages, rewrites
  config, restarts services and can change a Pi's IP. Read the plan.
- Drift checks run on every plan/apply and only **warn**. Fix drift with
  `terraform apply -replace='<resource address>'`.
- No CI. `terraform fmt -recursive -check` and `terraform validate` before
  committing.

## Build order (greenfield or disaster recovery)

| Step | Project | Needs first |
|------|---------|-------------|
| 1 | [pihole-deploy](terraform/pihole-deploy/README.md) | DNS for everything else. Replica, then primary |
| 2 | [internal-traefik-deploy](terraform/internal-traefik-deploy/README.md) | Pi-hole records pointing its hostnames at it |
| 3 | [external-traefik-deploy](terraform/external-traefik-deploy/README.md) | The router's port-forward for 443 to it |

Every Pi first needs a fresh **Raspberry Pi OS Lite (64-bit)** image with the
SSH user and key set in Raspberry Pi Imager, plus passwordless sudo — see
[pi-hardening's prerequisites](terraform/modules/pi-hardening/README.md#before-the-first-apply).
To rebuild a single Pi, follow its project's runbook; the others are
unaffected.

## Conventions

- `terraform fmt` style (2-space indent). `.gitattributes` forces LF line
  endings — templates are rendered byte-for-byte onto the Pis.
- After editing a template, check that existing resources render unchanged;
  see [lessons learned](docs/lessons-learned.md).
- This repo is public: nothing from `C:\terraform-local\`, no real
  hostnames, IPs or hashes. Scan the diff before committing.
