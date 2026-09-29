# Technical Notes & Implementation Diary

This document contains raw implementation notes, design rationale, and troubleshooting post-mortems captured during the construction of `fleet-platform`. Detailed blog posts based on these notes are published on [bouligny.dev](https://bouligny.dev).

---

## Hardware & Node Inventory

| Node | Mobo | CPU | RAM | Storage | Primary Role |
|---|---|---|---|---|---|
| **nibbler** | ASUS ROG Strix B450-F | Ryzen 7 2700X (8c/16t) | 32 GiB | 250GB NVMe + 2TB SSD | Proxmox Node (Terraform Target) |
| **farnsworth** | ASRock X570 Taichi | Ryzen 5 5600 (6c/12t) | 64 GiB | 3 × 1 TB NVMe | Proxmox Node |
| **wernstrom** | ASRock X570 Taichi | Ryzen 5 5600 (6c/12t) | 64 GiB | 3 × 1 TB NVMe | Proxmox Node |

---

## Phase 0: Proxmox, Cloud-init, Terraform, K3s, Ansible

My goal with this project was technical curiosity — building a fully automated, production-grade homelab platform from scratch to deeply understand Terraform, cloud-init, Kubernetes, Argo CD, HAProxy Ingress, cert-manager, Prometheus, and Ansible automation.

### Cloud-init Fundamentals
Cloud-init solves the automated OS bootstrapping problem. Instead of interactive OS installers, pre-built cloud disk images (`.qcow2`/`.img`) are copied directly onto hypervisor disks. On first boot, `cloud-init` reads configuration payloads (via Proxmox `nocloud` virtual CD-ROM) to set hostnames, SSH keys, networks, and initial users.

### Building the Proxmox Template (`helper-artifacts/build-proxmox-template.sh`)
1. Download official Ubuntu Noble cloud image (`noble-server-cloudimg-amd64.img`).
2. Use `virt-customize` to pre-install `qemu-guest-agent` for hypervisor communication.
3. Truncate `/etc/machine-id` so every cloned VM generates a unique machine ID and DHCP lease on first boot.
4. Convert VM to Proxmox template (ID `9000`).

### Proxmox VE Upgrade & Provider Setup
- Cluster formed across `nibbler`, `farnsworth`, `wernstrom`.
- Created API token service account (`terraform-svc@pve`).
- Upgraded Proxmox VE 8 to 9 for API compatibility with `bpg/proxmox` provider.

### Terraform IaC Architecture
- `main.tf` defines a `for_each` resource map stamping out VM nodes with static IPs, CPU, and RAM allocation.
- API tokens passed securely via environment variables (`PROXMOX_VE_API_TOKEN`).
- State stored in remote S3 backend with lockfiles.

### Ansible Cluster Bootstrap & Unattended Upgrade Race Condition
- Fixed systemd D-Bus disconnect error caused by Ubuntu `unattended-upgrades` patching on first boot:
  - Wait for `cloud-init status --wait`.
  - Poll `/varlib/dpkg/lock-frontend` via `fuser` until unattended updates complete before running package tasks.
- Encrypted cluster join token with Ansible Vault (`k3s-token-vault.yml`).
- Automated kubeconfig retrieval and IP sanitization (`ansible/get-cli-kubeconfig.yml`).

---

## Phase 1: Modular Ansible Roles & Argo CD Bootstrap

### Refactoring Ansible Playbooks into Reusable Roles
- Split monolithic playbooks into decoupled roles:
  - `install_cluster_k3s`: System dependencies, k3s server/agent systemd setup.
  - `get_cli_kubeconfig`: Kubeconfig retrieval and workstation setup.
  - `install_cli_argocd`: Local CLI tool installation.
  - `install_cluster_argocd`: In-cluster Argo CD Helm release.
- Moved deployment-specific inventory variables into `group_vars/`.

### Single-Script Teardown & Rebuild (`rebuild-cluster.sh`)
- Enforced strict bash error handling (`set -euo pipefail`).
- Added automated SSH host key purging (`ssh-keygen -R`) to handle re-minted host keys cleanly.

### Argo CD Declarative App-of-Apps Pattern
- Implemented root Application manifest (`argocd/cluster/root.yml`) pointing to repository path with directory recursion enabled.
- Established resource ownership hierarchy: Root App -> Application CRDs -> Workload Deployments.
- Solved CRD race conditions using sync options: `ServerSideApply=true` and `SkipDryRunOnMissingResource=true`.
