# fleet-platform

## DONE
- Imported ubuntu cloud image
- configured ubuntu cloud image template on proxmox node
- upgrade pve node from 8 to 9 (Use keyboard and mouse not browser! Watchout for hardware renaming. EX: eps1 to eps2)
- hook terraform into pve
- ansible install and config of k3s

## TODO
- Break out the grab kube config play and move it into its own playbook
- Turn the current ansible into roles
- Next phase

## STRETCH GOALS
- Automate the deployment of a new proxmox node including the downloading and configuration of a ubuntu template using cloud images (terraform and ansible)
- Proxmox Templates are built in a pipeline
- Proxmox Template ids are programatic
- Ip addresses are programatic and passed down through the pipeline

# PHASE NOTES

| | nibbler | farnsworth | wernstrom |
|---|---|---|---|
| Mobo | ASUS ROG Strix B450-F | ASRock X570 Taichi | ASRock X570 Taichi |
| CPU | Ryzen 7 2700X (8c/16t, Zen+) | Ryzen 5 5600 (6c/12t, Zen 3) | Ryzen 5 5600 (6c/12t, Zen 3) |
| RAM | 32 GiB | 64 GiB | 64 GiB |
| GPU | RTX 3090 | NVS 310 (display only) | NVS 310 (display only) |
| Storage | 250 GB NVMe + 2 TB 870 QVO + 1 TB 870 EVO | 3 × 1 TB KLEVV NVMe | 3 × 1 TB KLEVV NVMe |
| NIC | Intel I211 1 GbE + ConnectX-3 (down) | Intel I211 1 GbE + AX200 Wi-Fi | Intel I211 1 GbE + AX200 Wi-Fi |

## Phase 0: Proxmox, Cloud-init, Terraform, K3s, Ansible

So my goal with this project was to learn a bunch of new technologies. Terraform, cloud-init, Kubernetes (I knew a bunch of Kubernetes and labbed it somewhat, but I hadn't labbed it in a larger production way). I also wanted to learn the related Kubernetes technologies like ArgoCD, ingress-nginx + cert-manager, Prometheus, Grafana, Alertmanager. I wanted to try SOPS for secrets, which seemed like an interesting way to manage secrets in git (I've already used HashiCorp Vault). I already knew Ansible and Proxmox and some S3 (MinIO). I've worked with Debian and Ubuntu in the past. RHEL is what I do at work because I'm a Red Hat consultant.

Cloud-init

The first thing I started tinkering with is cloud-init. To understand cloud-init you need to understand the problem it's trying to solve. We need to take an operating system, say Ubuntu, and install and configure it on some machine, virtual machine or bare metal, in the exact same way, thousands of times, using some configuration parameters passed quickly and tiny (as text) to that machine. We also need that machine to come up quickly, installed and configured unattended, so we can get tons of them fast. So instead of installing with an installer ISO, why don't we preinstall a base operating system, take that disk, and copy it into another machine? Then we put a program inside that disk that can configure the operating system once it's fed some parameters. That's what cloud-init is. It's a program that lives inside a fully installed disk image of an operating system and configures that operating system from within, on first boot.

