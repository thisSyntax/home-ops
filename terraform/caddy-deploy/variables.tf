variable "pi_hosts" {
    description = "Map of Raspberry Pi Proxies"
    type = map(object({
        static_ip = string
        gateway = string
        dns = list(string)
        interface = optional(string, "eth0")
        bootstrap_ip = string
        role = string
        sites = list(object({
            hostname = string
            upstream = string
        }))
    }))

    validation {
        condition = alltrue([for h in var.pi_hosts : contains(["external", "internal"], h.role)])
        error_message = "Each pi_hosts entry's role must be either \"external\" or \"internal\"."
    }
}
variable "ssh_user" {
    description = "SSH user that will be used to connect to each PI"
    type = string
}
variable "ssh_private_key_path" {
    description = "Path to the ssh private key"
    type = string
    default = "~/.ssh/id_ed25519"
}
variable "application_ufw_name" {
    description = "The application that will be running on this PI that needs UFW rules"
    type = string
}
variable "application_ufw_description" {
    description = "Description for the application's UFW app profile"
    type = string
}
variable "application_ufw_ports" {
    description = "List of the ports that the custom applications use for UFW"
    type = list(string)
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
variable "cloudflare_api_token" {
    description = "Defines the cloudflare api token for use in certificate renewal"
    type = string
    sensitive = true
}