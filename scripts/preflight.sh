#!/usr/bin/env bash
# =============================================================================
# preflight — fail before Terraform does, with an explanation
# =============================================================================
# Wazuh on 4 GiB is tight and this host is thin on both RAM and disk. Every
# check here exists because its absence produces a failure that is expensive to
# diagnose: an indexer killed by the OOM reaper mid-shard-recovery, or a qcow2
# that cannot grow because the backing filesystem filled.
#
# Exit codes:  0 = go   1 = blocked
# =============================================================================
set -euo pipefail

# --- tunables (overridable from the environment) ------------------------------
REQUIRED_MEM_MIB="${REQUIRED_MEM_MIB:-4096}"
REQUIRED_DISK_GIB="${REQUIRED_DISK_GIB:-12}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
STORAGE_POOL="${STORAGE_POOL:-vm-images}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519.pub}"

failures=0
warnings=0

if [[ -t 1 ]]; then
	RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
	RED=''; YEL=''; GRN=''; DIM=''; RST=''
fi

ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$1"; warnings=$((warnings + 1)); }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; failures=$((failures + 1)); }
hint() { printf '      %s%s%s\n' "$DIM" "$1" "$RST"; }

printf '\nPreflight checks\n────────────────\n'

# -----------------------------------------------------------------------------
# Tools
# -----------------------------------------------------------------------------
for tool in terraform virsh ansible-playbook ssh; do
	if command -v "$tool" >/dev/null 2>&1; then
		ok "$tool found"
	else
		bad "$tool is not on PATH"
	fi
done

# -----------------------------------------------------------------------------
# Libvirt access
# -----------------------------------------------------------------------------
if virsh -c "$LIBVIRT_URI" version >/dev/null 2>&1; then
	ok "libvirt reachable at $LIBVIRT_URI"
else
	bad "cannot connect to libvirt at $LIBVIRT_URI"
	hint "you must be in the 'libvirt' group: sudo usermod -aG libvirt \$USER"
	hint "group membership needs a fresh login to take effect"
fi

if virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" >/dev/null 2>&1; then
	pool_state=$(virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL" 2>/dev/null \
		| awk -F': *' '/^State/ {print $2}')
	if [[ "$pool_state" == "running" ]]; then
		ok "storage pool '$STORAGE_POOL' is active"
	else
		bad "storage pool '$STORAGE_POOL' exists but is $pool_state"
		hint "virsh -c $LIBVIRT_URI pool-start $STORAGE_POOL"
	fi
else
	bad "storage pool '$STORAGE_POOL' does not exist"
	hint "create it, or set storage_pool in terraform/terraform.tfvars"
fi

# -----------------------------------------------------------------------------
# Memory
# -----------------------------------------------------------------------------
# MemAvailable, not MemFree: the kernel's own estimate of what can be handed out
# without swapping, which is the number that actually predicts an OOM kill.
mem_avail_mib=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)
if (( mem_avail_mib >= REQUIRED_MEM_MIB )); then
	ok "memory available: ${mem_avail_mib} MiB (need ${REQUIRED_MEM_MIB} MiB)"
else
	bad "memory available: ${mem_avail_mib} MiB — need ${REQUIRED_MEM_MIB} MiB"
	hint "the VM will still boot, but the indexer's 1 GiB JVM heap will be"
	hint "paged out and Wazuh will be unusable or OOM-killed."
	hint ""
	hint "free memory, then re-check:"
	hint "  virsh -c $LIBVIRT_URI list          # any other VM running?"
	hint "  ps -eo rss=,comm= --sort=-rss | head"
fi

swap_used_mib=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{printf "%d", (t-f)/1024}' /proc/meminfo)
if (( swap_used_mib > 4096 )); then
	warn "${swap_used_mib} MiB of swap is already in use"
	hint "the host is under memory pressure before the VM even starts"
fi

# -----------------------------------------------------------------------------
# Disk
# -----------------------------------------------------------------------------
pool_path=$(virsh -c "$LIBVIRT_URI" pool-dumpxml "$STORAGE_POOL" 2>/dev/null \
	| sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -1 || true)

if [[ -n "$pool_path" && -d "$pool_path" ]]; then
	disk_avail_gib=$(df -BG --output=avail "$pool_path" | tail -1 | tr -dc '0-9')
	disk_pct=$(df --output=pcent "$pool_path" | tail -1 | tr -dc '0-9')

	if (( disk_avail_gib >= REQUIRED_DISK_GIB )); then
		ok "disk free at $pool_path: ${disk_avail_gib} GiB (${disk_pct}% used)"
	else
		bad "disk free at $pool_path: ${disk_avail_gib} GiB — need ${REQUIRED_DISK_GIB} GiB"
		hint "the root disk is thin-provisioned, so this fails at write time —"
		hint "typically while the indexer is committing a segment, which"
		hint "corrupts the shard rather than returning a clean error."
	fi

	if (( disk_pct >= 90 )); then
		warn "filesystem holding the pool is ${disk_pct}% full"
	fi
else
	warn "could not determine the storage pool's filesystem path"
fi

# -----------------------------------------------------------------------------
# SSH key
# -----------------------------------------------------------------------------
if [[ -r "$SSH_PUBLIC_KEY" ]]; then
	ok "SSH public key present: $SSH_PUBLIC_KEY"
else
	bad "SSH public key not readable: $SSH_PUBLIC_KEY"
	hint "ssh-keygen -t ed25519 -C \"\$USER@\$(hostname)\""
fi

# -----------------------------------------------------------------------------
# KVM
# -----------------------------------------------------------------------------
if [[ -w /dev/kvm ]]; then
	ok "/dev/kvm is writable (hardware acceleration available)"
elif [[ -e /dev/kvm ]]; then
	bad "/dev/kvm exists but is not writable by $USER"
	hint "sudo usermod -aG kvm \$USER, then log out and back in"
else
	bad "/dev/kvm is missing — virtualisation is disabled or unsupported"
	hint "enable VT-x/AMD-V in firmware; without it the VM runs under"
	hint "emulation and Wazuh will be unusably slow"
fi

# -----------------------------------------------------------------------------
# Verdict
# -----------------------------------------------------------------------------
printf '\n'
if (( failures > 0 )); then
	printf '%sBlocked: %d check(s) failed%s' "$RED" "$failures" "$RST"
	(( warnings > 0 )) && printf ', %d warning(s)' "$warnings"
	printf '.\n\n'
	printf 'Fix the above, or override a threshold if you know what you are\n'
	printf 'trading away, e.g.:\n\n'
	printf '    REQUIRED_MEM_MIB=3072 make preflight\n\n'
	exit 1
fi

printf '%sReady%s' "$GRN" "$RST"
(( warnings > 0 )) && printf ' (%d warning(s) — read them)' "$warnings"
printf '.\n\n'
