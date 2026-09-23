#!/bin/bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
source /home/jon/super-dumb-repos/password-files/token-proxmox
ssh-keygen -R 192.168.1.20; ssh-keygen -R 192.168.1.21
terraform -chdir=terraform destroy -auto-approve
terraform -chdir=terraform apply -auto-approve
ansible-playbook ansible/install-cluster-k3s.yml --vault-password-file /home/jon/super-dumb-repos/password-files/vault-password-fleet-platform
ansible-playbook ansible/get-cli-kubeconfig.yml
ansible-playbook ansible/install-cluster-argocd.yml --vault-password-file /home/jon/super-dumb-repos/password-files/vault-password-fleet-platform
ansible-playbook ansible/configure-bootstrap-secrets.yml
ansible-playbook ansible/configure-rootapp-argocd.yml
kubectl wait --for=condition=Ready nodes --all --timeout=180s && kubectl get nodes