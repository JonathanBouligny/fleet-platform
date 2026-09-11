locals {
  virtual_environment_endpoint = "https://192.168.1.10:8006/"
}

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111.1"
    }
  }
}

provider "proxmox" {
  endpoint = local.virtual_environment_endpoint
  insecure = true

  ssh {
    agent    = true
    username = "terraform"
  }
}
