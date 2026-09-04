module "pi_hardening" {
    source = "../pi-hardening"

    pi_hosts = {
        (var.pi_key) = {
            static_ip = var.static_ip
            gateway = var.gateway
            dns = var.dns
            interface = var.interface
            bootstrap_ip = var.bootstrap_ip
        }
    }
    ssh_user = var.ssh_user
    ssh_private_key_path = var.ssh_private_key_path
    fail2ban_maxretry = var.fail2ban_maxretry
    fail2ban_bantime = var.fail2ban_bantime
    fail2ban_findtime = var.fail2ban_findtime
    unattended_upgrades_auto_reboot = var.unattended_upgrades_auto_reboot
    unattended_upgrades_auto_reboot_time = var.unattended_upgrades_auto_reboot_time
    auto_upgrades_days = var.auto_upgrades_days
}

resource "null_resource" "docker" {
    depends_on = [module.pi_hardening]

    connection {
        type = "ssh"
        host = var.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }

    provisioner "remote-exec" {
        inline = [
            "sudo apt-get update -y",
            "curl -sSL https://get.docker.com | sh",
            "sudo usermod -aG docker ${var.ssh_user}"
        ]
    }
}

resource "null_resource" "traefik_static" {
    depends_on = [module.pi_hardening]

    triggers = {
        content_hash = md5(templatefile("${path.module}/templates/traefik.yml.tftpl", {
            acme_email = var.acme_email
            dashboard_enabled = var.dashboard_enabled
        }))
    }

    connection {
        type = "ssh"
        host = var.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }

    provisioner "remote-exec" {
        inline = [
            "sudo mkdir -p ${var.config_path}",
            "sudo mkdir -p ${var.config_path}/acme"
        ]
    }

    provisioner "file" {
        content = templatefile("${path.module}/templates/traefik.yml.tftpl", {
            acme_email = var.acme_email
            dashboard_enabled = var.dashboard_enabled
        })
        destination = "/tmp/traefik.yml"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo install -o root -g root -m 0644 /tmp/traefik.yml ${var.config_path}/traefik.yml"
        ]
    }
}

resource "null_resource" "traefik_dynamic" {
    for_each = var.services
    depends_on = [module.pi_hardening]

    triggers = {
        content_hash = md5(templatefile("${path.module}/templates/dynamic-service.yml.tftpl", {
            name = each.key
            hostname = each.value.hostname
            target_url = each.value.target_url
            entrypoint = each.value.entrypoint
            use_acme = var.use_acme
        }))
    }

    connection {
        type = "ssh"
        host = var.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }

    provisioner "remote-exec" {
        inline = ["sudo mkdir -p ${var.config_path}/dynamic"]
    }

    provisioner "file" {
        content = templatefile("${path.module}/templates/dynamic-service.yml.tftpl", {
            name = each.key
            hostname = each.value.hostname
            target_url = each.value.target_url
            entrypoint = each.value.entrypoint
            use_acme = var.use_acme
        })
        destination = "/tmp/${each.key}.yml"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo install -o root -g root -m 0644 /tmp/${each.key}.yml ${var.config_path}/dynamic/${each.key}.yml"
        ]
    }
}

resource "null_resource" "cf_token" {
    depends_on = [module.pi_hardening]

    triggers = {
        content_hash = filemd5(pathexpand(var.cf_api_token_path))
    }

    connection {
        type = "ssh"
        host = var.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }

    provisioner "remote-exec" {
        inline = ["sudo mkdir -p ${var.config_path}/secrets"]
    }

    provisioner "file" {
        source = pathexpand(var.cf_api_token_path)
        destination = "/tmp/cf-token"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo install -o root -g root -m 0600 /tmp/cf-token ${var.config_path}/secrets/cf-token",
            "rm -f /tmp/cf-token"
        ]
    }
}

resource "docker_image" "traefik" {
    name = "traefik:v3.4"

    depends_on = [null_resource.docker]
}

resource "docker_container" "traefik" {
    name = "traefik"
    image = docker_image.traefik.image_id
    restart = "unless-stopped"

    env = [
        "TRAEFIK_STATIC_CONFIG_HASH=${null_resource.traefik_static.triggers["content_hash"]}",
        "CF_DNS_API_TOKEN_FILE=/etc/traefik/secrets/cf-token"
    ]

    volumes {
        host_path = var.config_path
        container_path = "/etc/traefik"
        read_only = true
    }

    volumes {
        host_path = "${var.config_path}/acme"
        container_path = "/etc/traefik/acme"
        read_only = false
    }

    ports {
        internal = 80
        external = 80
    }

    ports {
        internal = 443
        external = 443
    }

    dynamic "ports" {
        for_each = var.dashboard_enabled ? [1] : []
        content {
            internal = 8080
            external = 8080
            ip = "127.0.0.1"
        }
    }

    depends_on = [
        null_resource.docker,
        null_resource.traefik_static,
        null_resource.traefik_dynamic,
        null_resource.cf_token,
    ]
}
