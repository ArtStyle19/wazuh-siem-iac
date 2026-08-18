# =============================================================================
# Wazuh SIEM lab
# =============================================================================
# `make` for the target list. The paths worth knowing:
#
#   make preflight && make up      build everything from nothing
#   make destroy                   tear the VM down (keeps nothing)
#   make configure                 re-run configuration without rebuilding
#
# =============================================================================

SHELL := /bin/bash
# -e: stop on first failure. -u: an unset variable is a bug, not an empty string.
# pipefail: a failure mid-pipe fails the recipe instead of being swallowed.
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TF_DIR     := terraform
ANS_DIR    := ansible
TF         := terraform -chdir=$(TF_DIR)
VAULT_FILE := $(ANS_DIR)/inventory/group_vars/all/vault.yml
INVENTORY  := $(ANS_DIR)/inventory/hosts

# Set VAULT_PASS_FILE=path to skip the interactive prompt (and to run in CI).
#
# $(abspath ...) is required, not cosmetic: every ansible recipe does `cd $(ANS_DIR)`
# first, so a relative path like `.vault-pass` would be looked for in ansible/ and
# fail with "vault password file was not found" — pointing at a file that plainly
# exists in the directory you ran make from.
VAULT_ARGS := $(if $(VAULT_PASS_FILE),--vault-password-file $(abspath $(VAULT_PASS_FILE)),--ask-vault-pass)

# Extra flags passed straight through, e.g. make configure ANSIBLE_ARGS="--tags wazuh"
ANSIBLE_ARGS ?=
TF_ARGS      ?=

# make's $(if) tests for EMPTINESS, not truth — so `ASK_PASS=0` is true and would enable
# the very flag the operator was trying to turn off. Anyone who has used a shell expects
# =0 to mean off, so the values that plainly mean "no" are stripped before the test.
# Reach for this in every on/off flag rather than $(if $(FLAG),...) directly.
truthy = $(filter-out 0 false no off FALSE NO OFF,$1)

.PHONY: help preflight deps init fmt fmt-check validate lint plan apply up \
        configure verify destroy nuke clean console ssh ip logs ps status \
        vault-init vault-edit vault-show credentials rotate-passwords agent agent-local \
        agent-check vps-inventory bootstrap tunnel wg docs hooks

# -----------------------------------------------------------------------------
help: ## Show this help
	@printf '\nWazuh SIEM lab\n'
	@printf '══════════════\n\n'
	@awk 'BEGIN {FS = ":.*?## "} \
		/^# ---- / {printf "\n\033[1m%s\033[0m\n", substr($$0, 8)} \
		/^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' \
		$(MAKEFILE_LIST)
	@printf '\n'

# ---- Setup
deps: ## Install the required Ansible collections
	ansible-galaxy collection install -r $(ANS_DIR)/requirements.yml

preflight: ## Check RAM, disk, libvirt and keys before building anything
	@bash scripts/preflight.sh

vault-init: ## Create the encrypted vault with strong random passwords
	@bash scripts/gen-vault.sh $(VAULT_FILE) $(if $(VAULT_PASS_FILE),--vault-password-file $(VAULT_PASS_FILE),)

vault-edit: ## Edit the encrypted vault
	ansible-vault edit $(VAULT_ARGS) $(VAULT_FILE)

vault-show: ## Print the vault's contents (all four values, unlabelled)
	@ansible-vault view $(VAULT_ARGS) $(VAULT_FILE)

