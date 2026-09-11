#!/bin/bash

declare -A TEMPLATE_IDS=( [nibbler]=9000 [farnsworth]=9001 [wernstrom]=9002 )

node="${1:-}"
if [[ -z "${TEMPLATE_IDS[$node]:-}" ]]; then
  echo "usage: $0 <${!TEMPLATE_IDS[*]}>" >&2
  exit 1
fi

vmid="${TEMPLATE_IDS[$node]}"

cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/20260911/noble-server-cloudimg-amd64.img

virt-customize -a noble-server-cloudimg-amd64.img \
  --install qemu-guest-agent \
  --truncate /etc/machine-id
# You may need to put this between install and truncate again im not entirely sure
#  --run-command 'systemctl enable qemu-guest-agent.service' \

qm create $vmid --name "${node}-ubuntu-cloud-template" --memory 4096 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci
qm set $vmid --scsi0 local-lvm:0,import-from=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img
qm set $vmid --ide2 local-lvm:cloudinit
qm set $vmid --boot order=scsi0
qm set $vmid --serial0 socket --vga serial0
qm template $vmid
