locals {
    caddyfile_hashes = {
        for k, v in var.pi_hosts : k => md5(templatefile("${path.module}/templates/Caddyfile.tftpl", {
            role = v.role
            acme_email = var.acme_email
            sites = v.sites
        }))
    }
}

module "pi_hardening" {
    source = "../modules/pi-hardening"

    pi_hosts = {
        for k, v in var.pi_hosts : k => {
            static_ip = v.static_ip
            gateway = v.gateway
            dns = v.dns
            interface = v.interface
            bootstrap_ip = v.bootstrap_ip
        }
    }
    ssh_user = var.ssh_user
    ssh_private_key_path = var.ssh_private_key_path
    application_ufw_name = var.application_ufw_name
    application_ufw_description = var.application_ufw_description
    application_ufw_ports = var.application_ufw_ports
    fail2ban_maxretry = var.fail2ban_maxretry
    fail2ban_bantime = var.fail2ban_bantime
    fail2ban_findtime = var.fail2ban_findtime
    unattended_upgrades_auto_reboot = var.unattended_upgrades_auto_reboot
    unattended_upgrades_auto_reboot_time = var.unattended_upgrades_auto_reboot_time
    auto_upgrades_days = var.auto_upgrades_days
}

data "external" "caddy" {
    for_each = var.pi_hosts
    program = ["C:/Program Files/Git/usr/bin/bash.exe", "${path.module}/scripts/remote-file-hash.sh"]

    query = {
        host = each.value.static_ip
        user = var.ssh_user
        key_path = pathexpand(var.ssh_private_key_path)
        remote_path = "/etc/caddy/Caddyfile"
    }
}

check "caddyfile_check" {
    assert {
        condition = alltrue([
            for k, v in var.pi_hosts : data.external.caddy[k].result.hash == local.caddyfile_hashes[k]
        ])
        error_message = "Caddyfile drift detected on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.caddy[k].result.hash != local.caddyfile_hashes[k]
        ])}"
    }
}

resource "null_resource" "caddy" {
    for_each = var.pi_hosts
    depends_on = [module.pi_hardening]

    triggers = {
        caddyfile_hash = local.caddyfile_hashes[each.key]
    }

    connection {
        type = "ssh"
        host = each.value.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }

    provisioner "remote-exec" {
        inline = [
            "sudo apt-get update -y",
            "sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl",
            "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg",
            "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list",
            "sudo apt-get update -y",
            "sudo apt-get install -y caddy"
        ]
    }

    provisioner "remote-exec" {
        inline = each.value.role == "external" ? [
            "sudo dpkg-divert --divert /usr/bin/caddy.default --rename /usr/bin/caddy",
            "curl -sL 'https://caddyserver.com/api/download?os=linux&arch=arm64&p=github.com/caddy-dns/cloudflare' -o ./caddy",
            "sudo mv ./caddy /usr/bin/caddy.custom",
            "sudo chmod +x /usr/bin/caddy.custom",
            "sudo setcap cap_net_bind_service=+ep /usr/bin/caddy.custom",
            "sudo update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.default 10",
            "sudo update-alternatives --install /usr/bin/caddy caddy /usr/bin/caddy.custom 50"
        ] : ["true"]
    }

    provisioner "file" {
        content = each.value.role == "external" ? templatefile("${path.module}/templates/caddy-env-override.conf.tftpl", {
            cloudflare_api_token = var.cloudflare_api_token
        }) : ""
        destination = "/tmp/caddy-env-override.conf"
    }

    provisioner "remote-exec" {
        inline = each.value.role == "external" ? [
            "sudo mkdir -p /etc/systemd/system/caddy.service.d",
            "sudo install -o root -g root -m 0600 /tmp/caddy-env-override.conf /etc/systemd/system/caddy.service.d/override.conf",
            "sudo systemctl daemon-reload",
            "rm -f /tmp/caddy-env-override.conf"
        ] : ["true"]
    }
    
    provisioner "file" {
        content = templatefile("${path.module}/templates/Caddyfile.tftpl", {
            role = each.value.role
            acme_email = var.acme_email
            sites = each.value.sites
        })
        destination = "/tmp/Caddyfile"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo install -o root -g root -m 0644 /tmp/Caddyfile /etc/caddy/Caddyfile",
            "sudo sh -c \"CF_API_TOKEN='${each.value.role == "external" ? var.cloudflare_api_token : ""}' caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile\"",
            "sudo systemctl enable caddy",
            "sudo systemctl reload caddy || sudo systemctl restart caddy",
            "sleep 2",
            "systemctl is-active --quiet caddy"
        ]
    }
}