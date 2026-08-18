# Troubleshooting

Ordered by how early in the process the problem shows up.

---

## The VM boots but never appears on the network

**Look at the serial console first. Always.**

```bash
make console          # detach with Ctrl-]
```

This is the whole reason `modules/libvirt-vm` declares a `<serial>` device. Debian cloud
images already boot with `console=ttyS0,115200n8` on the kernel command line, so the
console shows you the complete boot — GRUB, kernel, systemd, cloud-init — including the
panic or the hang.

If the console shows nothing at all, the guest is not executing. Check the domain XML has
ACPI:

```bash
virsh -c qemu:///system dumpxml wazuh-server | grep -A4 '<features>'
```

You should see:

```xml
<features>
  <acpi/>
  <apic/>
  <vmport state='off'/>
</features>
```

**If `<features>` is missing, that is the bug.** A `q35` machine needs ACPI to enumerate
its PCIe bus; without it the guest kernel hangs before reaching userspace, with the vCPUs
spinning at 100%. libvirt does not add this element unless asked, and neither `terraform
validate` nor `terraform apply` will warn you.

Confirming a guest is hung rather than merely slow:

```bash
# Has the guest ever sent a packet?
virsh -c qemu:///system domifstat wazuh-server vnet0 | grep tx_packets
# tx_packets 0  ->  the guest never brought up its NIC

# Is it burning CPU?
virsh -c qemu:///system domstats wazuh-server --cpu-total | grep cpu.user
# a large and growing cpu.user with tx_packets 0  ->  spinning, not working
```

In this project a hang like that should fail the apply rather than reach you, because the
interface declares `wait_for_ip`. If Terraform reported success and the VM is unreachable,
check that guardrail is still in place.

---

## `terraform apply` fails on the domain

### `Invalid value for attribute 'migratable' in element 'cpu': 'yes'`

Provider 0.9.8 renders `cpu.migratable = true` as `migratable='yes'`, but libvirt's schema
requires `on|off`. Do not set the attribute — libvirt fills in `migratable='on'` by
itself. Already handled in the module; this note is for when you copy the `cpu` block
elsewhere.

### `Provider produced inconsistent result after apply: .devices.serials[0].source.pty.path: was "", but now "/dev/pts/4"`

The provider's schema marks `serials[].source.pty.path` as **required**, but a pty's path
is assigned by libvirt at runtime and then read back, so any value you supply is wrong by
the time apply finishes.

Omit `source` entirely:

```hcl
serials = [{
  target = { type = "isa-serial", port = 0, model = { name = "isa-serial" } }
}]
```

That is also the correct libvirt XML — `<source>` is output-only for a pty — and the
provider still emits `<serial type='pty'>`. libvirt mirrors it into a matching
`<console>`, which is what `virsh console` attaches to.

### `Provider produced inconsistent result after apply: .target.format.type: was "raw", but now "iso"`

On `libvirt_volume` for the cloud-init seed. libvirt probes the file it was given,
recognises ISO9660, and records the volume format as `iso` — so whatever you declared
is contradicted on the next read.

Omit `target` from that volume entirely and let libvirt classify it. The domain's cdrom
still declares `driver.type = "raw"`, which is correct and unrelated: that is the qemu
driver format, and qemu reads the ISO's bytes raw however libvirt catalogues the volume.

### The pattern behind all three

Every one of these is the same mistake: **declaring an attribute whose value libvirt
derives.** The provider writes your value into the XML, libvirt overwrites or normalises
it, the provider reads the real value back, and Terraform correctly complains that the
provider did not do what it said it would.

The rule that avoids the whole class: *if the hypervisor decides it, do not set it.*
Applies to pty paths, volume formats probed from content, `migratable`, and the
guest-agent channel's socket path — which is why `channels[].source.unix` is `{}` here
rather than carrying a path.

Recovering from one of these mid-apply: the resource is left **tainted**, not broken.
Fix the configuration and re-run — `terraform plan` will show it as
`is tainted, so must be replaced`, and everything already created is kept.

### `wait_for_ip` times out after 300 seconds

The guest booted but never got a DHCP lease. In order of likelihood:

