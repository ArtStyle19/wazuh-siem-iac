# =============================================================================
# libvirt-vm — a Debian cloud-image VM on libvirt/KVM
# =============================================================================
#
# This module deliberately spells out the domain devices that libvirt does NOT
# add for you. Omitting them is what turned this project's first attempt into a
# domain that reported `running` while the guest kernel spun at 100% CPU and
# never touched the network. See docs/TROUBLESHOOTING.md for the post-mortem.
#
# The output contract (ip_address / hostname / ssh_user) is intentionally
# provider-agnostic so a cloud VM module can replace this one without the
# Ansible layer noticing. See docs/PORTING-TO-VPS.md.
# =============================================================================

locals {
  fqdn = "${var.vm_name}.${var.domain_suffix}"

  # Minimal bootstrap set. Everything here exists to make the VM reachable and
  # manageable, not to install a workload:
  #   qemu-guest-agent  -> host can query the guest's IP and shut it down cleanly
  #   python3           -> Ansible's interpreter
  #   python3-apt       -> required by Ansible's apt module; not in the cloud image
  #   cloud-guest-utils -> provides growpart, needed to expand the root filesystem
  base_packages = [
    "qemu-guest-agent",
    "python3",
    "python3-apt",
    "cloud-guest-utils",
    "ca-certificates",
    "curl",
    "gnupg",
  ]

  packages = distinct(concat(local.base_packages, var.extra_packages))
}

# -----------------------------------------------------------------------------
# Base image (read-only backing store)
# -----------------------------------------------------------------------------
# Downloaded once and shared by every overlay that points at it. Keeping it as a
# separate resource is what makes rebuilding a VM cheap: `terraform destroy`
# followed by `apply` reuses this volume instead of re-fetching ~400 MB.
resource "libvirt_volume" "base" {
  name = var.base_image_volume_name
  pool = var.storage_pool

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = var.base_image_url
    }
  }
}

# -----------------------------------------------------------------------------
# Root disk (copy-on-write overlay)
# -----------------------------------------------------------------------------
resource "libvirt_volume" "root" {
  name = "${var.vm_name}-root.qcow2"
  pool = var.storage_pool

  # qcow2 is thin-provisioned: this is a ceiling, not an allocation.
  capacity      = var.disk_gib * 1024 * 1024 * 1024
  capacity_unit = "B"

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.base.path

    format = {
      type = "qcow2"
    }
  }

  # ---------------------------------------------------------------------------
  # capacity is a CREATE-TIME value. Growing an existing disk is done outside
  # Terraform, and this lifecycle block is what keeps that honest.
  # ---------------------------------------------------------------------------
  # The provider does not support changing it, and it fails in the worst possible
  # order — it PLANS an in-place update and then refuses during apply:
  #
  #   Plan: 0 to add, 1 to change, 0 to destroy.
  #   Error: Storage volumes cannot be updated. All changes require replacement.
  #
  # `size`/`capacity` is not marked ForceNew in the schema, so Terraform believes the
  # change is applicable. Nothing is destroyed — the apply just errors — but the plan
  # tells you the opposite of the truth right up until it fails.
  #
  # It is compounded by refresh: the provider never re-reads capacity from libvirt, so
  # after growing the disk out of band the state still holds the old value. libvirt and
  # `virsh vol-info` report 40 GiB while Terraform insists it is 30 and offers to "fix"
  # it — a diff that can never be applied and that breaks every later `terraform apply`
  # for reasons unrelated to whatever you were actually changing.
  #
  # So capacity is ignored after creation. A fresh build still honours var.disk_gib;
  # an existing disk is grown with the running domain in place:
  #
  #   virsh -c qemu:///system blockresize <domain> <path-to-qcow2> 40G
  #   # NOT `virsh vol-resize`: that shells out to qemu-img, which cannot take a write
  #   # lock on a disk a running QEMU already holds. blockresize goes through QEMU
  #   # itself, which owns the file, so it works on a live domain.
  #   sudo growpart /dev/vda 1 && sudo resize2fs /dev/vda1     # inside the guest
  #
  # Then raise var.disk_gib to match, so a rebuild starts at the size you ended up
  # needing rather than the size you first guessed.
  lifecycle {
    ignore_changes = [capacity]
  }
}

