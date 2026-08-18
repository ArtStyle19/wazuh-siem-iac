# ============================================================================
# Identity
# ============================================================================

variable "vm_name" {
  description = "Libvirt domain name. Also used as the guest hostname and as the prefix for every volume this module creates."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.vm_name))
    error_message = "vm_name must be a lowercase DNS label: letters, digits and hyphens only, 3-63 characters, not starting or ending with a hyphen."
  }
}

variable "domain_suffix" {
  description = "DNS domain appended to vm_name to form the guest FQDN."
  type        = string
  default     = "lab.local"
}

variable "description" {
  description = "Free-text description stored in the domain XML. Useful for `virsh desc` when several projects share a hypervisor."
  type        = string
  default     = "Managed by Terraform"
}

# ============================================================================
# Storage
# ============================================================================

variable "storage_pool" {
  description = "Name of the libvirt storage pool that will hold the base image, the overlay disk and the cloud-init ISO."
  type        = string
  default     = "default"
}

variable "base_image_url" {
  description = "URL (or local file:// path) of the cloud image to use as the read-only backing store."
  type        = string
}

variable "base_image_volume_name" {
  description = "Volume name for the downloaded base image. Shared between VMs on purpose: the download happens once and every overlay backs onto it."
  type        = string
  default     = "debian-13-genericcloud-amd64.qcow2"
}

variable "disk_gib" {
  description = "Virtual size of the VM's root disk in GiB. qcow2 is thin-provisioned, so this is a ceiling and not an upfront allocation."
  type        = number
  default     = 20

  validation {
    condition     = var.disk_gib >= 5 && var.disk_gib <= 2048
    error_message = "disk_gib must be between 5 and 2048."
  }
}

# ============================================================================
# Compute
# ============================================================================

variable "memory_mib" {
  description = "Guest RAM in MiB."
  type        = number
  default     = 2048

  validation {
    condition     = var.memory_mib >= 512
    error_message = "memory_mib must be at least 512."
  }
}

variable "vcpu" {
  description = "Number of virtual CPUs."
  type        = number
  default     = 2

  validation {
    condition     = var.vcpu >= 1 && var.vcpu <= 64
    error_message = "vcpu must be between 1 and 64."
  }
}

variable "cpu_mode" {
  description = <<-EOT
    Libvirt CPU mode. `host-passthrough` exposes the physical CPU's full feature
    set, which is both the fastest option and the one least likely to leave a
    modern guest short of an instruction it expects. Use `host-model` instead if
    you ever need to live-migrate between non-identical hosts.
  EOT
  type        = string
  default     = "host-passthrough"

  validation {
    condition     = contains(["host-passthrough", "host-model", "custom"], var.cpu_mode)
    error_message = "cpu_mode must be one of: host-passthrough, host-model, custom."
  }
}

# ============================================================================
# Network
# ============================================================================

variable "network_name" {
  description = "Name of the libvirt network to attach the primary interface to."
  type        = string
}

variable "mac_address" {
  description = "MAC address of the primary interface. Pinning it lets the network's DHCP server hand out a reserved address, so the guest IP survives a destroy/apply cycle."
  type        = string

  validation {
    condition     = can(regex("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", var.mac_address))
    error_message = "mac_address must be lowercase colon-separated hex, e.g. 52:54:00:8a:01:10."
  }
}

variable "ip_address" {
  description = "The address this VM is expected to receive. Set it when the network holds a matching DHCP reservation; leave null to discover the leased address at apply time instead."
  type        = string
  default     = null

  validation {
    condition     = var.ip_address == null || can(cidrhost("${var.ip_address}/32", 0))
    error_message = "ip_address must be a valid IPv4 address or null."
  }
}

variable "extra_networks" {
  description = <<-EOT
    Additional libvirt networks to attach beyond the primary one.

    The primary interface is where the machine lives: it carries the default route,
    holds the DHCP reservation, and is what `wait_for_ip` waits for. Extra interfaces
    exist to reach somewhere the primary cannot — a shared transit network, a storage
    network, a management VLAN.

    `use_routes` defaults to false, and that default is the important part: an extra
    interface that installs its own default route silently changes where all of the
    machine's egress goes. A second NIC should add reachability, not reroute the host.
  EOT

  type = list(object({
    network     = string
    mac_address = string
    # DHCP only. Static addressing for a secondary interface belongs in the network's
    # DHCP reservations, where it is declared once, rather than in the guest.
    use_routes = optional(bool, false)
    use_dns    = optional(bool, false)
  }))
  default = []

  validation {
    condition = length(var.extra_networks) == length(distinct([
      for n in var.extra_networks : n.mac_address
    ]))
    error_message = "Each extra network needs a unique mac_address."
  }

  validation {
    condition = alltrue([
      for n in var.extra_networks :
      can(regex("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", n.mac_address))
    ])
    error_message = "Each extra network's mac_address must be lowercase colon-separated hex."
  }
}

variable "wait_for_ip_timeout" {
  description = <<-EOT
    Seconds Terraform will wait for the guest to claim a DHCP lease before
    failing the apply.

    Keep this enabled. A VM that boots but never reaches the network is the
    single most common libvirt failure mode, and without this guardrail
    Terraform reports success on a domain that is silently hung.
  EOT
  type        = number
  default     = 300
}

# ============================================================================
# Guest bootstrap (cloud-init)
# ============================================================================

variable "admin_username" {
  description = "Name of the unprivileged sudo-capable account created by cloud-init."
  type        = string
  default     = "admin"
}

variable "ssh_public_key" {
  description = "OpenSSH public key authorised for admin_username. Password authentication is disabled, so this is the only way in."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) ", trimspace(var.ssh_public_key)))
    error_message = "ssh_public_key must be an OpenSSH public key (ssh-ed25519, ssh-rsa or ecdsa-sha2-*). Did you point at the private key by mistake?"
  }
}

variable "timezone" {
  description = "Guest timezone, as an IANA zone name."
  type        = string
  default     = "Etc/UTC"
}

variable "extra_packages" {
  description = <<-EOT
    Packages appended to the minimal bootstrap set.

    Keep this short. cloud-init's job here is to make the VM reachable by SSH
    and manageable by Ansible; installing the workload from cloud-init means
    every configuration change costs a full VM rebuild.
  EOT
  type        = list(string)
  default     = []
}

# ============================================================================
# Lifecycle
# ============================================================================

variable "autostart" {
  description = "Whether libvirt should start this domain when the host boots. Off by default so a lab VM does not silently consume RAM after a reboot."
  type        = bool
  default     = false
}