1. The guest is hung. Go to the serial console.
2. The MAC in `vm_mac_address` does not match the DHCP reservation. Both come from the
   same variable, so this only happens if you edited the network by hand.
3. The network's dnsmasq is not running: `virsh net-info wazuh-lab`.
4. `network_cidr` collides with an existing network. Check `ip route`.

---

## Ansible cannot reach the host

```bash
make ip                            # what Terraform thinks
virsh -c qemu:///system domifaddr wazuh-server --source agent
```

If the guest agent answers, the VM is healthy and this is an SSH or inventory problem.
If it does not, the `qemu-guest-agent` package or the virtio channel is missing — both
are handled by the module, so check `virsh dumpxml | grep -A3 guest_agent`.

Host key mismatch after a rebuild is expected: a new VM on the same IP has a new host
key. `ansible.cfg` sets `host_key_checking = False` for exactly this reason. If you SSH
manually:

```bash
ssh-keygen -R "$(make -s ip)"
```

---

## `make bootstrap` fails with `Permission denied (publickey,password)`

The message misleads in a specific way: it lists the methods the **server** accepts, not
the one the client actually tried. A password that was never sent therefore looks exactly
like a password that was wrong.

Work through it in this order.

**1. Was `--ask-pass` passed at all?** Without it Ansible has neither a key nor a password
to offer. Note that make's `$(if ...)` tests emptiness rather than truth — hence the
`truthy` helper in the Makefile, so `ASK_PASS=0` means off while any other non-empty value
means on.

```bash
make bootstrap HOSTS=<host> BOOTSTRAP_USER=<user> ASK_PASS=1
```

**2. Is `PreferredAuthentications` pinned in `ansible.cfg`?** This one cost a real
debugging session. `ssh_args` is placed FIRST on the ssh command line, and ssh uses the
**first** value it obtains for any option — so a pin there beats everything Ansible
appends afterwards, including the password path. `--ask-pass` prompts, takes the
password, and ssh never offers it.

Ansible already does the right thing unaided, and conditionally: with no password it
appends `-o PasswordAuthentication=no` and a publickey-only
`-o PreferredAuthentications=...`; with a password it deliberately appends neither.

Check what is actually being built, against a dead endpoint so you add no failed attempts
on the real host:

```bash
printf '[probe]\nnowhere ansible_host=127.0.0.1 ansible_port=1\n' > /tmp/probe.ini
ansible -i /tmp/probe.ini nowhere -m ping -e ansible_password=x -vvv 2>&1 \
  | grep -oE 'PreferredAuthentications=[^ ]*|PasswordAuthentication=[^ ]*' | sort -u
```

With a password supplied that must print **nothing**. If it prints
`PreferredAuthentications=publickey`, that is your bug.

**3. Is `sshpass` installed?** `--ask-pass` requires it. Its absence produces a clear
error rather than this one, so rule it out fast: `command -v sshpass`.

**4. Only now suspect the credentials** — wrong password, an account that does not exist,
or one whose password is locked (`!` in `/etc/shadow`), which still leaves `password`
advertised by sshd.

**Stop guessing early.** Every blind retry is a failed auth attempt, and a VPS running
fail2ban will ban your address and lock you out of your own machine. Establish which
accounts accept your key in a single pass:

```bash
for u in root ubuntu debian admin youruser; do
  printf '%-10s ' "$u"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$u@<host>" 'echo OK' 2>&1 | tail -1
done
```

The durable fix is to stop using passwords entirely: run
`ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<host>` once, after which bootstrap needs no
`ASK_PASS`.

---

## Bringing the lab back after the KVM host reboots

