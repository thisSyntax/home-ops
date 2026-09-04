module "traefik" {
    source = "../modules/traefik-node"

    pi_key = var.pi_key
    static_ip = var.static_ip
    gateway = var.gateway
    dns = var.dns
    interface = var.interface
    bootstrap_ip = var.bootstrap_ip
    docker_host = var.docker_host
    config_path = var.config_path
    dashboard_enabled = var.dashboard_enabled
    services = var.services
    ssh_user = var.ssh_user
    ssh_private_key_path = var.ssh_private_key_path
    fail2ban_maxretry = var.fail2ban_maxretry
    fail2ban_bantime = var.fail2ban_bantime
    fail2ban_findtime = var.fail2ban_findtime
    unattended_upgrades_auto_reboot = var.unattended_upgrades_auto_reboot
    unattended_upgrades_auto_reboot_time = var.unattended_upgrades_auto_reboot_time
    auto_upgrades_days = var.auto_upgrades_days
    acme_email = var.acme_email
    use_acme = var.use_acme
}

locals {
    mkcert_domains = [for k, v in var.services : v.hostname]
}

resource "null_resource" "mkcert" {
    depends_on = [module.traefik]

    triggers = {
        domains = join(",", local.mkcert_domains)
    }

    connection {
        type = "ssh"
        host = var.static_ip
        user = var.ssh_user
        private_key = file(pathexpand(var.ssh_private_key_path))
    }

    provisioner "remote-exec" {
        inline = [
            "curl -JLO 'https://dl.filippo.io/mkcert/latest?for=linux/arm64'",
            "chmod +x mkcert-v*-linux-arm64",
            "sudo mv mkcert-v*-linux-arm64 /usr/local/bin/mkcert",
            "sudo mkdir -p ${var.config_path}/certs",
            "mkcert -cert-file /tmp/internal-cert.pem -key-file /tmp/internal-key.pem ${join(" ", [for d in local.mkcert_domains : "'${d}'"])}",
            "sudo install -o root -g root -m 0644 /tmp/internal-cert.pem ${var.config_path}/certs/internal-cert.pem",
            "sudo install -o root -g root -m 0600 /tmp/internal-key.pem ${var.config_path}/certs/internal-key.pem",
            "rm -f /tmp/internal-cert.pem /tmp/internal-key.pem"
        ]
    }

    provisioner "file" {
        content = templatefile("${path.module}/templates/tls.yml.tftpl", {
            cert_path = "${var.config_path}/certs/internal-cert.pem"
            key_path = "${var.config_path}/certs/internal-key.pem"
        })
        destination = "/tmp/tls.yml"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo mkdir -p ${var.config_path}/dynamic",
            "sudo install -o root -g root -m 0644 /tmp/tls.yml ${var.config_path}/dynamic/tls.yml"
        ]
    }
}
