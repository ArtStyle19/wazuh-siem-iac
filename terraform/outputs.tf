output "dashboard_url" {
  description = "Wazuh dashboard. Serves a self-signed certificate, so expect a browser warning on first visit."
  value       = "https://${module.wazuh_server.ip_address}"
}

output "api_url" {
  description = "Wazuh server API endpoint."
  value       = "https://${module.wazuh_server.ip_address}:55000"
}

output "vm_ip" {
  description = "IPv4 address of the Wazuh server."
  value       = module.wazuh_server.ip_address
}

output "vm_fqdn" {
  description = "FQDN of the Wazuh server, resolvable from other guests on this network."
  value       = module.wazuh_server.fqdn
}

# Deliberately the cloud-init account, NOT var.ansible_user. This is the break-glass
# login — the one that exists because the VM booted, not because a playbook succeeded.
# When the automation account is the thing that is broken, an SSH command naming it is
# no help.
output "ssh_command" {
  description = "Ready-to-paste SSH command, as the cloud-init break-glass account."
  value       = "ssh -i ${var.ssh_private_key_path} ${module.wazuh_server.ssh_user}@${module.wazuh_server.ip_address}"
}

output "console_command" {
  description = "Serial console. This is the tool to reach for when a VM boots but never appears on the network. Detach with Ctrl-]."
  value       = "virsh -c ${var.libvirt_uri} console ${var.vm_name}"
}

output "network" {
  description = "Lab network summary."
  value = {
    name       = libvirt_network.lab.name
    bridge     = var.network_bridge
    cidr       = var.network_cidr
    gateway    = local.gateway_ip
    dhcp_range = "${local.dhcp_range_start}-${local.dhcp_range_end}"
    dns_domain = var.dns_domain
  }
}

output "agent_enrollment" {
  description = "Values a Wazuh agent needs in order to register with this manager."
  value = {
    manager_address    = module.wazuh_server.ip_address
    enrollment_port    = 1515
    communication_port = 1514
    playbook           = "ansible-playbook ansible/agent.yml -i <inventory> -e wazuh_manager_address=${module.wazuh_server.ip_address}"
  }
}

output "next_steps" {
  description = "What to run once the apply completes."
  value       = <<-EOT

    VM is up and holding a DHCP lease at ${module.wazuh_server.ip_address}.
    Nothing is installed on it yet — that is Ansible's job.

      1. Configure the stack (~10 min, pulls ~3 GiB of images):

           make configure

      2. Confirm it came up:

           make verify

      3. Open the dashboard and log in as `admin` with the password from your
         vault (`make vault-show`):

           ${"https://${module.wazuh_server.ip_address}"}

      4. Enrol this workstation as the first agent:

           make agent-local

    If step 1 cannot reach the host, the VM booted but the guest is unhealthy.
    Look at the serial console before anything else:

         virsh -c ${var.libvirt_uri} console ${var.vm_name}

  EOT
}
