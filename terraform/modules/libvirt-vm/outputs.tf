# =============================================================================
# Output contract
# =============================================================================
# These four outputs are the module's public interface. A replacement module for
# a cloud provider (Hetzner, DigitalOcean, AWS...) that emits the same four
# names is a drop-in substitute, because nothing downstream — including the
# rendered Ansible inventory — knows or cares that libvirt is involved.
# =============================================================================

output "ip_address" {
  description = "IPv4 address of the VM's primary interface."
  value = coalesce(
    var.ip_address,
    try(tolist(data.libvirt_domain_interface_addresses.vm[0].interfaces[0].addrs)[0], null),
  )
}

output "hostname" {
  description = "Guest hostname (short form)."
  value       = var.vm_name
}

output "fqdn" {
  description = "Guest fully-qualified domain name."
  value       = local.fqdn
}

output "ssh_user" {
  description = "Username to connect as. Password auth is disabled; only the injected SSH key works."
  value       = var.admin_username
}

# -----------------------------------------------------------------------------
# Libvirt-specific extras (not part of the portable contract)
# -----------------------------------------------------------------------------

output "domain_id" {
  description = "Libvirt domain ID."
  value       = libvirt_domain.vm.id
}

output "domain_uuid" {
  description = "Libvirt domain UUID — stable across restarts, unlike the ID."
  value       = libvirt_domain.vm.uuid
}

output "mac_address" {
  description = "MAC address of the primary interface."
  value       = var.mac_address
}

output "root_volume_path" {
  description = "Host filesystem path of the VM's root disk."
  value       = libvirt_volume.root.path
}
