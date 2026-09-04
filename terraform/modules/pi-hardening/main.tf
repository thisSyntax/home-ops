locals {
    fail2ban_hashes = {
        for k, v in var.pi_hosts : k => md5(templatefile("${path.module}/templates/jail.local.tftpl", {
            maxretry = var.fail2ban_maxretry
            bantime = var.fail2ban_bantime
            findtime = var.fail2ban_findtime
        }))
    }

    x11_forwarding_hash = filemd5("${path.module}/templates/60-disable-x11-forwarding.conf")

    unattended_upgrades_hashes = {
        for k, v in var.pi_hosts : k => md5(templatefile("${path.module}/templates/50unattended-upgrades.tftpl", {
            unattended_upgrades_auto_reboot = var.unattended_upgrades_auto_reboot
            unattended_upgrades_auto_reboot_time = var.unattended_upgrades_auto_reboot_time
        }))
    }

    auto_upgrades_hashes = {
        for k, v in var.pi_hosts : k => md5(templatefile("${path.module}/templates/20auto-upgrades.tftpl", {
            auto_upgrades_days = var.auto_upgrades_days
        }))
    }
}

data "external" "static_ip" {
    for_each = var.pi_hosts
    depends_on = [null_resource.static_ip]
    program = ["C:/Program Files/Git/usr/bin/bash.exe", "${path.module}/scripts/static-ip-check.sh"]

    query = {
        host = each.value.static_ip
        user = var.ssh_user
        key_path = pathexpand(var.ssh_private_key_path)
        interface = each.value.interface
        expected_ip = "${each.value.static_ip}/24"
        expected_gateway = each.value.gateway
        expected_dns = join(",", each.value.dns)
    }
}

check "static_ip_check" {
    assert {
        condition = alltrue([for k, v in var.pi_hosts : data.external.static_ip[k].result.address_ok == "true"])
        error_message = "Interface address has drifted from the expected static IP on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.static_ip[k].result.address_ok != "true"
        ])}"
    }

    assert {
        condition = alltrue([for k, v in var.pi_hosts : data.external.static_ip[k].result.gateway_ok == "true"])
        error_message = "Gateway has drifted from expected on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.static_ip[k].result.gateway_ok != "true"
        ])}"
    }

    assert {
        condition = alltrue([for k, v in var.pi_hosts : data.external.static_ip[k].result.dns_ok == "true"])
        error_message = "DNS servers have drifted from expected on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.static_ip[k].result.dns_ok != "true"
        ])}"
    }

    assert {
        condition = alltrue([for k, v in var.pi_hosts : data.external.static_ip[k].result.method_ok == "true"])
        error_message = "ipv4.method is no longer 'manual' on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.static_ip[k].result.method_ok != "true"
        ])}"
    }
}

resource "null_resource" "static_ip" {
    for_each = var.pi_hosts

    triggers = {
        static_ip = each.value.static_ip
        gateway = each.value.gateway
        dns = join(",", each.value.dns)
        interface = each.value.interface      
    }

    connection {
        type = "ssh"
        host = each.value.bootstrap_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }

    provisioner "file" {
        content = templatefile("${path.module}/templates/set-static-ip.sh.tftpl", {
            interface = each.value.interface
            static_ip = each.value.static_ip
            gateway = each.value.gateway
            dns_csv = join(",", each.value.dns)
        })
        destination = "/tmp/set-static-ip.sh"
    }

    provisioner "remote-exec" {
        inline = [
            "chmod +x /tmp/set-static-ip.sh",
            "/tmp/set-static-ip.sh"
        ]
        on_failure = continue
    }
}

data "external" "disable_x11_forwarding" {
    for_each = var.pi_hosts
    depends_on = [null_resource.disable_x11_forwarding]
    program = ["C:/Program Files/Git/usr/bin/bash.exe", "${path.module}/scripts/remote-file-hash.sh"]

    query = {
        host = each.value.static_ip
        user = var.ssh_user
        key_path = pathexpand(var.ssh_private_key_path)
        remote_path = "/etc/ssh/sshd_config.d/60-disable-x11-forwarding.conf"
    }
}

check "disable_x11_forwarding_check" {
    assert {
        condition = alltrue([
            for k, v in var.pi_hosts : data.external.disable_x11_forwarding[k].result.hash == local.x11_forwarding_hash
        ])
        error_message = "60-disable-x11-forwarding.conf drift detected on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.disable_x11_forwarding[k].result.hash != local.x11_forwarding_hash
        ])}"
    }
}

