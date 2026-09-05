provider "docker" {
    host = "ssh://${var.ssh_user}@${var.static_ip}:22"
}