The preinstalled disks are typically created by the companies who manage the operating systems, but you could make your own (you'd just have to maintain it). The img file is literally a fully functional bootable disk that gets passed around, img/qcow2 is just the most commonly supported format between hypervisors, and each hypervisor copies it into whatever disk format it natively supports. The configuration data comes through some medium, for Proxmox it's a virtual CD-ROM drive, for AWS it's a magic HTTP endpoint. Cloud-init hunts through its list of possible data sources at boot until one answers. The data is applied on first boot only, hence "init" (technically it re-runs its identity modules if the instance-id changes, but practically, first boot). For more configuration after that, we have other tools like Ansible.

One thing I got wrong at first, I thought "nocloud" and "configdrive2" were alternatives to cloud-init. They're not, they're payload formats of cloud-init (Proxmox writes nocloud for Linux guests, configdrive2 for Windows, selected by ostype). The actual alternatives to cloud-init are things like Ignition (immutable OSes) and cloudbase-init (Windows). I'm using cloud-init because it's the industry standard and it's the only scheme Proxmox and the bpg provider speak anyways.

Building the template

I used the official docs at https//pve.proxmox.com/wiki/Cloud-Init_Support and downloaded a disk image from https,//cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img. I hunted around for an Ubuntu image and figured this was the latest, so that's what I grabbed.

Once I had the image I needed to create a machine from it. The steps are in scripts/build-template.sh, but the summary, create an empty VM, import the disk image (which becomes its hard disk, no install ever happens, the image IS the installed OS), attach the cloud-init CD-ROM drive Proxmox uses to deliver configuration, set the boot order and a serial console (cloud images expect one). I also used virt-customize to install qemu-guest-agent into the image so Proxmox and Terraform can query the VM for things like its IP address.

The other thing virt-customize does in my build script is truncate /etc/machine-id, and this one deserves an explanation because I didn't understand it at first. Every Linux install generates a random ID in /etc/machine-id on its first boot to indentify its self. The ID gets generated once and then the disk gets copied many times, so every clone comes out wearing the same serial number. Many things use the id, the big one being DHCP, which builds its client identifier from it. Same client ID means the router thinks it's the same device, which means it hands two different machines the same IP address. Two machines, one IP, and nothing in either machine's config looks wrong. The fix is easy, systemd treats an empty machine-id file as "this is my first boot" and generates a fresh one. So you blank the file in the template and every clone mints its own identity when it starts, just like a fresh install would. It has to be the last virt-customize step though, because virt-customize boots the image internally to run apt, and that boot stamps an ID back in, so if we ran it first it would just write a new id while running virt-cutomize.

Once I had the VM set up, I converted it into a template so I can quickly get many copies. Important lesson from this stage, images flow forward only. I modified the .img with virt-customize a second time and the resulting template crashed to initramfs on boot, some mutation along the way damaged it. Rather than debug a mutated artifact of uncertain history, I did a clean re-download and a single customize pass, and that worked. The exact commands that worked went into build-template.sh so I can rebuild it later (and so the next Ubuntu LTS is a one-variable change). My first clone attempt hung waiting on the guest agent. I thought it was an enable issue, the agent's service not being enabled inside the image, so I built a separate image without the systemctl enable to compare. It worked both with and without the enable, so the real problem was memory, the docs' example 768MB was redlining the guest and the agent (along with everything else) was starving. Gave the clones real memory and moved on.

I cloned one from the template by hand in the GUI first, without any cloud-init values, just to prove the template booted. Cloud-init configuration itself happens per-clone in the next step, through Terraform.

Proxmox setup (and an unplanned upgrade)

I'm running three Proxmox nodes (nibbler, farnsworth, wernstrom) joined into one datacenter cluster, so Terraform only has to hit one API endpoint and can place VMs on any node. One wrinkle, clones need their source template local to the target node, so I copied the template to each node (9000/9001/9002).

For Terraform access I created a service account (terraform-svc@pve, in the pve realm, the pam realm is a passthrough to Linux users on the host, which is not what you want for a service account) with an API token and a least-privilege role from the bpg provider docs. Then there was an issue, the permissions in the provider docs didn't exist on my Proxmox. The docs were written for Proxmox 9 and I was on 8, and later I hit the mirror image of the same error by accidentally reading the docs for this provider https://registry.terraform.io/providers/Terraform-for-Proxmox/proxmox/latest/docs instead of bpg/proxmox. Since Proxmox 8 was hitting end of life anyways, I upgraded all three nodes to 9 using https,//pve.proxmox.com/wiki/Upgrade_from_8_to_9.

I didn't configure SSH for the bpg provider (it only needs it for a few operations like snippet uploads that I'm not using), that comes later if an apply ever asks for it.

Terraform

Terraform is an IaC tool that does state-based deployments. It takes text that defines infrastructure declaratively and tries to create it. It maintains a file that holds the state of what it created, so future runs can use it for changes or deletion. Ansible also does infrastructure as code, so why maintain state instead of going stateless like Ansible? State is what makes lifecycle management possible and fast. It's much easier to modify a machine when you already know which machine is yours and what state it's in, the binding between "this declaration" and "that real VM" exists nowhere in reality, so it has to be remembered somewhere, and that's what state is. Ansible gets away without it because it addresses machines explicitly and the machine itself is the database, every run just asks the target what its current condition is. But when the object doesn't exist yet, or needs to stop existing, there's nothing to ask, a stateless tool can't know that a thing it's no longer told about used to exist and should now be destroyed. Terraform gives you all of that for free. Rule of thumb I landed on, Terraform for objects with lifecycles and identities (VMs, networks, buckets), Ansible for properties of machines that already exist. Okay, enough explanation.

