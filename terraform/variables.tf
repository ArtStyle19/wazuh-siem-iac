# =============================================================================
# Hypervisor
# =============================================================================

variable "libvirt_uri" {
  description = "Libvirt connection URI."
  type        = string
  default     = "qemu:///system"
}

variable "storage_pool" {
  description = "Libvirt storage pool for the base image, root disk and cloud-init seed. Must already exist and be active — `make preflight` checks this."
  type        = string
  default     = "vm-images"
}

variable "base_image_url" {
  description = "Debian cloud image used as the read-only backing store."
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

# =============================================================================
# Virtual machine
# =============================================================================

variable "vm_name" {
  description = "Name of the Wazuh server VM. Used as the libvirt domain name, the guest hostname and the volume prefix."
  type        = string
  default     = "wazuh-server"
}

variable "vm_memory_mib" {
  description = <<-EOT
    Guest RAM in MiB.

    Wazuh's all-in-one deployment has a hard floor of 4 GiB, and the breakdown
    is worth knowing rather than memorising:

      wazuh.indexer      1 GiB JVM heap (-Xms1g -Xmx1g) plus JVM overhead
      wazuh.dashboard    ~1 GiB (Node.js / OpenSearch Dashboards)
      wazuh.manager      ~0.5 GiB (analysisd, remoted, filebeat)
      Debian + Docker    ~0.4 GiB

    4096 works. 6144 is what Wazuh actually recommends and what you should use
    if the host can spare it.
  EOT
  type        = number
  default     = 4096

  validation {
    condition     = var.vm_memory_mib >= 4096
    error_message = "Wazuh all-in-one requires at least 4096 MiB. The indexer's JVM heap alone is 1 GiB; below this the indexer is OOM-killed as soon as agents start reporting."
  }
}

variable "vm_vcpu" {
  description = "Number of virtual CPUs. Two is Wazuh's documented minimum."
  type        = number
  default     = 2

  validation {
    condition     = var.vm_vcpu >= 2
    error_message = "Wazuh all-in-one requires at least 2 vCPUs."
  }
}

variable "vm_disk_gib" {
  # MEASURED on a working deployment, not estimated. An earlier version of this
  # description claimed "roughly 8 GiB after deployment". The real figure for a
  # single-node 4.14 stack with three agents is ~27 GiB, and it is dominated by one
  # directory that has nothing to do with how much you retain:
  #
  #   /var/ossec/queue/vd/feed    ~11   GiB   Vulnerability Detection CVE feed (RocksDB)
  #   container images            ~4    GiB
  #   /var/ossec/queue/indexer    ~1.6  GiB
  #   ALL Wazuh indices           ~16   MiB   <- not the problem, despite intuition
  #   FIM report_changes copies   ~56   KiB   <- also not the problem
  #
  # The CVE feed is downloaded in full regardless of agent count or retention window, so
  # index-retention (ISM) policies do not shrink it. Only disabling vulnerability
  # detection in the manager's ossec.conf does — at the cost of one of Wazuh's most
  # valuable features.
  description = "Root disk ceiling in GiB. Thin-provisioned, so a ceiling rather than an allocation. Budget ~27 GiB for a working 4.14 deployment: the Vulnerability Detection CVE feed alone is ~11 GiB."
  type        = number
  default     = 40

  validation {
    # 20 was the old floor and 30 the old default; both are genuinely too small. A
    # deployment with vulnerability detection enabled reaches 96% of a 30 GiB disk with
    # three agents and 16 MiB of indices.
    #
    # Note the guest does NOT protect itself at that point. The old error message here
    # claimed "the indexer refuses writes once the filesystem passes its flood-stage
    # watermark" — but on a single-node cluster
    # `cluster.routing.allocation.disk.watermark.enable_for_single_data_node` is false, so
    # the flood-stage read-only block never engages. The cluster stays green and the
    # filesystem simply fills up, which is a worse failure than being told to stop.
    condition     = var.vm_disk_gib >= 35
    error_message = "vm_disk_gib must be at least 35. Container images are ~4 GiB and the Vulnerability Detection CVE feed is ~11 GiB by itself; 30 GiB fills to 96% in ordinary use."
  }
}

variable "vm_mac_address" {
  description = "MAC address of the VM's interface. Pinned so the DHCP reservation below can target it, which is what keeps the dashboard URL and every agent's WAZUH_MANAGER stable across rebuilds."
  type        = string
  default     = "52:54:00:8a:01:10"

  validation {
    condition     = can(regex("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", var.vm_mac_address))
    error_message = "vm_mac_address must be lowercase colon-separated hex. Use the 52:54:00 prefix reserved for libvirt guests to avoid colliding with real hardware."
  }
}

# =============================================================================
# Network
# =============================================================================

variable "network_name" {
  description = "Name of the libvirt NAT network this project creates and owns."
  type        = string
  default     = "wazuh-lab"
}

variable "network_bridge" {
  description = "Linux bridge device backing the network. Must be <= 15 characters (kernel interface-name limit) and must not collide with an existing bridge."
  type        = string
  default     = "virbr-wazuh"

  validation {
    condition     = length(var.network_bridge) <= 15
    error_message = "network_bridge must be 15 characters or fewer — that is the kernel's IFNAMSIZ limit."
  }
}

variable "network_cidr" {
  description = "IPv4 subnet for the lab network. Must not overlap the default libvirt network (192.168.122.0/24) or anything on your LAN."
  type        = string
  default     = "192.168.140.0/24"

  validation {
    condition     = can(cidrhost(var.network_cidr, 0)) && tonumber(split("/", var.network_cidr)[1]) <= 24
    error_message = "network_cidr must be a valid IPv4 CIDR with a prefix of /24 or shorter."
  }
}

variable "network_host_index" {
  description = "Host index within network_cidr to reserve for the Wazuh server. The default puts it at .10, clear of the gateway at .1 and the dynamic pool at .100-.200."
  type        = number
  default     = 10

  validation {
    condition     = var.network_host_index >= 2 && var.network_host_index < 100
    error_message = "network_host_index must be between 2 and 99 so it stays outside the dynamic DHCP range."
  }
}

variable "dns_domain" {
  description = "DNS domain served by the network's dnsmasq instance. Guests resolve each other by <name>.<domain>."
  type        = string
  default     = "lab.local"
}

# =============================================================================
# Guest access
# =============================================================================

variable "admin_username" {
  description = "Unprivileged sudo account created by cloud-init at first boot."
  type        = string
  default     = "admin"
}

# The account Ansible CONNECTS as — deliberately separate from admin_username above.
#
# They start out the same: cloud-init creates the account, Ansible uses it. But the two
# are different kinds of thing, and conflating them means the automation account can
# only ever be changed by rebuilding the VM. cloud-init runs once, gated on instance-id,
# so editing admin_username on a live machine changes the rendered user-data and the
# generated inventory while the guest keeps the account it already has — the inventory
# then names a user that does not exist, and every playbook fails at connection.
#
# Splitting them makes the automation account rotatable on a running host: create the
# new one with `make bootstrap`, point this at it, re-apply to regenerate the inventory.
# The cloud-init account stays as the break-glass login that does not depend on Ansible
# having worked.
#
# null means "same as admin_username", which is the right default for a VM nobody has
# bootstrapped separately.
variable "ansible_user" {
  description = "Account Ansible connects as. null = use admin_username (the cloud-init account)."
  type        = string
  default     = null
}

# =============================================================================
# Transit network
# =============================================================================

variable "transit_network_name" {
  description = <<-EOT
    An existing libvirt network the manager ALSO attaches to, so hosts that cannot
    reach the lab network can still reach its WireGuard port.

    This models what the internet provides for free in production: a VPS and the
    manager already share a routable network, and the manager exposes only 51820/udp
    on it. libvirt REJECTs forwarding between its own networks, so without a shared
    network a guest elsewhere cannot reach the manager at all — a libvirt lab is a
    *harder* starting point than the internet, not an easier one.

    Set to null for a purely local lab where every agent is on the lab network or is
    the hypervisor itself.
  EOT
  type        = string
  default     = "default"
}

variable "transit_mac_address" {
  description = "MAC of the manager's interface on the transit network. Pinned so a DHCP reservation can be added later if a stable address is wanted."
  type        = string
  default     = "52:54:00:8a:01:11"

  validation {
    condition     = can(regex("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", var.transit_mac_address))
    error_message = "transit_mac_address must be lowercase colon-separated hex."
  }
}

# =============================================================================
# Guest access
# =============================================================================

variable "ssh_public_key_path" {
  description = "Path to the SSH public key authorised on the VM."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Path to the matching private key. Only written into the generated Ansible inventory; Terraform never reads the key itself."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "timezone" {
  description = "Guest timezone as an IANA zone name."
  type        = string
  default     = "America/Lima"
}

# =============================================================================
# Wazuh
# =============================================================================

variable "wazuh_version" {
  description = <<-EOT
    Wazuh release deployed by Ansible. Terraform only passes it through to the
    generated inventory so that one variable drives both layers.

    Pin it. 4.14.7 is the current stable line; the 5.0.0 tags on Docker Hub are
    betas and must not be used for anything you intend to keep.
  EOT
  type        = string
  default     = "4.14.7"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.wazuh_version))
    error_message = "wazuh_version must be an exact three-part version, e.g. 4.14.7. Floating tags like `latest` make deployments unreproducible."
  }
}