# -----------------------------------------------------------------------------
# cloud-init NoCloud datasource
# -----------------------------------------------------------------------------
resource "libvirt_cloudinit_disk" "seed" {
  name = "${var.vm_name}-seed"

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname       = var.vm_name
    fqdn           = local.fqdn
    admin_username = var.admin_username
    ssh_public_key = trimspace(var.ssh_public_key)
    timezone       = var.timezone
    packages       = local.packages
  })

  meta_data = templatefile("${path.module}/templates/meta-data.yaml.tftpl", {
    instance_id = var.vm_name
    hostname    = var.vm_name
  })

  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    mac_address    = var.mac_address
    extra_networks = var.extra_networks
  })
}

# libvirt_cloudinit_disk (provider 0.9.8) has no `pool` argument: it writes the
# ISO to /tmp/terraform-provider-libvirt-cloudinit/. Copying it into the target
# pool keeps the domain's disk backed by a managed volume rather than a path
# under /tmp that a reboot or tmpfiles cleanup could remove underneath a
# running guest.
resource "libvirt_volume" "seed" {
  name = "${var.vm_name}-seed.iso"
  pool = var.storage_pool

  # No `target.format`, for the same reason the serial device below has no
  # `source`: libvirt derives the value and then reports its own answer back.
  #
  # Declaring `format.type = "raw"` here fails the apply with
  #   .target.format.type: was cty.StringVal("raw"), but now cty.StringVal("iso")
  # because libvirt probes the file, recognises ISO9660 and records the volume
  # format as `iso`. Leaving it unset lets libvirt classify the volume, and the
  # provider does not track an optional attribute the config never set — so this
  # re-plans clean.
  #
  # Note this is volume *metadata* only. The domain's cdrom below still declares
  # `driver.type = "raw"`, which is correct and unrelated: qemu reads the ISO's
  # bytes raw regardless of how libvirt catalogues the volume.

  create = {
    content = {
      url = libvirt_cloudinit_disk.seed.path
    }
  }
}

