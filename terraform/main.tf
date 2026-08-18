# =============================================================================
# Wazuh SIEM lab — root module
# =============================================================================
#
# Terraform's remit stops at "a VM exists, it has a known address, and it is
# reachable by SSH". Everything installed inside it belongs to Ansible.
#
# That boundary is the point of the project. It is what lets you re-run
# configuration without rebuilding a VM, and what makes the eventual move to a
# VPS a change of one module call rather than a rewrite.
# =============================================================================

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
# A dedicated NAT network rather than libvirt's shared `default`. Two reasons:
#
#   1. Ownership. Terraform can create, reserve addresses on, and destroy a
#      network it made. Mutating a pre-existing `default` that other VMs depend
#      on means a `terraform destroy` here breaks them.
#
#   2. Reservations. The static DHCP host entry below is what gives the VM a
#      stable address, which in turn is what lets every Wazuh agent keep a fixed
#      WAZUH_MANAGER value across rebuilds.
resource "libvirt_network" "lab" {
  name      = var.network_name
  autostart = true

  bridge = {
    name = var.network_bridge
    stp  = "on"
  }

  # NAT: guests reach the internet (apt, Docker Hub, Wazuh's repos) and the
  # host reaches guests directly, but nothing on the LAN can route inbound.
  forward = {
    mode = "nat"

    nat = {
      ports = [
        { start = 1024, end = 65535 },
      ]
    }
  }

  domain = {
    name = var.dns_domain
    # Queries for this domain are answered by this dnsmasq only and never
    # leaked upstream.
    local_only = "yes"
  }

  dns = {
    enable = "yes"
  }

  ips = [
    {
      family  = "ipv4"
      address = local.gateway_ip
      prefix  = local.prefix

      dhcp = {
        ranges = [
          {
            start = local.dhcp_range_start
            end   = local.dhcp_range_end
          },
        ]

        # The reservation. dnsmasq hands this exact address to this exact MAC,
        # and registers the name in DNS while it is at it.
        hosts = [
          {
            mac  = var.vm_mac_address
            ip   = local.wazuh_ip
            name = var.vm_name
          },
        ]
      }
    },
  ]
}

# -----------------------------------------------------------------------------
# Wazuh server VM
# -----------------------------------------------------------------------------
module "wazuh_server" {
  source = "./modules/libvirt-vm"

  vm_name       = var.vm_name
  domain_suffix = var.dns_domain
  description   = "Wazuh SIEM (manager + indexer + dashboard) — ${local.managed_by}"

  storage_pool   = var.storage_pool
  base_image_url = var.base_image_url
  disk_gib       = var.vm_disk_gib

  memory_mib = var.vm_memory_mib
  vcpu       = var.vm_vcpu

  network_name = libvirt_network.lab.name
  mac_address  = var.vm_mac_address
  # Passed in rather than discovered: the reservation above means we already
  # know it, and the module's wait_for_ip proves the guest actually claimed it.
  ip_address = local.wazuh_ip

  # A second interface on a shared network, so agents with no route to the lab
  # network can still reach the manager's WireGuard port.
  #
  # This is the lab's stand-in for the internet. In production the list is EMPTY: a
  # VPS and the manager are already mutually routable, and the only thing needed is
  # that 51820/udp is reachable. The lab has to manufacture that path because libvirt
  # REJECTs forwarding between its networks.
  #
  # use_routes and use_dns stay false. The lab network remains the manager's default
  # route and resolver; this NIC exists to be reached ON, not to change how the
  # manager reaches out.
  extra_networks = var.transit_network_name == null ? [] : [
    {
      network     = var.transit_network_name
      mac_address = var.transit_mac_address
      use_routes  = false
      use_dns     = false
    },
  ]

  admin_username = var.admin_username
  ssh_public_key = local.ssh_public_key
  timezone       = var.timezone
}

# -----------------------------------------------------------------------------
# Hand-off to Ansible
# -----------------------------------------------------------------------------
# Rendering a static inventory from Terraform's own outputs means the two layers
# cannot disagree about where the VM is.
#
# The alternative is the cloud.terraform.terraform_provider inventory plugin,
# which reads state directly and needs no generated file. It is the better
# choice once state lives in a remote backend that CI can read. For a local lab
# a rendered file is easier to inspect when something goes wrong — you can cat
# it — and one less collection to install.
resource "local_file" "ansible_inventory" {
  filename = local.ansible_inventory_path
  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    group                = "wazuh_servers"
    hostname             = module.wazuh_server.hostname
    ip_address           = module.wazuh_server.ip_address
    ssh_user             = coalesce(var.ansible_user, module.wazuh_server.ssh_user)
    ssh_private_key_path = pathexpand(var.ssh_private_key_path)
    wazuh_version        = var.wazuh_version
    timezone             = var.timezone
  })

  # 0640, not the module default of 0777. The file names a private key path and
  # is gitignored.
  file_permission      = "0640"
  directory_permission = "0750"
}
