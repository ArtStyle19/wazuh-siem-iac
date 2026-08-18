terraform {
  # 1.12 is the floor for the nested-attribute syntax the libvirt provider's
  # 0.9.x schema uses. Pinning a range rather than an exact version keeps the
  # project usable on a colleague's slightly different install.
  required_version = ">= 1.12"

  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # Pessimistic constraint: accept 0.9.8 and later 0.9.x patches, never 0.10.
      # A pre-1.0 provider can and does break its schema on minor bumps.
      version = "~> 0.9.8"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
