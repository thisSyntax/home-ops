locals {
  pihole_hashes = {
    for k, v in var.pi_hosts : k => md5(templatefile("${path.module}/templates/pihole.toml.tftpl", {
      dns        = v.dns
      hosts      = var.local_hosts
      interface  = v.interface
      app_pwhash = lookup(var.pihole_app_pwhashes, k, "")
      app_sudo   = v.app_sudo
    }))
  }
}

module "pi_hardening" {
  source = "../modules/pi-hardening"

  pi_hosts = {
    for k, v in var.pi_hosts : k => {
      static_ip    = v.static_ip
      gateway      = v.gateway
      dns          = v.dns
      interface    = v.interface
      bootstrap_ip = v.bootstrap_ip
      ipv6_token   = v.ipv6_token
    }
  }
  ssh_user                             = var.ssh_user
  ssh_private_key_path                 = var.ssh_private_key_path
  application_ufw_name                 = var.application_ufw_name
  application_ufw_description          = var.application_ufw_description
  application_ufw_ports                = var.application_ufw_ports
  fail2ban_maxretry                    = var.fail2ban_maxretry
  fail2ban_bantime                     = var.fail2ban_bantime
  fail2ban_findtime                    = var.fail2ban_findtime
  unattended_upgrades_auto_reboot      = var.unattended_upgrades_auto_reboot
  unattended_upgrades_auto_reboot_time = var.unattended_upgrades_auto_reboot_time
  auto_upgrades_days                   = var.auto_upgrades_days
}

data "external" "pihole" {
  for_each   = var.pi_hosts
  depends_on = [null_resource.pihole]
  program    = ["C:/Program Files/Git/usr/bin/bash.exe", "${path.module}/scripts/pihole-config-check.sh"]

  query = {
    host      = each.value.static_ip
    user      = var.ssh_user
    key_path  = pathexpand(var.ssh_private_key_path)
    dns       = join(", ", each.value.dns)
    interface = each.value.interface
    hosts     = join(", ", var.local_hosts)
  }
}

check "pihole_check" {
  assert {
    condition = alltrue([for k, v in var.pi_hosts : data.external.pihole[k].result.dns == "true"])
    error_message = "Pi-hole DNS  has drifted on: ${join(", ", [
      for k, v in var.pi_hosts : k if data.external.pihole[k].result.dns != "true"
    ])}"
  }

  assert {
    condition = alltrue([for k, v in var.pi_hosts : data.external.pihole[k].result.interface == "true"])
    error_message = "Pi-hole interface has drifted on: ${join(", ", [
      for k, v in var.pi_hosts : k if data.external.pihole[k].result.interface != "true"
    ])}"
  }

  assert {
    condition = alltrue([for k, v in var.pi_hosts : data.external.pihole[k].result.hosts == "true"])
    error_message = "Pi-hole hosts has drifted on: ${join(", ", [
      for k, v in var.pi_hosts : k if data.external.pihole[k].result.hosts != "true"
    ])}"
  }
}

resource "null_resource" "pihole" {
  for_each   = var.pi_hosts
  depends_on = [module.pi_hardening]

  triggers = {
    pihole_hash = local.pihole_hashes[each.key]
  }

  connection {
    type        = "ssh"
    host        = each.value.static_ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/pihole.toml.tftpl", {
      dns        = each.value.dns
      interface  = each.value.interface
      hosts      = var.local_hosts
      app_pwhash = lookup(var.pihole_app_pwhashes, each.key, "")
      app_sudo   = each.value.app_sudo
    })
    destination = "/tmp/pihole.toml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo install -D -o root -g root -m 0600 /tmp/pihole.toml /etc/pihole/pihole.toml",
      "sudo apt-get update -y",
      "curl -sSL https://install.pi-hole.net | sudo bash -s -- --unattended",
      "sudo pihole setpassword ${var.pihole_password}"
    ]
  }
}

# Nebula Sync on the primary only: pushes its Pi-hole config to the replicas on
# an hourly systemd timer. A pinned release, checked against its SHA-256 before
# install; the env file (with the Pi-hole passwords) goes up via source like the
# Traefik projects' Cloudflare token, so only its hash is in state.
resource "null_resource" "nebula_sync" {
  for_each   = { for k, v in var.pi_hosts : k => v if v.nebula_sync_primary }
  depends_on = [null_resource.pihole]

  triggers = {
    version      = var.nebula_sync_version
    sha256       = var.nebula_sync_sha256
    env_hash     = filemd5(pathexpand(var.nebula_sync_env_path))
    service_hash = filemd5("${path.module}/templates/nebula-sync.service")
    timer_hash   = filemd5("${path.module}/templates/nebula-sync.timer")
  }

  connection {
    type        = "ssh"
    host        = each.value.static_ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "file" {
    source      = pathexpand(var.nebula_sync_env_path)
    destination = "/tmp/nebula-sync.env"
  }

  provisioner "file" {
    source      = "${path.module}/templates/nebula-sync.service"
    destination = "/tmp/nebula-sync.service"
  }

  provisioner "file" {
    source      = "${path.module}/templates/nebula-sync.timer"
    destination = "/tmp/nebula-sync.timer"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e", # a failed download or checksum stops here instead of enabling the timer
      "cd /tmp && curl -fsSL -o nebula-sync.tar.gz https://github.com/lovelaze/nebula-sync/releases/download/v${var.nebula_sync_version}/nebula-sync_${var.nebula_sync_version}_linux_arm64.tar.gz && echo '${var.nebula_sync_sha256}  nebula-sync.tar.gz' | sha256sum -c - && tar xzf nebula-sync.tar.gz nebula-sync && sudo install -o root -g root -m 0755 nebula-sync /usr/local/bin/nebula-sync && rm -f nebula-sync nebula-sync.tar.gz",
      "sudo install -D -o root -g root -m 0600 /tmp/nebula-sync.env /etc/nebula-sync/nebula-sync.env && rm -f /tmp/nebula-sync.env",
      "sudo install -o root -g root -m 0644 /tmp/nebula-sync.service /tmp/nebula-sync.timer /etc/systemd/system/ && rm -f /tmp/nebula-sync.service /tmp/nebula-sync.timer",
      "sudo systemctl daemon-reload && sudo systemctl enable --now nebula-sync.timer"
    ]
  }
}