# Lessons learned

Things that went wrong once, and the habits that came out of them.

## Replacing `pi_hosts` entries for a test dropped production from state

A test of `pihole-deploy` replaced the production entries in `pi_hosts` with
a test Pi. The plan showed the production resources as "destroy" — but
destroying a `null_resource` does nothing on the Pi, so the Pi-holes kept
running and nobody noticed that Terraform had forgotten them.

**Habit:** add a test host to `pi_hosts`, or use a separate directory or
workspace; never replace production entries. Re-adopting a Pi means
re-running its whole recipe, so it was done replica first, after making the
template reproduce production exactly.

## CRLF line endings changed every rendered config

Git for Windows' default `core.autocrlf=true` checked the repo out with CRLF.
Templates render byte-for-byte onto the Pis, so `\r` would have gone into
every Traefik route and `pihole.toml`, and the changed hashes made the plan
want to replace every route at once.

**Habit:** `.gitattributes` forces LF (`* text=auto eol=lf`). If a plan
unexpectedly wants to replace everything, check templates for `\r` first.

## Template whitespace and new optional fields

Adding an optional feature to a template must leave existing output
byte-identical, or every resource rendered from it is replaced. `%{ }`
directives with `~` strip the following newline, but spaces *before* a
directive are output literally.

**Habit:** after editing a template, render it with `terraform console` for an
existing instance and compare `md5()` with the `content_hash` trigger in
state (`terraform state show`). Expect the plan to touch only the instances
that use the new feature.

## A new object field silently disappeared

A field added to `traefik-node`'s `services` type had no effect: the root
modules still declared the old type, and Terraform drops undeclared object
attributes during conversion without an error.

**Habit:** copy the module's `variables.tf` to both Traefik roots whenever it
changes, and confirm new values with `terraform console` before planning.

## A fresh Pi OS image has no passwordless sudo

Raspberry Pi Imager's first user isn't given `NOPASSWD`. Combined with the
static-IP step's `on_failure = continue`, an apply would record that step as
created without doing anything.

**Habit:** the sudoers prerequisite in the pi-hardening runbook, then confirm
`sudo -n true` before the first plan.

## The DNS cache kept a modem's answers after a restart

While the ISP gateway restarted, it answered DNS with its own address, and
caches (a Pi-hole, Windows) kept those answers — sites resolved to the modem's
login page afterwards.

**Habit:** after an upstream outage, flush the Pi-hole cache
(`pihole reloaddns`) and client caches before debugging further.

## Smaller ones

- `nmcli -g` escapes colons in IPv6 tokens; read them with `nmcli -e no -g`.
- A plan file contains variable values, sensitive ones included — save plans
  to `C:\terraform-local\` and delete them after applying.
- `terraform fmt` doesn't format `.tftpl` files; check those by rendering.
