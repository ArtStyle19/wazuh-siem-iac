# =============================================================================
# State backend
# =============================================================================
#
# Local state, which is the right choice for exactly one situation: a single
# operator on a single machine with no CI. That is this lab, today.
#
# It is also the thing you migrate first when the project moves to a VPS, so the
# target configuration is written out below rather than left as an exercise.
#
# WHY IT MATTERS
#
#   1. State is a secret. It records every attribute of every resource in
#      plaintext, including values marked `sensitive` in outputs. Never commit
#      it. The .gitignore excludes *.tfstate* — verify that before your first
#      push, not after.
#
#   2. Local state has no locking. Two concurrent applies silently corrupt it.
#      One person on one laptop is fine; a CI pipeline is not.
#
#   3. Local state has no history. `terraform.tfstate.backup` is one generation
#      deep. A remote backend with object versioning is your undo button.
#
# MIGRATING
#
#   Uncomment one block below, then run `terraform init -migrate-state`.
#   Terraform copies the local state up and switches over in one step.
#
# ---- S3 (or any S3-compatible store: MinIO, Backblaze B2, Cloudflare R2) ----
#
#   terraform {
#     backend "s3" {
#       bucket       = "my-tfstate"
#       key          = "wazuh-lab/terraform.tfstate"
#       region       = "eu-central-1"
#       encrypt      = true
#       use_lockfile = true   # S3-native locking; replaces the old DynamoDB table
#     }
#   }
#
# ---- HCP Terraform / Terraform Enterprise ----
#
#   terraform {
#     cloud {
#       organization = "my-org"
#       workspaces { name = "wazuh-lab" }
#     }
#   }
#
# =============================================================================

terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
