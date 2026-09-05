module "traefik" {
    source = "../modules/traefik-node"

    pi_key = var.pi_key
    static_ip = var.static_ip
    gateway = var.gateway
    dns = var.dns
    interface = var.interface
    bootstrap_ip = var.bootstrap_ip
    config_path = var.config_path
    dashboard_enabled = var.dashboard_enabled
    dashboard_hostname = var.dashboard_hostname
    dashboard_htpasswd_path = var.dashboard_htpasswd_path
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
    cf_api_token_path = var.cf_api_token_path
}