# -----------------------------------------------------------------------------
# Domain
# -----------------------------------------------------------------------------
resource "libvirt_domain" "vm" {
  name        = var.vm_name
  type        = "kvm"
  description = var.description
  autostart   = var.autostart

  memory      = var.memory_mib
  memory_unit = "MiB"
  vcpu        = var.vcpu

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"

    boot_devices = [
      { dev = "hd" },
    ]
  }

  # ---------------------------------------------------------------------------
  # REQUIRED. Do not remove.
  # ---------------------------------------------------------------------------
  # libvirt does not add <features> unless you ask for it, and a q35 guest needs
  # ACPI to enumerate the PCIe bus. Without it the kernel hangs during early
  # boot with no diagnostic whatsoever.
  features = {
    acpi = true
    apic = {}

    # Hides the VMware backdoor port. Harmless on KVM and matches what
    # virt-manager emits, which keeps `virsh dumpxml` diffs quiet.
    vm_port = {
      state = "off"
    }
  }

  # host-passthrough gives the guest the physical CPU's feature set. The default
  # (`custom` + the ancient `qemu64` model) omits instructions that current
  # distributions increasingly assume.
  #
  # `migratable` is deliberately not set: provider 0.9.8 renders it as yes/no
  # while libvirt's schema demands on/off, so setting it fails the apply with
  # "Invalid value for attribute 'migratable' in element 'cpu': 'yes'".
  # Libvirt fills in migratable='on' by itself, so nothing is lost.
  cpu = {
    mode  = var.cpu_mode
    check = "none"
  }

  clock = {
    offset = "utc"

    timer = [
      { name = "rtc", tick_policy = "catchup" },
      { name = "pit", tick_policy = "delay" },
      { name = "hpet", present = "no" },
    ]
  }

  # A server has no business suspending itself.
  pm = {
    suspend_to_mem  = { enabled = "no" }
    suspend_to_disk = { enabled = "no" }
  }

  devices = {

    # -------------------------------------------------------------------------
    # Disks
    # -------------------------------------------------------------------------
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.root.pool
            volume = libvirt_volume.root.name
          }
        }

        target = {
          dev = "vda"
          bus = "virtio"
        }

        driver = {
          name = "qemu"
          type = "qcow2"

          # writeback is the pragmatic lab choice; discard=unmap lets fstrim in
          # the guest return freed blocks to the host filesystem, which matters
          # when the backing filesystem is nearly full.
          cache   = "writeback"
          discard = "unmap"
        }
      },

      {
        device    = "cdrom"
        read_only = true

        source = {
          volume = {
            pool   = libvirt_volume.seed.pool
            volume = libvirt_volume.seed.name
          }
        }

        target = {
          dev = "sda"
          bus = "sata"
        }

        driver = {
          name = "qemu"
          type = "raw"
        }
      },
    ]

    # -------------------------------------------------------------------------
    # Network
    # -------------------------------------------------------------------------
    # Interface ORDER is significant: libvirt assigns PCI slots in this order, and
    # the guest names interfaces from those slots. The primary must stay first so
    # its predictable name and the cloud-init `set-name: eth0` match.
    #
    # Only the primary declares wait_for_ip. Gating the apply on a secondary
    # interface would make an auxiliary network a hard dependency of the whole
    # build, which is the opposite of why it exists.
    interfaces = concat(
      [
        {
          type = "network"

          mac = {
            address = var.mac_address
          }

          source = {
            network = {
              network = var.network_name
            }
          }

          model = {
            type = "virtio"
          }

          # The guardrail. Terraform blocks until libvirt sees a DHCP lease for
          # this interface, so a guest that fails to boot fails the apply instead
          # of being reported as healthy.
          wait_for_ip = {
            source  = "lease"
            timeout = var.wait_for_ip_timeout
          }
        },
      ],
      [
        for extra in var.extra_networks : {
          type = "network"

          mac = {
            address = extra.mac_address
          }

          source = {
            network = {
              network = extra.network
            }
          }

          model = {
            type = "virtio"
          }
        }
      ],
    )

    # -------------------------------------------------------------------------
    # Serial console
    # -------------------------------------------------------------------------
    # Debian cloud images ship `console=ttyS0,115200n8` on the kernel command
    # line, so this single device turns `virsh console <vm>` into a full boot
    # log. It is the difference between debugging a hung guest and guessing.
    #
    # Two things are load-bearing here and both look like omissions:
    #
    #   1. No `source`. A pty's path is assigned by libvirt at runtime, but the
    #      provider's schema marks source.pty.path as *required* and then
    #      re-reads the live value. Setting it to "" fails the apply with
    #      "Provider produced inconsistent result after apply: was "", but now
    #      "/dev/pts/4"". Omitting source entirely is also the correct libvirt
    #      XML — and the provider still emits <serial type='pty'>.
    #
    #   2. Only the serial is declared. Libvirt mirrors it into a matching
    #      <console type='pty'>, which is what `virsh console` attaches to.
    #
    # Verified: the resulting domain re-plans clean, with no drift.
    serials = [
      {
        target = {
          type = "isa-serial"
          port = 0

          model = {
            name = "isa-serial"
          }
        }
      },
    ]

    # -------------------------------------------------------------------------
    # QEMU guest agent
    # -------------------------------------------------------------------------
    # Pairs with the qemu-guest-agent package installed by cloud-init. Enables
    # `virsh domifaddr <vm> --source agent`, filesystem-consistent snapshots and
    # a graceful `virsh shutdown`. Without this channel the installed agent has
    # nothing to talk to.
    channels = [
      {
        source = {
          unix = {}
        }

        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
      },
    ]

    # -------------------------------------------------------------------------
    # Entropy
    # -------------------------------------------------------------------------
    # Without a virtio-rng device the guest's entropy pool fills slowly, which
    # stalls anything doing key generation early in boot — sshd host keys, TLS
    # certificate creation, the Wazuh indexer's JVM.
    rngs = [
      {
        model = "virtio"

        backend = {
          random = "/dev/urandom"
        }
      },
    ]

    mem_balloon = {
      model = "virtio"

      stats = {
        period = 10
      }
    }

    graphics = [
      {
        spice = {
          auto_port = true

          # Loopback only. A SPICE port on 0.0.0.0 is an unauthenticated
          # console on the network.
          listen = "127.0.0.1"
        }
      },
    ]
  }

  running = true
}

# -----------------------------------------------------------------------------
# Address discovery
# -----------------------------------------------------------------------------
# Only needed when the caller has not reserved an address. With a DHCP
# reservation the address is an input we control, and wait_for_ip above already
# proved the guest claimed it.
data "libvirt_domain_interface_addresses" "vm" {
  count = var.ip_address == null ? 1 : 0

  domain = libvirt_domain.vm.id
  source = "lease"

  depends_on = [libvirt_domain.vm]
}