The VMs do **not** autostart, so a host reboot (or a laptop that simply powers off) leaves
the manager and any local test VM shut off. Everything else — the Docker stack, the
overlay, the firewall rules — recovers on its own once the manager is up.

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
virsh list --all                       # expect: shut off
virsh start wazuh-server               # the hub first
virsh start lab-vm-01                # then any local spoke
```

Then wait and check, in this order. Each line answers a different question, and skipping
ahead makes a slow recovery look like a failure:

```bash
make exec CMD='sudo docker ps --format "{{.Names}}\t{{.Status}}"'   # restart:always brings these back
make exec CMD='df -h / | tail -1'                                   # confirm any disk growth survived
make exec CMD='systemctl is-active wazuh-docker-firewall'            # DOCKER-USER rules reapplied
make wg                                                              # peers + handshakes
make verify                                                          # cluster health, API, agents
```

Expect the indexer to report **`red` for the first minute or two** while shards recover.
That is normal after an unclean shutdown; it goes `green` on its own. Only investigate if
it is still red after a few minutes.

Remote agents come back without help: the manager dials the ones with an `Endpoint` and
`PersistentKeepalive`, and hosts that dial in re-handshake themselves. An agent typically
needs **90–120 seconds** to flip from `Disconnected` back to `Active`.

**If one remote agent stays Disconnected while the others recover,** the tunnel on that
host is down rather than the manager being at fault. `wg-quick@wg0` is `enabled`, so it
survives a reboot of the agent — but not a `systemctl stop` nobody undid:

```bash
ssh wazuh-ansible@<host> 'systemctl is-active wg-quick@wg0; sudo journalctl -u wg-quick@wg0 -n 20 --no-pager'
```

A `Stopping wg-quick@wg0.service` with no matching `Started` afterwards is the signature —
usually an interrupted tunnel test. Fix it with `sudo systemctl start wg-quick@wg0`, and
see the note in
[RUNBOOK-ENROL-PUBLIC-VPS.md](RUNBOOK-ENROL-PUBLIC-VPS.md#8-verify--four-checks-increasing-in-strength)
about arming the restore with a systemd timer *before* cutting a tunnel.

Finally, confirm nothing drifted while the host was off:

```bash
make tunnel && make configure          # both must report changed=0
```

---

## Growing the manager's disk / `Storage volumes cannot be updated`

The libvirt provider cannot change a volume's size, and it fails in the worst order: it
**plans** an in-place update and refuses at apply time.

```
Plan: 0 to add, 1 to change, 0 to destroy.
Error: Storage volumes cannot be updated. All changes require replacement.
```

Nothing is destroyed, but two things follow that are easy to misread:

1. **Do not "resolve" it by letting Terraform replace the volume.** Replacing the root
   volume destroys the VM and everything in it.
2. **The provider never re-reads capacity on refresh.** After growing the disk out of
   band, `virsh vol-info` reports the new size while Terraform's state keeps the old one
   and offers to "fix" it forever — a diff that can never be applied and that breaks
   every subsequent `terraform apply` for unrelated reasons. `modules/libvirt-vm` carries
   `lifecycle { ignore_changes = [capacity] }` for precisely this.

The working procedure, with the domain running:

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
VOL=$(virsh domblklist wazuh-server | awk '/vda/{print $2}')
virsh blockresize wazuh-server "$VOL" 40G
make exec CMD='sudo growpart /dev/vda 1 && sudo resize2fs /dev/vda1 && df -h /'
terraform -chdir=terraform plan            # must report: No changes.
```

`virsh vol-resize` is the wrong tool here: it shells out to `qemu-img`, which cannot take
a write lock on a disk a running QEMU already holds
(`Failed to get "write" lock`). `blockresize` goes through QEMU, which owns the file.

**What actually fills the disk** is worth knowing before you grow it. On a measured
deployment: `/var/ossec/queue/vd/feed` (the Vulnerability Detection CVE feed) was
**11 GiB**, container images ~4 GiB, and *all* Wazuh indices together ~16 MiB. An index
retention policy therefore reclaims almost nothing — the feed is downloaded in full
regardless of agent count or retention window.

Also note the guest does not warn you. On a single-node cluster
`cluster.routing.allocation.disk.watermark.enable_for_single_data_node` is `false`, so the
flood-stage read-only block never engages: the cluster stays `green` and the filesystem
simply fills.

---

## `wazuh.indexer` restarts forever

Almost always `vm.max_map_count`.

```bash
make logs SERVICE=wazuh.indexer
```

Look for:

```
max virtual memory areas vm.max_map_count [65530] is too low, increase to at least [262144]
```

