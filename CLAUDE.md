# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Terraform for a home Raspberry Pi fleet (Pi-hole DNS, two Traefik reverse proxies) plus an early k3s-on-Proxmox project. A personal learning project run against real hardware.

- **Runbooks:** the root `README.md` (machine setup, workflow, build order for greenfield/DR) and each project/module README.
- **Why things are built the way they are:** `docs/` — start at `docs/README.md`. `docs/lessons-learned.md` lists past incidents; read it before changing templates, `pi_hosts` or variable types.

## How Claude Code is used here

**Write Terraform/Kubernetes code only when explicitly asked to.** Otherwise the role is documentation and guidance: help find what's next, explain how a pattern or resource works, review code the user writes, run read-only verification (`terraform validate`/`plan`), and diagnose issues — but let the user write the actual `.tf`/config changes. Live infrastructure debugging (SSH, checking real Pi state, fixing a live misconfiguration) is a different mode where taking direct action is expected. Documentation (READMEs, `docs/`, examples) can be edited directly.

## Rules

- **The repo is public.** Never copy anything from `C:\terraform-local\` (tfvars, tokens, htpasswd, env files), real hostnames, IPs, the domain, or password hashes into it. Secret-scan `git diff` plus untracked files before every commit. Examples use placeholders (`192.168.1.x`, `example.com`).
- **`apply` is live** — it SSHes into real Pis and changes them. Plan with `-out` to `C:\terraform-local\`, have the user approve, apply that file, delete it.
- **Template changes:** existing resources must render byte-for-byte as before. Render with `terraform console`, compare `md5()` with the `content_hash` triggers in state, and expect the plan to touch only instances using the new feature.
- **`modules/traefik-node/variables.tf` changes:** copy it to both Traefik root modules — a root that doesn't declare a new object field drops it silently.
- **Never replace production entries in `pihole-deploy`'s `pi_hosts`** to test something — add a host instead. Rebuild production replica first.
- Line endings are LF (`.gitattributes`); style is `terraform fmt`. If a plan unexpectedly wants to replace everything, check templates for `\r`.
- Projects run from Git Bash with direnv (`.envrc` → `C:\terraform-local\<project>.tfvars`). From another shell, pass `-var-file=C:/terraform-local/<project>.tfvars`.

## Current state

- `pihole-deploy`: the replica has been rebuilt on Pi OS Lite and is in state; the primary is still on the desktop image and not yet re-adopted (its `pi_hosts` entry is commented out in the tfvars).
- Both Traefik Pis are deployed; the external one's dashboard is enabled, LAN-only.
- IPv6 is disabled at the router, so the Pi-holes' `ipv6_token` values are inert.
- `k3s-deploy` is an early draft (see its README's known issues).
