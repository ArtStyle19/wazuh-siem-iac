locals {
  # ---------------------------------------------------------------------------
  # Addressing, derived from network_cidr so changing the subnet changes
  # everything consistently. Hard-coding .1 / .10 / .100 in three places is how
  # networks drift out of sync with their documentation.
  # ---------------------------------------------------------------------------
  gateway_ip = cidrhost(var.network_cidr, 1)
  # No `netmask` here: cloud-init's network-config takes the prefix length, not a
  # dotted mask, so a netmask local would be a value nothing consumes. tflint's
  # terraform_unused_declarations rule catches exactly that.
  prefix = tonumber(split("/", var.network_cidr)[1])

  wazuh_ip = cidrhost(var.network_cidr, var.network_host_index)

  # Dynamic pool for any future lab VM, kept clear of the reserved block.
  dhcp_range_start = cidrhost(var.network_cidr, 100)
  dhcp_range_end   = cidrhost(var.network_cidr, 200)

  # ---------------------------------------------------------------------------
  # Paths. Expanded here rather than in variable defaults, which cannot contain
  # expressions.
  # ---------------------------------------------------------------------------
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # Relative, NOT abspath().
  #
  # local_file records its filename in state. An absolute path bakes the checkout's
  # location into it, so moving or cloning the repo elsewhere makes Terraform see a
  # vanished file and plan a recreation — drift caused purely by where the directory
  # sits on disk. A relative path resolves against terraform/ (the Makefile always
  # invokes `terraform -chdir=terraform`) and travels with the repo.
  ansible_dir = "${path.module}/../ansible"

  # No file extension, deliberately. Ansible's inventory directory scan ignores
  # `.ini` (it is in inventory_ignore_extensions by default), so a file named
  # hosts.ini inside inventory/ is silently skipped and the host list comes back
  # empty. See the note in ansible/ansible.cfg.
  ansible_inventory_path = "${local.ansible_dir}/inventory/hosts"

  # ---------------------------------------------------------------------------
  # Tagging. Libvirt has no tag concept, so this goes into the domain
  # description — which is what `virsh desc <domain>` prints, and the only place
  # a human poking at the hypervisor will look to find out who owns a VM.
  # ---------------------------------------------------------------------------
  managed_by = "terraform:terraform-wazuh-lab"
}
