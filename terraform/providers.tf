provider "libvirt" {
  # qemu:///system rather than qemu:///session: system-level domains can use
  # libvirt-managed NAT networks and shared storage pools. Requires membership
  # of the `libvirt` group — see `make preflight`.
  uri = var.libvirt_uri
}

provider "local" {}