resource "null_resource" "disable_x11_forwarding" {
    for_each = var.pi_hosts
    depends_on = [null_resource.static_ip]

    triggers = {
        config_hash = filemd5("${path.module}/templates/60-disable-x11-forwarding.conf")
    }

    connection {
        type = "ssh"
        host = each.value.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }
    
    provisioner "file" {
        source = "${path.module}/templates/60-disable-x11-forwarding.conf"
        destination = "/tmp/60-disable-x11-forwarding.conf"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo install -o root -g root -m 0644 /tmp/60-disable-x11-forwarding.conf /etc/ssh/sshd_config.d/60-disable-x11-forwarding.conf",
            "sudo systemctl reload sshd"
        ]
    }
}

data "external" "ufw" {
    for_each = var.pi_hosts
    depends_on = [null_resource.ufw]
    program = ["C:/Program Files/Git/usr/bin/bash.exe", "${path.module}/scripts/ufw-status-check.sh"]

    query = {
        host = each.value.static_ip
        user = var.ssh_user
        key_path = pathexpand(var.ssh_private_key_path)
        app_name = var.application_ufw_name != null ? var.application_ufw_name : ""
    }
}

check "ufw_check" {
    assert {
        condition = alltrue([for k, v in var.pi_hosts : data.external.ufw[k].result.active == "true"])
        error_message = "UFW is not active on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.ufw[k].result.active != "true"
        ])}"
    }

    assert {
        condition = alltrue([for k, v in var.pi_hosts : data.external.ufw[k].result.default_policy_ok == "true"])
        error_message = "UFW default policy has drifted on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.ufw[k].result.default_policy_ok != "true"
        ])}"
    }

    assert {
        condition = alltrue([for k, v in var.pi_hosts : data.external.ufw[k].result.openssh_allowed == "true"])
        error_message = "UFW is missing the OpenSSH allow rule on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.ufw[k].result.openssh_allowed != "true"
        ])}"
    }

    assert {
        condition = var.application_ufw_name == null || alltrue([for k, v in var.pi_hosts : data.external.ufw[k].result.app_allowed == "true"])
        error_message = "UFW is missing the App allow rule on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.ufw[k].result.app_allowed != "true"
        ])}"
    }
}

resource "null_resource" "ufw" {
    for_each = var.pi_hosts
    depends_on = [null_resource.static_ip]

    triggers = {
        app_name = var.application_ufw_name != null ? var.application_ufw_name : ""
        description = var.application_ufw_description != null ? var.application_ufw_description : ""
        ports_csv = join("|", var.application_ufw_ports)
    }

    connection {
        type = "ssh"
        host = each.value.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }

    provisioner "file" {
        content = var.application_ufw_name != null ? templatefile("${path.module}/templates/application-ufw-profile.tftpl", {
            app_name = var.application_ufw_name
            description = var.application_ufw_description
            ports_csv = join("|", var.application_ufw_ports)
        }) : ""
        destination = "/tmp/application-ufw-profile"
    }

    provisioner "remote-exec" {
        inline = concat(
            [
                "sudo apt-get update -y",
                "sudo apt-get install -y ufw",
                "sudo ufw allow OpenSSH",
                "sudo ufw default deny incoming",
                "sudo ufw default allow outgoing",
            ],
            var.application_ufw_name != null ? [
                "sudo install -o root -g root -m 0644 /tmp/application-ufw-profile /etc/ufw/applications.d/${var.application_ufw_name}",
                "sudo ufw allow ${var.application_ufw_name}",
            ] : [],
            [
                "sudo ufw --force enable"
            ]
        )
    }
}

data "external" "fail2ban" {
    for_each = var.pi_hosts
    depends_on = [null_resource.fail2ban]
    program = ["C:/Program Files/Git/usr/bin/bash.exe", "${path.module}/scripts/remote-file-hash.sh"]

    query = {
        host = each.value.static_ip
        user = var.ssh_user
        key_path = pathexpand(var.ssh_private_key_path)
        remote_path = "/etc/fail2ban/jail.local"
    }
}