OpenSearch memory-maps every Lucene segment and refuses to start below 262144. Debian's
default is 65530. Because the service is `restart: always`, the symptom is a container
perpetually *Restarting* rather than one that clearly failed.

```bash
make ssh
sudo sysctl vm.max_map_count      # expect 262144
```

`roles/common/tasks/sysctl.yml` sets this persistently. If it is wrong, that role did not
run: `make configure ANSIBLE_ARGS="--tags common"`.

The other cause is memory. An indexer killed by the OOM reaper looks similar:

```bash
make ssh
sudo dmesg -T | grep -i 'killed process'
free -h
```

If the JVM was OOM-killed, no amount of configuration fixes it. `make destroy`, raise
`vm_memory_mib` to 6144, free host memory, `make up`.

---

## Cluster health is `yellow`

That is correct and permanent for a single-node cluster. Replica shards cannot be
assigned when there is nowhere to put them, so the cluster never reaches `green`.
`make verify` accepts `yellow` for this reason. Nothing to fix.

---

## The dashboard loads but every Wazuh view is empty

This is nearly always the **API credential**, not the data path. Alerts are flowing into
the indexer fine; the dashboard's connection to the manager's API is what is broken.

```bash
make verify        # authenticates against the API explicitly
```

The Wazuh API enforces password complexity: 8-64 characters with at least one uppercase,
one lowercase, one digit and one symbol. A password that fails is rejected, and nothing in
the dashboard says so. `scripts/gen-vault.sh` constructs the API password to satisfy the
rule explicitly rather than generating one and hoping.

Check the manager's view of it:

```bash
make ssh
sudo docker logs wazuh.manager 2>&1 | grep -i 'api\|wazuh-wui'
```

---

## A YARA match never becomes an alert

The chain has five hops and any of them fails silently. Do not debug it with malware — use
the canary, which makes the round trip reproducible on demand:

```bash
# on the agent
printf 'WAZUH_YARA_CANARY_a7f3e1' | sudo tee /usr/bin/canary-test >/dev/null
```

Then walk the hops in order. **The first one that is empty is the fault**, and each has a
different cause:

```bash
# HOP 1 — did FIM see it? (on the manager)
make ssh
sudo docker exec wazuh.manager \
  grep -c '"id":"554"' /var/ossec/logs/alerts/alerts.json
```

Nothing here means FIM is not watching that path, or the agent is not reporting at all.
Check `make status` for the agent's state first — an agent showing `Disconnected` with its
processes running is a saturated queue, not a network problem, and the cause is usually
`realtime` on a large directory tree.

```bash
# HOP 2 — did the agent run the scan? (on the agent)
sudo tail -20 /var/ossec/logs/active-responses.log
sudo tail -20 /var/ossec/logs/yara-scan.log
```

