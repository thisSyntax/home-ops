variable "pi_key" {
    description = "Name for this Pi, used as the key when calling module.pi_hardening (matters for -replace addressing)"
    type = string
}
variable "static_ip" {
    description = "Static IP this Pi is moved to"
    type = string
}
variable "gateway" {
    description = "Default gateway for this Pi's network"
    type = string
}
variable "dns" {
    description = "DNS servers for this Pi's network connection"
    type = list(string)
}
variable "interface" {
    description = "Network interface nmcli manages on this Pi"
    type = string
    default = "eth0"
}
variable "bootstrap_ip" {
    description = "This Pi's current IP before it's moved to static_ip"
    type = string
}
variable "docker_host" {
    description = "Docker provider connection string for this Pi, e.g. ssh://piuser@192.168.0.5:22"
    type = string
}
variable "config_path" {
    description = "Path on this Pi where Traefik's config is written and bind-mounted from"
    type = string
    default = "/etc/traefik"
}
variable "dashboard_enabled" {
    description = "Whether to expose Traefik's dashboard on 127.0.0.1:8080"
    type = bool
    default = false
}
variable "services" {
    description = "Map of services this Traefik instance proxies to, one dynamic config file per entry"
    type = map(object({
        hostname = string
        target_url = string
        entrypoint = string
    }))
}
variable "ssh_user" {
    description = "SSH user that will be used to connect to this Pi"
    type = string
}
variable "ssh_private_key_path" {
    description = "Path to the ssh private key"
    type = string
    default = "~/.ssh/id_ed25519"
}
variable "fail2ban_maxretry" {
    description = "Defines the maximum number of failed login attempts allowed within a specified time window (findtime)"
    type = number
    default = 4
}
variable "fail2ban_bantime" {
    description = "Defines how long an IP stays banned"
    type = string
    default = "1h"
}
variable "fail2ban_findtime" {
    description = "Defines the time window in which the maximum number of failed login attempts (defined by maxretry)"
    type = string
    default = "10m"
}
variable "unattended_upgrades_auto_reboot" {
    description = "Whether the Pi should automatically reboot itself when an installed update requires it"
    type = bool
    default = true
}
variable "unattended_upgrades_auto_reboot_time" {
    description = "Time of day (Pi local time) automatic reboots are allowed to run, if one is needed"
    type = string
    default = "03:00"
}
variable "auto_upgrades_days" {
    description = "How often in days to run the auto upgrades"
    type = number
    default = 1
}
variable "acme_email" {
    description = "Defines the email address for Certificate renewals"
    type = string
}
variable "use_acme" {
    description = "Whether routers request a cert via Let's Encrypt (certResolver). Set false for a Pi using a manually-supplied cert instead."
    type = bool
    default = true
}
