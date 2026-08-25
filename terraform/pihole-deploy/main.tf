locals {
    pihole_hashes = {
        for k, v in var.pi_hosts : k => md5(templatefile("${path.module}/templates/pihole.toml.tftpl", {
            dns = v.dns
            hosts = var.local_hosts
            interface = v.interface
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

data "external" "pihole" {
    for_each = var.pi_hosts
    depends_on = [null_resource.pihole]
    program = ["C:/Program Files/Git/usr/bin/bash.exe", "${path.module}/scripts/pihole-config-check.sh"]

    query = {
        host = each.value.static_ip
        user = var.ssh_user
        key_path = pathexpand(var.ssh_private_key_path)
        dns = join(", ", each.value.dns)
        interface = each.value.interface
        hosts = join(", ", var.local_hosts)
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
    for_each = var.pi_hosts
    depends_on = [module.pi_hardening]

    triggers = {
        pihole_hash = local.pihole_hashes[each.key]
    }

    connection {
        type = "ssh"
        host = each.value.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }

    provisioner "file" {
        content = templatefile("${path.module}/templates/pihole.toml.tftpl", {
            dns = each.value.dns
            interface = each.value.interface
            hosts = var.local_hosts
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