# `make vault-show` prints four secrets and says nothing about which one you type
# into the login form. Three of them are service accounts that no human ever uses,
# and one of those is called "dashboard_password" — which is the natural wrong
# answer to "what is my dashboard password". This target removes the ambiguity.
credentials: ## Show WHICH credential to use where (this is your dashboard login)
	@IP="$$($(TF) output -raw vm_ip 2>/dev/null)"; \
	 PW="$$(ansible-vault view $(VAULT_ARGS) $(VAULT_FILE) 2>/dev/null \
	        | sed -n 's/^vault_wazuh_indexer_password: *"\?\([^"]*\)"\?$$/\1/p')"; \
	 printf '\n\033[1mDashboard login\033[0m\n'; \
	 printf '  URL        https://%s\n' "$$IP"; \
	 printf '  username   \033[1madmin\033[0m\n'; \
	 printf '  password   \033[1m%s\033[0m\n' "$$PW"; \
	 printf '             \033[2m(this is vault_wazuh_indexer_password)\033[0m\n'; \
	 printf '\n\033[2mThe other vault values are internal service accounts, NOT logins:\033[0m\n'; \
	 printf '\033[2m  vault_wazuh_dashboard_password   kibanaserver — dashboard -> indexer\033[0m\n'; \
	 printf '\033[2m  vault_wazuh_api_password        wazuh-wui    — dashboard -> manager API\033[0m\n'; \
	 printf '\n'

hooks: ## Install the pre-commit hooks
	pre-commit install
	pre-commit install --hook-type commit-msg

# ---- Terraform
init: ## Initialise Terraform
	$(TF) init -input=false

fmt: ## Format the Terraform files
	$(TF) fmt -recursive

fmt-check: ## Fail if any Terraform file is unformatted
	$(TF) fmt -recursive -check -diff

validate: ## Validate the Terraform configuration
	$(TF) validate

lint: fmt-check validate ## Run every static check
	@if command -v tflint >/dev/null 2>&1; then \
		tflint --chdir=$(TF_DIR) --recursive; \
	else \
		printf 'tflint not installed — skipping (see README prerequisites)\n'; \
	fi
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint -c .yamllint.yaml --strict $(ANS_DIR)/ .pre-commit-config.yaml .github/; \
	else \
		printf 'yamllint not installed — skipping (pip install yamllint)\n'; \
	fi
	@if command -v ansible-lint >/dev/null 2>&1; then \
		cd $(ANS_DIR) && ansible-lint; \
	else \
		printf 'ansible-lint not installed — skipping (pip install ansible-lint)\n'; \
	fi
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh; \
	else \
		printf 'shellcheck not installed — skipping (dnf install ShellCheck)\n'; \
	fi

plan: ## Show what Terraform would change
	$(TF) plan -input=false $(TF_ARGS)

apply: ## Create the VM and the lab network
	$(TF) apply -input=false -auto-approve $(TF_ARGS)

# ---- Deploy
configure: $(INVENTORY) ## Install and configure Wazuh with Ansible
	cd $(ANS_DIR) && ansible-playbook site.yml $(VAULT_ARGS) $(ANSIBLE_ARGS)

up: apply configure ## Create the VM, then deploy Wazuh onto it
	@$(MAKE) --no-print-directory status

verify: $(INVENTORY) ## Re-run only the verification checks
	cd $(ANS_DIR) && ansible-playbook site.yml $(VAULT_ARGS) --tags verify $(ANSIBLE_ARGS)

rotate-passwords: $(INVENTORY) ## Re-hash the vault passwords and push them to the live cluster
	@printf 'Rotating credentials. This re-hashes from the vault and runs\n'
	@printf 'securityadmin.sh against the running indexer.\n\n'
	cd $(ANS_DIR) && ansible-playbook site.yml $(VAULT_ARGS) \
		--tags passwords,rotate,deploy \
		-e wazuh_force_password_rotation=true $(ANSIBLE_ARGS)

# ---- Remote hosts
#
# The tail of the "Prompts:" line, as a make variable rather than inline in the recipe.
#
# It contains NO apostrophe, deliberately. It is interpolated into a shell word, and the
# usual `'"'"'` idiom for embedding a literal quote only works inside a SINGLE-quoted
# string — dropped into a double-quoted one it closes the quote early and leaves the line
# unterminated, which make reports as `unexpected EOF while looking for matching "`.
# That is a shell parse error, so it fires before any recipe line runs and the target
# looks broken for no visible reason.
#
# It also only appears on the branch where NO_BECOME_PASS is unset, so every run that
# passes the flag works and the bug hides. Phrasing it "the sudo password of X" instead
# of "X's sudo password" removes the hazard rather than escaping around it.
bootstrap_extra_prompt = $(if $(call truthy,$(NO_BECOME_PASS)),, and then the sudo password of $(if $(BOOTSTRAP_USER),$(BOOTSTRAP_USER),the connecting user))

# Stated BEFORE the run, not diagnosed after it. Without --ask-pass, Ansible has neither
# a key nor a password to offer, and sshd's rejection is the generic
# `Permission denied (publickey,password)` — which names the two methods the SERVER
# accepts and says nothing about the one the client was missing. That reads like the key
# is wrong rather than absent, and the fix is a flag, so it belongs in the banner.
#
# Empty when ASK_PASS is set, and printed with `printf '%b'` so an empty value prints
# nothing at all rather than a stray blank line.
bootstrap_key_hint = $(if $(call truthy,$(ASK_PASS)),,\nNo --ask-pass, so this assumes your SSH key is already installed for $(if $(BOOTSTRAP_USER),$(BOOTSTRAP_USER),the connecting user).\nIf it is not, the run fails as UNREACHABLE with "Permission denied (publickey,password)".\nRe-run with ASK_PASS=1 to be prompted for the password of that account instead.\n)

# NO_BECOME_PASS=1 suppresses --ask-become-pass. Use it when the account named by
# BOOTSTRAP_USER already has passwordless sudo — re-bootstrapping a host, or renaming
# the automation account by connecting through the old one. Without the flag Ansible
# prompts for a sudo password that does not exist, and an empty answer is not the same
# as not asking: `become_pass` is then set to "" and sudo fails.
bootstrap: $(INVENTORY) ## Create the wazuh-ansible automation account on a new host (HOSTS=pattern BOOTSTRAP_USER=existing-user [NO_BECOME_PASS=1])
	@test -n "$(HOSTS)" || { \
		printf 'Usage: make bootstrap HOSTS=<pattern> BOOTSTRAP_USER=<existing-user>\n\n'; \
		printf 'Run ONCE per host that Terraform did not create. Creates the\n'; \
		printf '`wazuh-ansible` automation account with key auth and passwordless sudo,\n'; \
		printf 'so every later playbook can run unattended. Your own account is untouched.\n\n'; \
		printf 'Prompts for the sudo password of BOOTSTRAP_USER.\n'; \
		printf '  ASK_PASS=1        that user has no SSH key installed yet\n'; \
		printf '  NO_BECOME_PASS=1  that user already has passwordless sudo\n'; \
		exit 1; }
	@printf 'Prompts: the vault password%s.\n' '$(bootstrap_extra_prompt)'
	@printf '(The vault holds nothing this playbook needs, but Ansible decrypts\n'
	@printf ' group_vars/all for any host in scope, so it asks regardless.)\n'
	@printf '%b' '$(bootstrap_key_hint)'
	@printf '\n'
	cd $(ANS_DIR) && ansible-playbook bootstrap.yml $(VAULT_ARGS) \
		-e target_hosts=$(HOSTS) \
		$(if $(BOOTSTRAP_USER),-e bootstrap_initial_user=$(BOOTSTRAP_USER),) \
		$(if $(call truthy,$(ASK_PASS)),--ask-pass,) \
		$(if $(call truthy,$(NO_BECOME_PASS)),,--ask-become-pass) $(ANSIBLE_ARGS)

tunnel: $(INVENTORY) ## Build or refresh the WireGuard overlay (hub + all spokes)
	cd $(ANS_DIR) && ansible-playbook agent.yml $(VAULT_ARGS) \
		--tags wireguard $(ANSIBLE_ARGS)

# ---- Agents
agent: $(INVENTORY) ## Enrol inventory hosts as agents (HOSTS=pattern)
	@test -n "$(HOSTS)" || { \
		printf 'Usage: make agent HOSTS=<inventory-pattern>\n\n'; \
		printf 'Groups:\n'; \
		printf '  wazuh_agents_tunnel    hosts with no route here, via WireGuard\n'; \
		printf '  wazuh_agents_lan       hosts on the hypervisor network\n'; \
		printf '  wazuh_agents           both\n\n'; \
		printf 'Define them in ansible/inventory/vps  (make vps-inventory)\n'; \
		exit 1; }
	cd $(ANS_DIR) && ansible-playbook agent.yml $(VAULT_ARGS) \
		-e target_hosts=$(HOSTS) $(ANSIBLE_ARGS)

# What a dry run can and cannot tell you here.
#
# On an ALREADY-ENROLLED host it is a genuine preview: every file diff and service
# change is reported accurately.
#
# On a host that has never been enrolled it validates the overlay, the manager address
# and the repository setup, then stops at the first task that needs an artefact the dry
# run only simulated — typically
#   file (/usr/share/keyrings/wazuh.gpg) is absent, cannot continue
# because the keyring download was not really performed. Patching around that would just
# move the failure to `apt`, which cannot resolve wazuh-agent from a repository that was
# also only simulated. No amount of role hygiene fixes it: a package install from a repo
# that does not exist yet is not previewable.
#
# So treat a failure at or after the keyring as "the dry run ran out of road", not as a
# fault in the host. Everything before it was checked for real.
agent-check: $(INVENTORY) ## Dry-run agent enrolment (HOSTS=pattern) — do this first on a real VPS
	@test -n "$(HOSTS)" || { printf 'Usage: make agent-check HOSTS=<inventory-pattern>\n'; exit 1; }
	cd $(ANS_DIR) && ansible-playbook agent.yml $(VAULT_ARGS) \
		-e target_hosts=$(HOSTS) --check --diff $(ANSIBLE_ARGS)

# The sweep finds what the active response CANNOT see: files that were already on disk when
# the agent was installed. On a host compromised before Wazuh went in, the malware sits in
# FIM's baseline and no alert mentions it — this sweep is the only thing that surfaces it.
#
# Findings do NOT come back through Ansible's output: they are written to the agent's
# yara-scan.log and reach the dashboard as rule 110001 alerts (level 12), reusing the decoder
# already on the manager.
#
# PATHS goes in JSON form, not `-e key=value`: Ansible splits extra-vars on spaces, so
# `-e 'paths=/lib /usr/lib'` defines paths=/lib and then tries to read /usr/lib as another
# key=value pair. With JSON the whole space-containing value arrives intact.
yara-scan: $(INVENTORY) ## On-demand YARA sweep (HOSTS=pattern [PATHS="/lib /usr/bin"])
	@test -n "$(HOSTS)" || { \
		printf 'Usage: make yara-scan HOSTS=<pattern> [PATHS="/lib /usr/bin"]\n\n'; \
		printf 'Without PATHS it sweeps the paths in yara_scan_paths.\n'; \
		printf 'Requires yara_enabled=true in the inventory for that host.\n'; \
		exit 1; }
	cd $(ANS_DIR) && ansible-playbook yara-scan.yml $(VAULT_ARGS) \
		-e target_hosts=$(HOSTS) \
		$(if $(PATHS),-e '{"yara_scan_target_paths":"$(PATHS)"}',) $(ANSIBLE_ARGS)

vps-inventory: ## Create ansible/inventory/vps from the example
	@test ! -e $(ANS_DIR)/inventory/vps || { \
		printf '%s already exists — edit it directly.\n' "$(ANS_DIR)/inventory/vps"; exit 1; }
	cp $(ANS_DIR)/examples/vps.example $(ANS_DIR)/inventory/vps
	@printf 'Created %s (gitignored). Add your hosts, then:\n' "$(ANS_DIR)/inventory/vps"
	@printf '  make bootstrap HOSTS=bootstrap_targets BOOTSTRAP_USER=<existing-user>\n'
	@printf '  make tunnel\n'
	@printf '  make agent-check HOSTS=wazuh_agents_tunnel\n'

# Three details in agent-local are load-bearing, all learned the hard way. They are
# documented here rather than inside the recipe, because a tab-indented `#` line is
# handed to the shell and make echoes it — turning explanation into terminal noise.
#
#   1. The manager's address is resolved with $(TF) BEFORE the `cd`, in a single
#      shell statement. A nested `$(MAKE) ip` would run after the cd — inside
#      ansible/, where there is no Makefile — failing with "No rule to make target
#      'ip'" while still passing an empty address to Ansible.
#
#   2. TWO -i flags. Ansible merges inventory sources, so this keeps the real
#      inventory (hence the wazuh_servers group and its hostvars) while adding
#      localhost. A bare `-i localhost,` REPLACES the inventory, which empties
#      wazuh_servers and makes the manager-discovery play skip with "no hosts
#      matched".
#
#   3. The system interpreter, not pyenv's: the dnf module needs libdnf's Python
#      bindings, which exist only in /usr/bin/python3.
agent-local: $(INVENTORY) ## Enrol this workstation as the first agent
	@printf 'Installing the Wazuh agent on this machine. Needs your sudo password.\n\n'
	@MANAGER_IP="$$($(TF) output -raw vm_ip)"; \
	 test -n "$$MANAGER_IP" || { printf 'Could not read vm_ip from Terraform.\n'; exit 1; }; \
	 printf 'Manager: %s\n\n' "$$MANAGER_IP"; \
	 cd $(ANS_DIR) && ansible-playbook agent.yml $(VAULT_ARGS) \
		-i inventory/ -i localhost, \
		-e target_hosts=localhost \
		-e ansible_connection=local \
		-e ansible_python_interpreter=/usr/bin/python3 \
		-e wazuh_manager_address="$$MANAGER_IP" \
		--ask-become-pass $(ANSIBLE_ARGS)

# ---- Inspect
status: ## Show the connection details and next steps
	@$(TF) output -raw next_steps 2>/dev/null || \
		printf 'No state yet. Run: make preflight && make up\n'

ip: ## Print the VM's IP address
	@$(TF) output -raw vm_ip

wg: ## Show the WireGuard overlay state on the manager
	@$$($(TF) output -raw ssh_command) \
		'command -v wg >/dev/null 2>&1 \
		 && { sudo wg show; echo; echo "--- handshakes (0 = never) ---"; sudo wg show wg0 latest-handshakes 2>/dev/null; } \
		 || echo "wireguard is not installed on the manager yet — run: make tunnel"'

ssh: ## SSH into the VM (interactive; use `make exec CMD=...` to run one command)
	@$$($(TF) output -raw ssh_command)

# `make ssh` opens an INTERACTIVE session and ignores anything after the target name:
# `make ssh -- 'df -h'` connects, runs nothing, and then make tries to build a target
# called `df -h`. It looks like it worked, because you see the login banner. This target
# is the one that actually runs a command and returns.
#
# CMD is wrapped in single quotes so the REMOTE shell interprets pipes and redirection.
# Unquoted, `make exec CMD='df -h | tail -1'` would pipe on the control node instead,
# which silently gives the right answer for some commands and the wrong one for others.
# Consequence of that choice: use double quotes INSIDE CMD, not single.
#
# AND: write command substitution as `$$(...)`, never `$(...)`. A recipe line is expanded
# by make before the shell ever sees it, and CMD is recursively expanded, so a bare
# `$(sudo wg show wg0 public-key)` is read as a MAKE variable of that name — undefined, so
# it becomes the empty string. The command still runs and still succeeds; it just silently
# loses that argument:
#
#   make exec CMD='echo "[$(sudo wg show wg0 public-key)]"'    ->  []       WRONG
#   make exec CMD='echo "[$$(sudo wg show wg0 public-key)]"'   ->  [3N+...] right
#
# The first form is dangerous precisely because it looks like a real answer: an empty
# WireGuard public key reads as "this interface has no key", which is a genuine and
# serious failure mode. Diagnose with a plain ssh command if in any doubt.
#
# The empty-CMD guard is a make `$(if ...)` rather than a shell `test -n "$(CMD)"`,
# because the shell form re-expands CMD inside its own quotes: a CMD containing double
# quotes then breaks the test itself with "binary operator expected" — the guard failing
# on exactly the input it was meant to pass through.
exec: ## Run one command on the manager and return (CMD='...')
	@$(if $(strip $(CMD)),:,printf 'Usage: make exec CMD=<command>\n\nRuns one command on the manager over SSH and returns.\nUse double quotes inside CMD, not single.\n' >&2; exit 1)
	@$$($(TF) output -raw ssh_command) '$(CMD)'

console: ## Attach to the VM's serial console (detach with Ctrl-])
	@printf 'Attaching to the serial console. Detach with Ctrl-]\n'
	@printf 'This is the first place to look when the VM boots but never\n'
	@printf 'appears on the network.\n\n'
	@$$($(TF) output -raw console_command)

ps: ## Show the Wazuh container states
	@$$($(TF) output -raw ssh_command) \
		'sudo docker compose -p wazuh -f /opt/wazuh/compose.yaml ps'

logs: ## Tail the Wazuh container logs (SERVICE=wazuh.indexer to narrow)
	@$$($(TF) output -raw ssh_command) \
		"sudo docker compose -p wazuh -f /opt/wazuh/compose.yaml logs --tail=200 -f $(SERVICE)"

# ---- Teardown
destroy: ## Destroy the VM and the lab network
	$(TF) destroy -input=false -auto-approve $(TF_ARGS)
	@rm -f $(INVENTORY)

nuke: ## Delete the Wazuh data volumes, keeping the VM (DESTRUCTIVE)
	@printf 'This deletes every Wazuh volume: all alerts, agent registrations\n'
	@printf 'and indexer data. The VM itself stays.\n\n'
	@read -r -p 'Type "yes" to continue: ' reply; \
		test "$$reply" = "yes" || { printf 'Aborted.\n'; exit 1; }
	@$$($(TF) output -raw ssh_command) \
		'sudo docker compose -p wazuh -f /opt/wazuh/compose.yaml down --volumes'

clean: ## Remove local generated files (keeps state and the vault)
	rm -f $(INVENTORY)
	rm -rf $(TF_DIR)/.terraform/modules
	@printf 'Removed the generated inventory and cached modules.\n'
	@printf 'State and the vault are untouched — use `make destroy` for infrastructure.\n'

# -----------------------------------------------------------------------------
# The generated inventory is a real build artifact: every deploy target depends
# on it, and it only exists after a successful apply. Declaring the dependency
# means `make configure` on a fresh clone tells you what to do instead of
# failing inside Ansible with an empty host list.
$(INVENTORY):
	@printf 'No inventory at $(INVENTORY).\n\n'
	@printf 'Terraform generates it during apply. Run:\n\n'
	@printf '    make preflight && make apply\n\n'
	@exit 1