check "fail2ban_check" {
    assert {
        condition = alltrue([
            for k, v in var.pi_hosts : data.external.fail2ban[k].result.hash == local.fail2ban_hashes[k]
        ])
        error_message = "jail.local drift detected on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.fail2ban[k].result.hash != local.fail2ban_hashes[k]
        ])}"
    }
}

resource "null_resource" "fail2ban" {
    for_each = var.pi_hosts
    depends_on = [null_resource.ufw]

    triggers = {
        maxretry = var.fail2ban_maxretry
        bantime = var.fail2ban_bantime
        findtime = var.fail2ban_findtime
    }

    connection {
        type = "ssh"
        host = each.value.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }
    
    provisioner "file" {
        content = templatefile("${path.module}/templates/jail.local.tftpl", {
            maxretry = var.fail2ban_maxretry
            bantime = var.fail2ban_bantime
            findtime = var.fail2ban_findtime
        })
        destination = "/tmp/jail.local"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo apt-get update -y",
            "sudo apt-get install -y fail2ban",
            "sudo install -o root -g root -m 0644 /tmp/jail.local /etc/fail2ban/jail.local",
            "sudo systemctl enable fail2ban",
            "sudo systemctl reload fail2ban || sudo systemctl restart fail2ban",
            "sleep 2",
            "sudo fail2ban-client status sshd"
        ]
    }
}

data "external" "unattended_upgrades" {
    for_each = var.pi_hosts
    depends_on = [null_resource.unattended_upgrades]
    program = ["C:/Program Files/Git/usr/bin/bash.exe", "${path.module}/scripts/remote-file-hash.sh"]

    query = {
        host = each.value.static_ip
        user = var.ssh_user
        key_path = pathexpand(var.ssh_private_key_path)
        remote_path = "/etc/apt/apt.conf.d/50unattended-upgrades"
    }
}

data "external" "auto_upgrades" {
    for_each = var.pi_hosts
    depends_on = [null_resource.unattended_upgrades]
    program = ["C:/Program Files/Git/usr/bin/bash.exe", "${path.module}/scripts/remote-file-hash.sh"]

    query = {
        host = each.value.static_ip
        user = var.ssh_user
        key_path = pathexpand(var.ssh_private_key_path)
        remote_path = "/etc/apt/apt.conf.d/20auto-upgrades"
    }
}

check "unattended_upgrades_check" {
    assert {
        condition = alltrue([
            for k, v in var.pi_hosts : data.external.unattended_upgrades[k].result.hash == local.unattended_upgrades_hashes[k]
        ])
        error_message = "50unattended-upgrades drift detected on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.unattended_upgrades[k].result.hash != local.unattended_upgrades_hashes[k]
        ])}"
    }

    assert {
        condition = alltrue([
            for k, v in var.pi_hosts : data.external.auto_upgrades[k].result.hash == local.auto_upgrades_hashes[k]
        ])
        error_message = "20auto-upgrades drift detected on: ${join(", ", [
            for k, v in var.pi_hosts : k if data.external.auto_upgrades[k].result.hash != local.auto_upgrades_hashes[k]
        ])}"
    }
}

resource "null_resource" "unattended_upgrades" {
    for_each = var.pi_hosts
    depends_on = [null_resource.fail2ban]

    triggers = {
        unattended-upgrades_hash = local.unattended_upgrades_hashes[each.key]
        auto-upgrades_hash = local.auto_upgrades_hashes[each.key]
    }

    connection {
        type = "ssh"
        host = each.value.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }

    provisioner "file" {
        content = templatefile("${path.module}/templates/50unattended-upgrades.tftpl", {
            unattended_upgrades_auto_reboot = var.unattended_upgrades_auto_reboot
            unattended_upgrades_auto_reboot_time = var.unattended_upgrades_auto_reboot_time 
        })
        destination = "/tmp/50unattended-upgrades"
    }

    provisioner "file" {
        content = templatefile("${path.module}/templates/20auto-upgrades.tftpl", {
            auto_upgrades_days = var.auto_upgrades_days
        })
        destination = "/tmp/20auto-upgrades"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo apt-get update -y",
            "sudo apt-get install -y unattended-upgrades",
            "sudo install -o root -g root -m 0644 /tmp/50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades",
            "sudo install -o root -g root -m 0644 /tmp/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades",   
            "sudo unattended-upgrade --dry-run --debug"
        ]
  }   
}