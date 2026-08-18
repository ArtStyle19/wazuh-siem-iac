# Wazuh SIEM lab — Terraform + Ansible on libvirt/KVM

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A5%201.12-7B42BC)](terraform/versions.tf)
[![Wazuh](https://img.shields.io/badge/Wazuh-4.14.7-005C8B)](https://wazuh.com)

A reproducible Wazuh 4.14.7 deployment (manager + indexer + dashboard) on a Debian 13
VM, built to be created and destroyed repeatedly on a laptop and then moved to a VPS
with one module swap. Remote hosts — a VPS on the internet — report in over a private
**WireGuard** overlay, with keys generated on each host and never transmitted.

**Terraform owns infrastructure. Ansible owns configuration.** That boundary is the
point of the project — it is what lets you change what Wazuh does without rebuilding
the VM, and what makes the cloud migration a change of one module rather than a
rewrite.

```
┌─ terraform ──────────────────────┐   ┌─ ansible ────────────────────────────────┐
│ libvirt_network  wazuh-lab       │   │ bootstrap   first contact: user + sudo   │
│   └─ DHCP reservation → .10      │   │ common      sysctl, swap, ufw, sshd      │
│ module libvirt-vm                │   │ wireguard   overlay for remote agents    │
│   ├─ base image (backing store)  │   │ docker      Docker CE + compose plugin   │
│   ├─ overlay disk (qcow2)        │   │ wazuh_stack certs, creds, stack, groups  │
│   ├─ cloud-init seed ISO         │   │ wazuh_agent enrol any host (apt/dnf)     │
│   └─ domain (the corrected XML)  │   │ yara        malware ID from file content │
└──────────────────────────────────┘   └──────────────────────────────────────────┘
                 │                                      ▲
                 └──────────────────────────────────────┘ inventory/hosts
                                                          (generated)

              ┌─── wg0: 10.88.0.0/24 ───┐
   VPS  10.88.0.2 ──│  WireGuard (hub/spoke)  │──▶ 10.88.0.1  wazuh.manager
   (agent)          └─────────────────────────┘
   only 51820/udp needs to be reachable — never 1514, 1515, 443 or 9200
```

---

## Quickstart

```bash
make deps           # Ansible collections
make vault-init     # generate strong random Wazuh passwords, encrypted
make preflight      # RAM / disk / libvirt / KVM checks — read the output
make up             # apply + configure  (~15 min, pulls ~3 GiB of images)
make agent-local    # enrol this workstation as the first agent
```

Then open the URL from `make status` and log in as `admin`. `make vault-show` prints
the password.

Tear it down and start over with `make destroy`.

### Adding a remote host (a VPS)

A VPS cannot reach the manager directly — it sits on a libvirt NAT network behind a
workstation behind a router, and Wazuh agents connect *outbound to the manager*. A
WireGuard overlay solves it, exposing exactly one UDP port:

```bash
# 1. No account, no auth key, no shared secret: WireGuard keypairs are
#    generated on each host by `wg genkey` and never leave it.
make bootstrap HOSTS=bootstrap_targets BOOTSTRAP_USER=<existing-user> ASK_PASS=1
make tunnel                         # builds the overlay on hub + all spokes

# 2. Describe your hosts
make vps-inventory                  # copies the example to ansible/inventory/vps
$EDITOR ansible/inventory/vps       # add the host under [wazuh_agents_tunnel]

# 3. Dry run first — this is a machine you care about
make agent-check HOSTS=wazuh_agents_tunnel
make agent       HOSTS=wazuh_agents_tunnel
```

`ansible/inventory/vps` is gitignored: real addresses do not belong in a public repo.
Full walkthrough in [docs/AGENTS.md](docs/AGENTS.md).

### Prerequisites

Required, and checked by `make preflight`:

- Terraform >= 1.12, libvirt/KVM, `ansible-core` >= 2.16
- membership of the `libvirt` and `kvm` groups (needs a fresh login to take effect)
- an SSH keypair at `~/.ssh/id_ed25519`
- **4 GiB of free RAM** and ~12 GiB of free disk

Optional, for `make lint`. Both are Go binaries that need a writable `/usr/local/bin`:

```bash
# tflint
curl -sSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash

# terraform-docs
curl -sSLo /tmp/tfdocs.tar.gz \
  https://terraform-docs.io/dl/v0.20.0/terraform-docs-v0.20.0-linux-amd64.tar.gz
tar -xzf /tmp/tfdocs.tar.gz -C /tmp && sudo install /tmp/terraform-docs /usr/local/bin/
```

`ansible-lint`, `yamllint` and `shellcheck` are what `make lint` calls, and it skips any
of them that is missing with a message rather than failing — so install them if you want
the full local run (`pip install ansible-lint yamllint`, plus your distribution's
ShellCheck). `make hooks` installs the pre-commit hooks, which manage their own copies of
the same tools plus `gitleaks`.

---

## Resource requirements, honestly

Wazuh's all-in-one deployment has a hard floor of **4 GiB RAM / 2 vCPU**, and it is a
floor rather than a comfortable figure:

| Component | Memory |
|---|---|
| `wazuh.indexer` | 1 GiB JVM heap (`-Xms1g -Xmx1g`) plus JVM overhead |
| `wazuh.dashboard` | ~1 GiB (Node.js / OpenSearch Dashboards) |
| `wazuh.manager` | ~0.5 GiB (analysisd, remoted, filebeat) |
| Debian + Docker | ~0.4 GiB |

`vm_memory_mib` is validated against that floor, so Terraform refuses a
misconfiguration rather than handing you an indexer that dies under load. The role
also creates a 2 GiB swapfile in the guest — insurance against an OOM kill, not a
substitute for RAM.

If `make preflight` says you are short on memory, you are. Close things, or raise
`vm_memory_mib` to 6144 on a machine with room and enjoy a much faster dashboard.

---

## What you get

| Endpoint | Port | Notes |
|---|---|---|
| Dashboard | 443 | Self-signed cert — expect a browser warning |
| Server API | 55000 | Used by the dashboard; `make verify` authenticates against it |
| Agent enrolment | 1515/tcp | Where new agents register |
| Agent comms | 1514/tcp | Where enrolled agents report |
| Syslog | 514/udp | For devices that cannot run an agent |
| Indexer | 9200 | **Not published.** See `wazuh_expose_indexer` |

The indexer's port stays on the Docker network because nothing outside the VM needs
to speak OpenSearch, and publishing it adds an endpoint whose only protection is a
password you then have to rotate.

---

## Detection content

A stock Wazuh install tells you *that* a file appeared. This one also tells you **what it
is**, because a real incident showed the difference: 910 FIM alerts saying "file added to
the system", and a human identifying the malware family by hand from strings.

The `yara` role plus seven custom rules close that gap.

| Rule | Level | Fires on |
|---|---|---|
| `110001` | 12 | A file on disk matches a malware signature — the alert names the family |
| `110004` | **13** | A **running process** matches a signature (scanned through `/proc/<pid>/exe`) |
| `110010` | 12 | 8+ new binaries in system paths within 120s — one alert instead of 910 |
| `110011` | 10 | Change under `/lib/*.so`, `/etc/init.d/`, `/etc/rc*.d/` — persistence paths |

Rules come from `elastic/protections-artifacts`, **pinned to a commit SHA** and fetched
once on the control node so every agent gets identical content. 248 Linux rule files, 902
rules. Your own rules go in `roles/yara/files/rules.local/` and are compile-checked at
deploy time.

Two switches, both off by default, because active response runs a scan **as root** on
every FIM event that gets past the guards:

```yaml
yara_enabled: true                  # per agent: install the scanner
wazuh_yara_active_response: true    # manager: allow it to request scans
```

```bash
make yara-scan HOSTS=web01          # sweep what is already on disk, and /proc
```

Measured on a real compromise: 23,049 files swept, one `yara --scan-list` pass in **3
seconds**, three implants found on disk plus one running from a deleted binary, **zero
false positives**.

**Active response dispatch is not yet reliable** — the deterministic path is the sweep.
That and the rest of the caveats are in [docs/YARA.md](docs/YARA.md#known-limitations),
written out rather than glossed over.

---

## Layout

```
terraform/
  main.tf                 network + module call + inventory generation
  variables.tf            typed, described, validated
  backend.tf              local state now, remote config written out for later
  modules/libvirt-vm/     reusable VM; the corrected domain XML lives here
ansible/
  site.yml                common → docker → wazuh_stack
  agent.yml               two plays: discover the manager, then enrol agents
  inventory/              a merged DIRECTORY, not a file
    hosts                 generated by Terraform      (gitignored)
    vps                   your real remote hosts      (gitignored)
    group_vars/
      all/                shared vars + the vault     (vault gitignored)
      wazuh_agents_lan.yml      manager = its libvirt address
      wazuh_agents_tunnel.yml   manager = its WireGuard address (10.88.0.1)
  examples/vps.example    committed template for the above
  roles/                  bootstrap, common, wireguard, docker, wazuh_stack,
                          wazuh_agent, yara
  yara-scan.yml           on-demand YARA sweep (make yara-scan)
docs/
  ARCHITECTURE.md         data flow, ports, trust boundaries
  AGENTS.md               enrolling agents, including a VPS over WireGuard
  YARA.md                 malware identification: the chain, the rules, the
                          limits — read the limitations section
  RUNBOOK-ENROL-PUBLIC-VPS.md
                          front-to-back runbook for one new server
  PRODUCTION-VPS.md       what the local rehearsal does and does not prove
  PORTING-TO-VPS.md       the migration checklist
  TROUBLESHOOTING.md      including the post-mortem below
  local/                  gitignored: runbooks that name real hosts
scripts/
  preflight.sh            fail early, with an explanation
  gen-vault.sh            generate and encrypt the credentials
```

The inventory files have **no extension**, and that is load-bearing:
`inventory_ignore_extensions` includes `.ini`, so a directory inventory silently skips
`hosts.ini` and hands you an empty host list with nothing pointing at the cause. See
[ansible/ansible.cfg](ansible/ansible.cfg).

### Secrets

Passwords live in `ansible/inventory/group_vars/all/vault.yml`, encrypted with
Ansible Vault, and **that file is gitignored.** Only `vault.yml.example` is
committed; every clone generates its own vault with `make vault-init`.

That is a deliberate choice for a *public* repository, and worth explaining because
the conventional advice points the other way. Ansible Vault is AES-256, so
committing the encrypted file is not reckless — in a private repo it is the better
option, since the secret travels with the code that consumes it and is recoverable
by anyone with the passphrase. In a public repo the same act publishes ciphertext
that anyone can download and attack offline, forever. Its only protection is a
passphrase, and "the passphrase is strong" is not a control you can audit, rotate,
or revoke.

The honest cost of this choice: **the vault is not shared between machines.** Clone
the repo somewhere else and you get a different vault, so you cannot manage one
deployment from two laptops. When that becomes a real constraint — or when CI needs
the secret — the answer is not to start committing the vault. It is **SOPS + age**
or a KMS: encryption whose key lives outside the repository, where it can be
rotated and revoked. `docs/PORTING-TO-VPS.md` covers that migration.

`group_vars/all/vars.yml` is the only file that references `vault_`-prefixed
variables, so `grep vault_ vars.yml` is a complete inventory of the project's
secrets. The rest of the code reads ordinary variable names.

Rotating a password after deployment needs more than editing the vault — see
[Rotating credentials](docs/TROUBLESHOOTING.md#rotating-credentials). Use
`make rotate-passwords`.

---

## Why this project exists: a post-mortem

This project exists because its predecessor did not work. That was a single `main.tf`
creating a Debian 13 VM. It applied cleanly and Terraform reported success. The VM was
`running`. It was also completely broken — hung during early boot, burning 100% of two
vCPUs, having never transmitted a single network packet:

```console
$ virsh domifstat terraform-debian-1 vnet1
vnet1 tx_packets 0          # never sent anything, ever
$ virsh domstats terraform-debian-1 --cpu-total
cpu.user=604981224000       # 605 seconds of guest CPU, spinning
```

Diffing the generated domain XML against a working VM built by virt-manager found the
cause immediately:

| Element | Working VM | The broken one |
|---|---|---|
| `<features>` | `<acpi/> <apic/>` | **absent entirely** |
| `<cpu>` | `host-passthrough` | `custom` / `qemu64` |
| `<serial>` | pty | **absent** |
| guest agent `<channel>` | present | **absent** |
| `<rng>` | virtio | **absent** |

**The bug: libvirt does not add `<features>` unless you ask.** A `q35` machine needs
ACPI to enumerate its PCIe bus; without it the guest kernel hangs before it reaches
userspace. Nothing about a Terraform configuration hints that this element is
mandatory, because in `virt-install` and virt-manager it is always added for you.

The reason it took a diff to find, rather than thirty seconds, is the second omission:
**no serial console.** Debian's cloud images boot with `console=ttyS0,115200n8`
already on the kernel command line, so a single `<serial>` device would have turned
`virsh console` into a complete boot log. Without it there was nothing to look at.

Three things in this project follow directly from that:

1. `modules/libvirt-vm` declares `features`, `cpu`, `serials`, `channels` and `rngs`
   explicitly, with comments explaining that they are load-bearing.
2. Every VM gets `wait_for_ip`, so a guest that never reaches the network **fails the
   apply** instead of being reported as healthy.
3. `make console` exists, and is the first thing the docs tell you to reach for.

Three provider bugs were found while building the fix, all of the same shape: **the
provider round-trips a value libvirt derives for itself.** Two were caught against a
throwaway probe domain, the third on the first real apply.

- `cpu.migratable = true` renders as `migratable='yes'` where libvirt's schema
  demands `on|off`, failing the apply. Omitting it is correct — libvirt fills in
  `migratable='on'` itself.
- `serials[].source.pty.path` is marked *required* by the provider schema, but libvirt
  assigns a pty at runtime. Setting it to `""` fails with *"Provider produced
  inconsistent result after apply: was "", but now "/dev/pts/4""*. Omitting `source`
  entirely is both correct libvirt XML and the only thing that re-plans clean.
- `target.format.type = "raw"` on the cloud-init ISO volume fails with *"was "raw",
  but now "iso""* — libvirt probes the file, recognises ISO9660 and records the format
  as `iso`. Omit `target` and let libvirt classify it.

The generalisable lesson, and the reason all three are annotated in the code: with this
provider, **do not declare an attribute whose value the hypervisor computes.** If
libvirt decides it, leave it unset; anything you write there is a value the next read
will contradict.

The details are in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## Common tasks

```bash
make status              # IP, URLs, what to do next
make console             # serial console — first stop when a VM will not boot
make ps                  # container states
make logs SERVICE=wazuh.indexer
make configure           # re-run configuration; should report changed=0 twice running
make verify              # re-run only the health checks
make agent HOSTS=web01   # enrol an inventory host
make yara-scan HOSTS=web01   # sweep a host for malware already on disk
make nuke                # wipe Wazuh data, keep the VM (prompts)
make destroy             # remove the VM and the network
```

`make` on its own lists everything.

---

## Continuous integration — and what it does not cover

`make lint` runs every static check that does not need GitHub, with the same arguments CI
uses so the two cannot drift apart. On every push and weekly on a schedule, CI runs:

| Job | Checks |
|---|---|
| terraform | `fmt -check`, `init -backend=false`, `validate`, `tflint` |
| ansible | `yamllint --strict`, `ansible-lint` at the **`production`** profile, `--syntax-check` on both playbooks |
| security | `gitleaks` over full history, `shellcheck`, and an assertion that no state file, vault or private key is tracked |

**CI cannot prove the deployment works.** GitHub's runners have no libvirt and no KVM,
so `terraform plan` and `apply` do not run there — plan needs a live hypervisor to
refresh against. Only `make up` on a machine with libvirt exercises the real path.

That limitation is stated because a green badge on a pipeline that silently skips the
interesting half is worse than no badge. What CI does prove is real, though: the code
is well-formed, internally consistent, idiomatic by two linters' strictest settings,
and free of committed secrets.

`init -backend=false` is deliberate — CI must never touch state.

---

## Known limitations

Written out because a reader deciding whether to use this deserves to know where it stops,
and because every one of these was found by running the thing rather than by reading it.

**1. YARA active response dispatch is unreliable.** The manager fires the scan on the agent
inconsistently: the canary chain has been observed working end to end, then the same test on
the same host produces the FIM alert with no scan at all. Nothing appears in the agent's
`active-responses.log`, so the script is not failing — it is not being launched. Confirming
which side drops it needs `execd.debug=2` on the manager and a correlated read of both logs;
that has not been done. **The deterministic path is `make yara-scan`**, which has been
verified repeatedly and produces the same alerts. Treat the sweep as the control and active
response as an accelerator.

**2. A compromised host cannot be reliably monitored from inside itself.** One agent in this
lab goes `Disconnected` 7–8 minutes after every restart with `Authentication error. Wrong key
or corrupt payload`. Clearing the `rids` counters on both sides did not fix it; clearing a
stale `remoted` session did not either. A second internet-facing agent with an identical
configuration, enrolled the same way over the same tunnel, is flawless. The difference is not
configuration — that host is still rooted, and its persistence survived a reboot and added
two further generations. The answer to it is a rebuild, not more monitoring. An agent's
reports are worth what the host's integrity is worth.

**3. Rules are not tuned against a package upgrade.** Rule `110010` (8+ new binaries in
system paths within 120s) will fire during a large `apt upgrade`. The thresholds come from
the shape of one real incident, not from a measured baseline. Watch a full upgrade cycle
before treating it as high-confidence.

**4. No index retention policy.** Wazuh's indices grow without bound. This is deferred rather
than overlooked: at this lab's volume the alert indices are ~16 MiB, while the CVE feed alone
is ~11 GiB, so an ISM policy would tidy the small number and leave the large one. On a real
estate it becomes the first thing to configure, and the disk fills before anything warns you.

**5. Single node, local state.** Manager, indexer and dashboard share one VM, and Terraform
state is a local file. Both are appropriate for a lab and neither survives contact with a
team — see [docs/PORTING-TO-VPS.md](docs/PORTING-TO-VPS.md) for the remote backend and
[docs/PRODUCTION-VPS.md](docs/PRODUCTION-VPS.md) for what the local rehearsal does and does
not prove.

**6. Growing a disk is not a Terraform operation.** The libvirt provider plans a volume
resize in place and then refuses it at apply, and it never re-reads `capacity` on refresh —
so a grown disk shows as a permanent diff. The working procedure is an out-of-band
`virsh blockresize` plus `lifecycle { ignore_changes = [capacity] }`, documented in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). Shrinking is not possible at all.

**7. Active response is a privileged execution path.** `<active-response>` lets the manager
run a script **as root on any agent**, so a compromised manager has root execution across the
estate. `yara.sh` is written to do as little as possible with that — read a file, run yara,
never delete or kill or open a socket — but the capability is the exposure, not the script.
This is a trust boundary to accept knowingly, not a bug to fix.

---

## Licence and credits

MIT (see [LICENSE](LICENSE)), **except** the files listed in [NOTICE](NOTICE), which
derive from [wazuh/wazuh-docker](https://github.com/wazuh/wazuh-docker) `single-node`
v4.14.7 and remain **GPL-2.0**. That mainly means `wazuh_manager.conf.j2` (near-verbatim
upstream, with the cluster key moved into the vault) and `compose.yaml.j2`.

The split is spelled out rather than glossed over: a repository labelled MIT that
contains GPL-derived files misleads anyone who reuses it. Each template's header
documents how it differs from upstream.

Wazuh is a trademark of Wazuh, Inc. This project is not affiliated with or endorsed by
Wazuh, Inc.
