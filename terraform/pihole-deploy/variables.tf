variable "pi_hosts" {
  description = "Map of Raspberry Pi Proxies"
  type = map(object({
    static_ip    = string
    gateway      = string
    dns          = list(string)
    interface    = optional(string, "eth0")
    bootstrap_ip = string
    # Fixed IPv6 interface ID (e.g. "::53") - see pi-hardening's pi_hosts. The
    # resulting address is what goes in the router's IPv6 DNS servers.
    ipv6_token = optional(string)
    # webserver.api.app_sudo - lets app-password sessions change settings. Nebula
    # Sync replicas need it so the primary's config can be written to them.
    app_sudo = optional(bool, false)
    # Run Nebula Sync on this Pi, pushing its config to the replicas listed in
    # nebula_sync_env_path's REPLICAS. Only the primary runs it.
    nebula_sync_primary = optional(bool, false)
  }))

  validation {
    condition     = length([for k, v in var.pi_hosts : k if v.nebula_sync_primary]) <= 1
    error_message = "At most one pi_hosts entry can set nebula_sync_primary = true - Nebula Sync runs on the primary only."
  }
}
variable "nebula_sync_version" {
  description = "Nebula Sync release installed on the primary (https://github.com/lovelaze/nebula-sync/releases), without the leading v"
  type        = string
  default     = "0.11.2"
}
variable "nebula_sync_sha256" {
  description = "SHA-256 of that release's linux_arm64 tarball, from its checksums.txt. The install stops if the download doesn't match - update it together with nebula_sync_version."
  type        = string
  default     = "67d08bfebb4c924b64a8d8cf13aedf6bb42ea2dd7d6d5d06bddb6e5ba3991af1"
}
variable "nebula_sync_env_path" {
  description = "Path to a local env file for Nebula Sync (PRIMARY, REPLICAS, FULL_SYNC, RUN_GRAVITY...). Required when a pi_hosts entry sets nebula_sync_primary. Only the path is a Terraform value - the file holds the Pi-hole passwords and is pushed to the primary as a root-owned file, never embedded as content, so it never lands in Terraform state."
  type        = string
  default     = null
}
variable "ssh_user" {
  description = "SSH user that will be used to connect to each PI"
  type        = string
}
variable "ssh_private_key_path" {
  description = "Path to the ssh private key"
  type        = string
  default     = "~/.ssh/id_ed25519"
}
variable "application_ufw_name" {
  description = "The application that will be running on this PI that needs UFW rules"
  type        = string
}
variable "application_ufw_description" {
  description = "Description for the application's UFW app profile"
  type        = string
}
variable "application_ufw_ports" {
  description = "List of the ports that the custom applications use for UFW"
  type        = list(string)
}
variable "fail2ban_maxretry" {
  description = "Defines the maximum number of failed login attempts allowed within a specified time window (findtime)"
  type        = number
  default     = 4
}
variable "fail2ban_bantime" {
  description = "Defines how long an IP stays banned"
  type        = string
  default     = "1h"
}
variable "fail2ban_findtime" {
  description = "Defines the time window in which the maximum number of failed login attempts (defined by maxretry)"
  type        = string
  default     = "10m"
}
variable "unattended_upgrades_auto_reboot" {
  description = "Whether the Pi should automatically reboot itself when an installed update requires it"
  type        = bool
  default     = true
}
variable "unattended_upgrades_auto_reboot_time" {
  description = "Time of day (Pi local time) automatic reboots are allowed to run, if one is needed"
  type        = string
  default     = "03:00"
}
variable "auto_upgrades_days" {
  description = "How often in days to run the auto upgrades"
  type        = number
  default     = 1
}
variable "local_hosts" {
  description = "List of the local dns hosts in the format of IP and hostname"
  type        = list(string)
  sensitive   = true
}
variable "pihole_password" {
  description = "Defines the password for the PiHole web interface"
  type        = string
  sensitive   = true
}
variable "pihole_app_pwhashes" {
  description = "Existing Pi-hole app password hash (webserver.api.app_pwhash) per pi_hosts key, carried over so a rebuilt Pi-hole accepts the same app password and API clients like Homepage keep working. Each Pi-hole has its own - Nebula Sync doesn't copy it. A Pi with no entry gets none; generate a new app password in the UI after the rebuild. A separate map rather than a pi_hosts field because pi_hosts drives for_each, which can't take sensitive values."
  type        = map(string)
  sensitive   = true
  default     = {}
}