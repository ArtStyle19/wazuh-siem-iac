# =============================================================================
# tflint
# =============================================================================
# Install the plugin before first use:  tflint --init
#
# tflint catches what `terraform validate` does not: unused declarations, missing
# descriptions, naming that drifts from convention, and deprecated syntax.
# validate only answers "is this parseable and type-correct".
# =============================================================================

plugin "terraform" {
  enabled = true
  # The recommended preset includes the documented-variables and naming-
  # convention rules, which is most of the value.
  preset = "recommended"
}

config {
  # Lint called modules too, not just the root. `module = true` is the pre-0.54
  # spelling of this setting if you are on an older tflint.
  call_module_type = "all"
}

# Enforced explicitly rather than relying on the preset, because these two are
# the rules that keep a module reusable by someone who did not write it.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Off deliberately. The convention it wants — one file per concern — is exactly
# what this project does (versions.tf, providers.tf, variables.tf, outputs.tf,
# locals.tf, main.tf), but the rule also insists a module have no other files,
# which would flag backend.tf.
rule "terraform_standard_module_structure" {
  enabled = false
}