Nothing in `active-responses.log` means the manager never dispatched the active response.
**This is a known and unresolved failure — see [YARA.md](YARA.md#known-limitations).** Use
the sweep instead, which does not depend on dispatch and is deterministic:

```bash
make yara-scan HOSTS=<host> PATHS="/usr/bin"
```

If the sweep also writes nothing, check the pieces directly on the agent:

```bash
sudo -u root yara --fail-on-warnings /var/ossec/yara/index.yar /dev/null && echo 'rules compile'
sudo cat /var/ossec/yara/PROVENANCE          # which rule set version is deployed
ls -l /var/ossec/logs/yara-scan.log          # must be root:wazuh 0660
```

A sweep reporting `0 files scanned` for a directory that plainly has files means the path is
a symlink — on merged-`/usr` distros `/lib`, `/bin` and `/sbin` all are, and `find` does not
follow symlinks. The script resolves them with `readlink -f`; if you passed `PATHS` by hand,
pass the resolved path.

```bash
# HOP 3 — is logcollector reading the log? (on the agent)
sudo grep -i 'yara-scan.log\|duplicated' /var/ossec/logs/ossec.log | tail
```

`Could not open file ... No such file or directory` means logcollector started **before**
the file existed and will not pick it up until restarted — the role handles this with a
handler, but a hand-created log file needs `sudo systemctl restart wazuh-agent`.
`Log file ... is duplicated` means the same path is declared in both the shared `agent.conf`
and the agent's local `ossec.conf`; Wazuh drops one of the two.

```bash
# HOP 4 — does the manager decode it? (on the manager)
make ssh
sudo docker exec -i wazuh.manager /var/ossec/bin/wazuh-logtest <<'EOF'
wazuh-yara: INFO - Scan result: WAZUH_Canary_ChainTest /usr/bin/canary-test
EOF
```

`wazuh-logtest` is the fastest tool here: it shows the decoder that matched, the fields it
extracted and the rule that fired, without waiting for a real event. If it shows
`wazuh-yara-scan-result` and rule `110002`, the manager side is correct and the problem is
upstream of it.

If the decoder does not match, validate the ruleset — a malformed one is withdrawn by the
deploy, so the manager may be running with the factory rules only:

```bash
sudo docker exec wazuh.manager /var/ossec/bin/wazuh-analysisd -t
sudo docker exec wazuh.manager ls -l /var/ossec/etc/rules/local_rules.xml
```

Remember that a change to `local_rules.xml` or `local_decoder.xml` needs a manager
**restart** to take effect — `analysisd` reads them once at startup — and that a change to
the mounted `wazuh_manager.conf` needs a **recreate**, not a restart, because the image's
entrypoint only copies `/wazuh-config-mount` when the container is created.

```bash
sudo rm /usr/bin/canary-test        # clean up
```

---

## Rotating credentials

**Editing the vault and re-running `make configure` does nothing.** This is the most
common Wazuh surprise and it is worth understanding rather than working around.

`internal_users.yml` is read exactly once, while the indexer initialises its security
index (`plugins.security.allow_default_init_securityindex: true`). After that the index is
authoritative and the file is inert.

Two further reasons a naive rotation fails:

- bcrypt salts every hash, so re-hashing the same password produces different output.
  `roles/wazuh_stack/tasks/passwords.yml` therefore only hashes when
  `internal_users.yml` does not exist, which is what keeps the role idempotent.
- The manager's filebeat and the dashboard hold the old password in their environment
  until their containers are recreated.

The correct sequence — all three steps — is:

```bash
make vault-edit          # change the password
make rotate-passwords    # re-hash, push with securityadmin.sh, recreate dependents
```

`securityadmin.sh` authenticates with the admin **certificate**, not a password, which is
why this still works when you have locked yourself out entirely.

---

## Recovering from a lost vault password

The vault password is not recoverable. The Wazuh deployment is:

```bash
rm ansible/inventory/group_vars/all/vault.yml
make vault-init            # new passwords, new vault password
make rotate-passwords      # push them into the running cluster
```

Your alert history survives — it lives in the indexer's data volume, not in the vault.

---

## A second `make configure` reports changes

It should report `changed=0`. If it does not, a role is rewriting something it should have
left alone. Find it:

```bash
cd ansible && ansible-playbook site.yml --ask-vault-pass --diff --check
```

Known-legitimate exception: none. Treat any repeated change as a bug.

---

## Reference: the diagnostic commands worth memorising

```bash
# Hypervisor
virsh -c qemu:///system list --all
virsh -c qemu:///system dumpxml wazuh-server
virsh -c qemu:///system domifaddr wazuh-server --source agent
virsh -c qemu:///system domifstat wazuh-server vnet0
virsh -c qemu:///system domstats wazuh-server --cpu-total
virsh -c qemu:///system net-dhcp-leases wazuh-lab
virsh -c qemu:///system console wazuh-server        # Ctrl-] to detach

# Guest
cloud-init status --long
sudo journalctl -u cloud-init --no-pager
sudo sysctl vm.max_map_count
free -h && swapon --show
sudo dmesg -T | grep -i 'killed process'

# Stack
sudo docker compose -p wazuh -f /opt/wazuh/compose.yaml ps
sudo docker compose -p wazuh -f /opt/wazuh/compose.yaml logs -f wazuh.indexer
# Read the password into a variable first: `make vault-show` prints it, and
# pasting it inline puts it in your shell history.
read -rsp 'indexer password: ' PW; echo
sudo docker exec wazuh.indexer curl -sk -u "admin:$PW" https://localhost:9200/_cluster/health
```