So what did I do with Terraform? Got the provider working (service account, token in an environment variable, never in a .tf file, and never committed), confirmed it with a basic clone, then organized the files by convention, main.tf has the actual IaC, providers.tf has the provider config, terraform.tf pins the provider version. variables.tf had variables in it until I realized that by convention variables.tf is for inputs coming into a module from outside, constants that are just facts of my setup belong in locals. Now there's nothing really in there.

The main.tf is built around a locals map of VMs and a single for_each resource, each entry declares the node it lands on, its VM id, cores, memory, disk size, and static IP, and one resource block stamps them all out. The per-VM cloud-init settings (SSH key, user, static IP, DNS) go through the provider's initialization block, which fills Proxmox's cloud-init fields for each clone. Adding a node later is three lines in the map. Versions are pinned (provider and, later, k3s) so a rebuild next month produces the same cluster as today.

The k3s installer

I spent a lot of my time here. Its well documented but the info is scattered across an env-var reference, a CLI reference, and a config-file page, and you sort of have to try stuff and see what happens. The core thing, you can configure k3s via command line flags, environment variables, and a config file, and they're all the same options in different clothes (CLI flags map one-to-one to config file keys, the server CLI page IS the config file schema). I use a combination of environment and config file. The environment variables tell the installer what version to pin and which role to install (INSTALL_K3S_EXEC="server" or "agent", the role is baked into the systemd unit at install time, it's not a config setting). The config file has the actual settings, the server disables traefik (we're doing ingress-nginx later, and I don't want two ingress controllers fighting), the agent gets the server URL. Which template a node gets is selected by a node-type variable in the Ansible inventory.

The token is the variable that took me the longest to understand, because it does two different things depending on who reads it. On an agent (server URL present), the token is the credential used to join. On the first server (no URL), you're setting the cluster's token, the server adopts your value instead of generating a random one. So I generated one random string, put it in an Ansible Vault file, and templated it to both sides, the server adopts it, the agents present it, and they match by construction. (My first attempt gave the token only to the agent while the fresh server minted its own random one, "token didn't match," obviously, in hindsight.) The vault password lives in a 600 file that doesn't get committed. Later I'll probably replace this with SOPS. Multi-server is apparently the same pattern, all servers share the one cluster token, but I'll figure that out when I get there.

Ansible

The main installation issue I had was Ansible connecting and installing too fast,

```
Unable to restart service k3s-agent, Warning! D-Bus connection terminated.
Failed to wait for response, Connection reset by peer
```

