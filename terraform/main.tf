locals {
  vms = {
    k3s-server = {
      node_name = "farnsworth"
      template_vm_id = 9001
      cores      = 4
      memory     = 8192
      ip_address = "192.168.1.20/24"
      disk = {
        interface = "scsi0"
        size      = 60
      }
    }
    k3s-agent = {
      node_name = "wernstrom"
      template_vm_id = 9002
      cores      = 4
      memory     = 8192
      ip_address = "192.168.1.21/24"
      disk = {
        interface = "scsi0"
        size      = 60
      }
    }
  }
}

resource "proxmox_virtual_environment_vm" "vms" {
  for_each  = local.vms
  name      = each.key
  node_name = each.value.node_name

  clone {
    vm_id = each.value.template_vm_id
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  initialization {
    dns {
      servers = ["192.168.1.254"]
    }
    ip_config {
      ipv4 {
        address = each.value.ip_address
        gateway = "192.168.1.254"
      }
    }

    user_account {
      username = "jon"
      keys     = [trimspace(file("~/.ssh/id_ed25519.pub"))]
    }

  }

  disk {
    interface = each.value.disk.interface
    size      = each.value.disk.size
  }
}

output "vm_ipv4_address" {
  value = {
    for k, v in proxmox_virtual_environment_vm.vms : k => v.ipv4_addresses[1][0]
  }
}
