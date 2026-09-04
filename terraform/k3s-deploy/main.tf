provider "proxmox" {
    pm_api_url = var.proxmox_cluster
    pm_tls_insecure = true
    pm_api_token_id = var.proxmox_token_id
    pm_api_token_secret = var.proxmox_token_secret
}

resource "proxmox_vm_qemu" "create_vm" {
    for_each = var.vms
    name = each.value.hostname
    target_node = each.value.target_node
    memory = each.value.memory
    cores = each.value.cores
    sockets = each.value.sockets
    scsihw = "virtio-scsi-pci"
    boot = each.value.boot
    iso = each.value.iso
    disk = each.value.disk
    network = each.value.network
}