The machines were doing their first-boot security upgrade (Ubuntu's unattended-upgrades), which upgraded and restarted dbus/systemd right while Ansible was mid-conversation with systemd. The fix is to wait for the machine to finish being born before configuring it, and it turns out that's two separate waits, because two separate programs are involved, cloud-init status --wait for first-boot setup (accepting exit code 2, which means "done with recoverable errors"), and then watching the dpkg lock for the updater, because unattended-upgrades is not part of cloud-init and keeps running after cloud-init says done.

I had no idea you can't just ask apt whether it's currently patching, you have to look at the lock file using fuser. fuser identifies which processes are accessing a specific file; since everything is a file, that's how you see if something is in use. Exit code zero means in use, nonzero means free. Apt is a frontend over dpkg, and the specific file to watch is /var/lib/dpkg/lock-frontend, it's the session-level lock that any package frontend (apt, unattended-upgrades) holds for its entire operation, which is exactly the question I'm asking ("is anyone doing package management right now"), not just "is dpkg writing this millisecond." So we poll that file until we get nonzero and then let the rest of the playbook run. I want to break that functionality out into its own role.

Structure-wise, the playbook deploys the config file before running the installer (the installer starts the service as its last act, and the service needs its config, specifically the token, present at first start or it exits), and role/service-name differences between server and agent live in inventory group vars.

The kubeconfig

Once the cluster was up I was manually grabbing the kubeconfig from the server, so I set up a task to do it, slurp /etc/rancher/k3s/k3s.yaml off the server, rewrite the 127.0.0.1/localhost server address to the real server IP, and write it to ~/.kube/config on my desktop with a delegated task. (Fun bug, I originally used ansible_host in the rewrite, and since the task was delegated to localhost, it faithfully wrote "localhost" as the server address. delegate_to changes whose variables are in scope, reach across with hostvars.) I want to break this out into its own role too. The kubeconfig goes stale on every full rebuild since the cluster re-mints its CA, which is exactly why the fetch belongs in the playbook, it self-heals.

Two more small things for full unattended runs, SSH host keys are re-minted on every rebuild too, so rebuild.sh purges the stale known_hosts entries and the inventory sets StrictHostKeyChecking=accept-new, trust new hosts automatically, still refuse changed ones. And the vault password gets passed via a file instead of a prompt.

Then I tested the whole thing end to end, terraform destroy && terraform apply, then ansible-playbook, then kubectl get nodes. Two nodes, both Ready, from an empty datacenter, no hands. The relevant commands live in rebuild.sh in the root of the repo, that script is the acceptance test.

That's it! Phase 0 complete. Onto Phase 1.

## Phase 1: Reworks,

### Reworking ansible and rebuild
So the original ansible scripts were just playbooks and making sure everything worked. A lot could be reused so i put them in roles. Specifically i made two roles, get_cli_kubeconfig and install_cluster_k3s. They were originally combined and i may want to use them independently. I split out the variables which either went to vars if they were role internal or defaults if they were something that could be configured from outside the role. I also split out the environment variables which went on the InstallK3s_and_GetKubeConfig.yml file. Some handlers that could be moved to a handler file and then did some defaults. The main thing is now we can resuse get_cli_kubeconfig which is the really useful part and the ansible is better organized.

I also cleaned up the inventory and moved some variables there. The variables i moved into inventories were moved out of the roles because i wanted to make sure everything was reusable and those variables were deployment specific. So group_vars/agents  got the k3s_server_url which is deployment specific and the vault file was moved to all so its always loaded. That allowed me to remove it from the rebuild.sh script along with some other edits ill talk about in a bit. Then i renamed the inventory file for organization.

The rebuild.sh file had some changes. I did a set to fix some of the weird things happening on runs, specifically when something failed the bash script continued running and it created an incomplete environment on each run. So i did a set. -e which exits on error, -u which says any undefined variables are errors, -o pipefail makes sure that if any stage fails the whole script fails. Then i made changes to the ansible-playbook command based on renamed files and the vault file being loaded automatically. The ssh-keygen change is just so i no longer clober my own environment each time i run this script just the ip addresses i want (still hard coded for now). Kubectl changed and i added wait just to prevent another race condition like when systemctl restarted and ansible crashes because the service it was using restarted.

I also realized that there was a premade role from rancher that uses ansible to install k3s, in the future we'll be moving to that when we need more advanced features like HA. Right now this was fine to learn the ins and outs of the k3s installer. https://github.com/k3s-io/k3s-ansible.


### Installing argocd
I manually installed the argo cli in /usr/local/bin but itll be automated configuration later (lets try and hunt down a role). It was straight forward i followed the insturctions on the website and then did a kubectl port-forward svc/guestbook-ui 8081:80 -n default seo that i could make sure the basic app worked. I ran the basic app with the command line just to make sure everything was hooked up correctly. The real task will be writing and understanding the argocd spec.

### running argo cd
So to run argocd you can use the command line or you can setup a manifest for argo to view in the argocd namespace and let it create resources based on that. The full pattern we want is to setup a manifest so we're going for that. Argo manifest files can be used to specify kustomize, helm or oci files. We're not doing any of that. We're doing a fourth thing where we setup the argo file to look at a repo and recursively look through that repo for files speicified inside the repo. That uses the directory block. The full specification for an argo manifest can be found here https://github.com/argoproj/argo-cd/blob/master/docs/operator-manual/application.yaml and with it and https://argo-cd.readthedocs.io/en/stable/user-guide/directory/ this getting started we can specify a repo and a destination for our artifacts. We setup recurision and specified a path to our cluster folder.

<!-- this is a work in progress i think -->
The root apps goal is to point at my repo and search it for files like the guestbook app. It has recursion and it places all its files into the argocd namespace because the argocd namespace is where the CRD instances go. we use the destination that is the internal kubernetes service api address. The finalizer is a kubernetes object that dictates how objects are deleted in kuberentes, in this case it says delete the children before the parent. The root object does own the objects it discovered but it own some specifically. It own the WORK ORDER in this case the work order is the CRD. So the root object owns all the manifest files that actually create the workloads. The order is root work order -> guestbook work order -> guest application workloads