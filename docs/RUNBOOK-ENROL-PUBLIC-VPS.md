# Runbook — enrolling a public VPS as a Wazuh agent

A complete, ordered procedure for putting a Wazuh agent on an internet-reachable Linux
server and connecting it to the manager over the WireGuard overlay.

This is the **publicly reachable** case: the server has a real routable IP and can accept
inbound UDP. That is the easy topology, because the manager (behind NAT) dials *out* to
it. If your target cannot accept inbound UDP, stop and read
[PRODUCTION-VPS.md](PRODUCTION-VPS.md#which-direction-dials) instead — the procedure is
different and may not be possible at all.

Nothing here requires a reboot of the target server.

---

## 0. Set your variables once

Every command below uses these. Set them in the shell you will work in, so the rest of the
runbook is copy-pasteable and no real address ends up in a committed file.

```bash
export VPS_IP=203.0.113.10          # the server's public address
export VPS_PORT=22                  # SSH port, if not 22
export VPS_USER=root                # the account you can log in as TODAY
export WG_ADDR=10.88.0.5            # its address on the overlay — must be unused
export INV_NAME=myvps               # the name it will have in the inventory
```

Pick `WG_ADDR` by checking what is already taken:

```bash
grep -o 'wireguard_address=[0-9.]*' ansible/inventory/vps
grep wireguard_address ansible/inventory/group_vars/wazuh_servers.yml
```

---

## 1. Preconditions on the manager — check these first

Enrolling an agent adds load and alert volume to the manager. Two things have bitten this
project, both cheap to check and expensive to discover afterwards.

### 1a. Manager disk

```bash
make exec CMD='df -h /'
```

**If free space is under ~3 GiB, fix that before enrolling anything.** The single-node
indexer does *not* protect itself: `enable_for_single_data_node` is `false`, so the
flood-stage read-only watermark never engages, the cluster stays `green`, and the
filesystem simply fills. What you get is not a clear error but a manager that misbehaves
in unrelated-looking ways.

Note that index retention will *not* help much: on a measured deployment all Wazuh indices
totalled ~16 MiB while the Vulnerability Detection CVE feed
(`/var/ossec/queue/vd/feed`) was ~11 GiB. Growing the disk is the fix:

**Do NOT try to grow it with `terraform apply`.** The libvirt provider plans an in-place
update and then refuses during apply — it tells you the opposite of the truth right up
until it fails:

```
Plan: 0 to add, 1 to change, 0 to destroy.
Error: Storage volumes cannot be updated. All changes require replacement.
```

Nothing is destroyed (the apply errors out), but it does not work. `capacity` is a
create-time value, and the module carries `lifecycle { ignore_changes = [capacity] }` so
this diff does not poison every later apply. Grow it with the domain running instead:

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
VOL=$(virsh domblklist wazuh-server | awk '/vda/{print $2}')

# blockresize, NOT vol-resize. `virsh vol-resize` shells out to qemu-img, which cannot
# take a write lock on a disk a running QEMU already holds:
#   Failed to get "write" lock ... Is another process using the image?
# blockresize goes through QEMU itself, which owns the file, so it works live.
virsh blockresize wazuh-server "$VOL" 40G

# the guest sees the bigger device immediately; the partition and filesystem do not grow
# on their own. Both of these are safe online on a mounted root filesystem.
make exec CMD='sudo growpart /dev/vda 1 && sudo resize2fs /dev/vda1 && df -h /'
```

Then raise `vm_disk_gib` to match, so a future rebuild starts at the size you actually
needed. Confirm you have not left an unappliable diff behind:

```bash
terraform -chdir=terraform plan     # must say: No changes.
```

Note that `terraform plan` will keep reporting the OLD size until you do — the provider
never re-reads capacity from libvirt on refresh, so `virsh vol-info` and Terraform
disagree and only libvirt is right.

### 1b. Manager reachable and healthy

```bash
make verify          # cluster health + API + agent list
make wg              # existing peers, handshakes
```

Do not add a peer to a mesh that is not currently converging. A pre-existing failure will
be indistinguishable from one the new host caused.

---

## 2. Establish what access you have — in ONE pass

Every failed SSH attempt is a failed auth attempt. A server running fail2ban will ban your
address and lock you out of your own machine, so probing by trial and error is the one
approach that can make this unrecoverable.

```bash
# Does key auth already work, for any account? BatchMode never prompts,
# so this cannot hang and cannot consume a password attempt.
for u in root ubuntu debian admin "$VPS_USER"; do
  printf '%-10s ' "$u"
  ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$VPS_PORT" "$u@$VPS_IP" 'echo OK' 2>&1 | tail -1
done
```

**Read the failures, not only the successes.** The parenthesised list names the methods
*the server accepts*, not what your client tried:

| Response | Meaning |
|---|---|
| `OK` | key auth works for that account — best case, no password needed |
| `Permission denied (publickey,password)` | your key is not installed, but passwords **are** accepted |
| `Permission denied (publickey)` | passwords are disabled; a key is the only way in |
| timeout / no route | host, port or firewall problem — not an auth problem |

Then, for an account that works, find out whether sudo needs a password:

```bash
ssh -p "$VPS_PORT" "$VPS_USER@$VPS_IP" 'sudo -n true && echo "NOPASSWD sudo" || echo "sudo needs a password"'
```

### Strongly preferred: install your key first

This removes passwords from the automation path permanently, and you run it in your own
terminal where any real error is immediately visible.

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p "$VPS_PORT" "$VPS_USER@$VPS_IP"
```

### Confirm the underlay before configuring anything

The manager must be able to reach the server's WireGuard port:

```bash
make exec CMD="nc -zvu -w5 $VPS_IP 51820"
```

For UDP, `Connection refused` is the **useful** answer — it proves the packet reached the
host and only the listener was missing, so the path is open. `succeeded` is weak evidence
(nothing refused it). `No route to host` means something is filtering: open `51820/udp` in
the provider's firewall or security group.

---

## 3. Gather the target's facts

Run this on the server. It decides several later steps, and takes one round trip:

```bash
ssh -p "$VPS_PORT" "$VPS_USER@$VPS_IP" '
. /etc/os-release; echo "OS:     $NAME $VERSION_ID"
echo "kernel: $(uname -r)"
echo "virt:   $(systemd-detect-virt 2>/dev/null || echo none)"
ip link add wgtest type wireguard 2>/dev/null \
  && { echo "wg:     kernel support OK"; ip link del wgtest; } \
  || echo "wg:     NO kernel support"
echo "sudo:   $(command -v sudo || echo absent)"
echo "fw:     $(firewall-cmd --state 2>/dev/null || echo "no firewalld")/$(ufw status 2>/dev/null | head -1 || echo "no ufw")"
echo "mem:    $(free -m | awk "/Mem:/{print \$2\" MiB, \"\$7\" available\"}")"
echo "disk:   $(df -h / | awk "NR==2{print \$4\" free of \"\$2}")"
echo "addr:   $(ip -4 -o addr show scope global | awk "{print \$2, \$4}" | tr "\n" " ")"'
```

What to do with each answer:

- **`wg: NO kernel support`** — usually an OpenVZ/LXC container. Stop: plain WireGuard
  cannot work. The overlay is not available to this host.
- **`sudo: absent`** — on a minimal image logging in as root, add
  `ANSIBLE_ARGS="-e ansible_become=false"` to the bootstrap command; you are already root.
- **overlay subnet collision** — if any listed address is inside `10.88.0.0/24`, change
  `wireguard_subnet` before proceeding. A partial collision breaks some flows and not
  others, which is much harder to diagnose than a total failure.
- **RedHat family** — `wireguard-tools` is not in baseos/appstream; the role enables EPEL
  automatically. On RHEL proper (not Rocky/Alma/CentOS) install `epel-release` from the
  EPEL URL yourself first.

---

## 4. Add it to the inventory

Edit `ansible/inventory/vps` (gitignored — this is where real addresses belong).

**One line per host. INI inventory has NO line continuation** — a trailing `\` makes
Ansible fail to parse the *entire file* with `No escaped character`, which silently takes
every other host in it out of service too.

```ini
[wazuh_agents_tunnel]
myvps ansible_host=203.0.113.10 ansible_user=wazuh-ansible wireguard_address=10.88.0.5 wireguard_listen=true wireguard_endpoint=203.0.113.10:51820 wireguard_hub_endpoint=

[bootstrap_targets]
myvps
```

Add `ansible_port=2222` to that line if SSH is not on 22.

The three WireGuard settings each mean something distinct, and this combination is
"the manager dials this host":

| setting | meaning |
|---|---|
| `wireguard_listen=true` | this host accepts handshakes, so its `51820/udp` gets opened |
| `wireguard_endpoint=<ip>:51820` | the address **the manager** dials to reach it |
| `wireguard_hub_endpoint=` (empty) | this host does **not** dial back — it stays passive |

`ansible_user=wazuh-ansible` names an account that does not exist yet. That is correct:
step 5 creates it, and the bootstrap playbook overrides the connection user for that one
run.

Verify the file parses, and that you did not disturb the other hosts:

```bash
cd ansible && ansible-inventory -i inventory/ --graph && cd ..
```

---

## 5. Bootstrap the automation account

Run **once** per host. It installs `python3` and `sudo`, creates `wazuh-ansible` with your
public key, writes `/etc/sudoers.d/90-wazuh-ansible` (validated with `visudo --check`
*before* installing it), and proves the account can reach root. Your own login is
untouched and keeps its password requirement.

Pick the row matching what you found in step 2:

| What you have | Command |
|---|---|
| Key works, **NOPASSWD** sudo (typical for `root`) | `make bootstrap HOSTS=$INV_NAME BOOTSTRAP_USER=$VPS_USER NO_BECOME_PASS=1` |
| Key works, sudo wants a password | `make bootstrap HOSTS=$INV_NAME BOOTSTRAP_USER=$VPS_USER` |
| **Password only**, sudo wants a password | `make bootstrap HOSTS=$INV_NAME BOOTSTRAP_USER=$VPS_USER ASK_PASS=1` |
| **Password only**, logging in as `root` | `make bootstrap HOSTS=$INV_NAME BOOTSTRAP_USER=root ASK_PASS=1 NO_BECOME_PASS=1` |

Both flags are on/off and accept `0`/`no`/`false` to mean off:

- **`ASK_PASS=1`** adds `--ask-pass`. Needed *only* while your key is not installed.
  Without it Ansible has no password to offer and the run fails as
  `Permission denied (publickey,password)` — which is indistinguishable from a wrong
  password.
- **`NO_BECOME_PASS=1`** drops `--ask-become-pass`. Use it when the account already has
  passwordless sudo. Without it you are prompted for a password that does not exist, and
  an empty answer is *not* the same as not being asked.

Prompt order is not what you would guess:

```
SSH password:                                 <- the login password
BECOME password[defaults to SSH password]:    <- the sudo password (Enter reuses the above)
Vault password:                               <- your vault password
```

Add `VAULT_PASS_FILE=.vault-pass` to skip the last one. The vault holds nothing this
playbook needs, but Ansible decrypts `group_vars/all` for any host in scope, so it asks
regardless.

Confirm the outcome — from here on, no password is ever needed for this host:

```bash
ssh -o BatchMode=yes -p "$VPS_PORT" "wazuh-ansible@$VPS_IP" 'id; sudo -n id -un'
```

A dry run (`--check`) also works on a fresh host from this step onwards.

---

## 6. Build the overlay

```bash
make tunnel
```

This runs the hub **and every spoke in one play**, which is structural rather than
stylistic: each host generates its own keypair, publishes only its *public* key as a fact,
and templates its config from the others' facts. Ansible's `linear` strategy guarantees
every host has published before any host writes a config. Split across two plays, that
guarantee is lost.

What happens on the new host: `wireguard-tools` is installed, a private key is generated
**on the host** with `umask 077` and never read back by Ansible, `51820/udp` is opened in
whichever firewall is actually running (or you get an explicit warning that none is), and
`wg-quick@wg0` is enabled and started.

Expected output for a host the manager dials:

```
wazuh-server 10.88.0.1 on wg0: N peer(s) configured, 10.88.0.5 reachable.
myvps        10.88.0.5 on wg0: 1 peer(s) configured, 10.88.0.1 reachable.
```

---

## 7. Enrol the agent

```bash
make agent-check HOSTS=$INV_NAME     # dry run — it is a real machine
make agent       HOSTS=$INV_NAME
```

On a host that has **never** been enrolled, `agent-check` stops at the Wazuh keyring with
`file (/usr/share/keyrings/wazuh.gpg) is absent, cannot continue`. That is the dry run
running out of road, not a fault: `--check` only simulated the download, and patching it
would just move the failure to `apt`, which cannot resolve a package from a repository
that was also only simulated. Everything before that point was genuinely checked.

Expect a final message like:

```
myvps: agent 4.14.7 running and connected to 10.88.0.1:1514.
```

---

## 8. Verify — four checks, increasing in strength

Only the last one proves the overlay is load-bearing rather than merely present.

```bash
# 1. the manager sees it, and every other agent is still Active
make exec CMD='sudo docker exec wazuh.manager /var/ossec/bin/agent_control -l'

# 2. the agent connected to the TUNNEL address
ssh -p "$VPS_PORT" "wazuh-ansible@$VPS_IP" \
  'sudo grep "Connected to the server" /var/ossec/logs/ossec.log | tail -1'
#    expect [10.88.0.1]:1514 — a public address here means the overlay is decorative

# 3. the interface holds a key and a recent handshake
ssh -p "$VPS_PORT" "wazuh-ansible@$VPS_IP" 'sudo wg show'
#    `public key: (none)` means the interface has NO identity — see the table in step 10
```

**Schedule the repair BEFORE you break anything.** This test deliberately cuts a working
tunnel, and the step that restores it is the last line — so anything that interrupts the
sequence (Ctrl-C, a dropped SSH session, a laptop that powers off) leaves the tunnel down
and that agent silently offline. That is not hypothetical: it happened here, and the host
sat disconnected until someone read
`journalctl -u wg-quick@wg0` and found a `Stopping…` with no matching `Started`.

A transient systemd timer removes the dependency on the session surviving:

```bash
# 4a. arm the restore FIRST. It fires in 90s no matter what happens to this shell.
ssh -p "$VPS_PORT" "wazuh-ansible@$VPS_IP" \
  'sudo systemd-run --on-active=90s --unit=wg-restore --collect \
     systemctl start wg-quick@wg0'

# 4b. record every agent's keepalive, then cut the tunnel
make exec CMD='sudo docker exec wazuh.manager /var/ossec/bin/agent_control -i 00X | grep -E "Status|Last keep alive"'
ssh -p "$VPS_PORT" "wazuh-ansible@$VPS_IP" 'sudo systemctl stop wg-quick@wg0'
sleep 70

# 4c. THIS agent's Last keep alive must be frozen while the others advanced.
make exec CMD='sudo docker exec wazuh.manager /var/ossec/bin/agent_control -i 00X | grep -E "Status|Last keep alive"'

# 4d. the timer has restored it by now; confirm rather than assume
ssh -p "$VPS_PORT" "wazuh-ansible@$VPS_IP" 'systemctl is-active wg-quick@wg0; sudo wg show wg0 | grep handshake'
```

Expect the agent to need **90–120 seconds** to return to `Active` after the tunnel is
back: the manager only re-marks it once a keepalive arrives, so `Disconnected` immediately
after 4d is normal, not a failure.

Then prove convergence. A second run of everything must report `changed=0`:

```bash
make tunnel && make agent HOSTS=$INV_NAME && make configure
```

If anything reports `changed` on a second run, a role is rewriting a file it should have
left alone. Fix that before moving on — non-idempotence hides real drift.

---

## 9. Clean up

- If this host previously used a differently-named automation account, retire it: set
  `bootstrap_revoke_users='["<old>"]'` on its inventory line and re-run bootstrap
  **connecting as the replacement** (the role refuses to revoke the account it is logged
  in as, asserted before it changes anything). A superseded account keeps its authorised
  key and its NOPASSWD root grant, and nobody is watching it.
- Delete `.vault-pass` if you created one.
- If the step-3 output said no firewall is running, decide whether that is acceptable. The
  role will have told you explicitly rather than silently doing nothing.

---

## 10. Troubleshooting, in the order you will meet it

| Symptom | Cause | Check / fix |
|---|---|---|
| `Permission denied (publickey,password)` during bootstrap | no key installed and `--ask-pass` not passed | add `ASK_PASS=1`; also confirm `ansible.cfg` does **not** pin `PreferredAuthentications` (see below) |
| Prompted for a sudo password that does not exist | `--ask-become-pass` sent to a NOPASSWD account | add `NO_BECOME_PASS=1` |
| Ansible fails to parse the whole inventory | backslash line continuation in the INI file | put each host on one line |
| `No match for argument: wireguard-tools` | RHEL-family host without EPEL | the role handles Rocky/Alma/CentOS; on RHEL install `epel-release` first |
| No handshake, ever | UDP blocked on the underlay | `nc -zvu <ip> 51820` from the manager; open it in the provider firewall |
| Handshake, then silence after ~2 min | NAT mapping expired | `PersistentKeepalive` missing on the dialling side |
| `wg show` prints `public key: (none)` | the interface has **no private key** | `sudo wg set wg0 private-key /etc/wireguard/wg0.key`; the role now converges this every run |
| Tunnel pings but the agent never connects | manager's `DOCKER-USER` rules | `sudo iptables -S DOCKER-USER` on the manager — ufw does not govern Docker-published ports |
| Agent connects, no events arrive | MTU on the real internet path | lower `wireguard_mtu` to 1380 and re-run `make tunnel` |
| Worked, then broke after a manager reboot | iptables rules are not persistent | `systemctl status wazuh-docker-firewall` |
| Agent flaps Active/Disconnected | version skew or tunnel instability | agent version must never exceed the manager's; the role pins and holds it |

### The `PreferredAuthentications` trap

If `ansible.cfg` has `-o PreferredAuthentications=publickey` in `ssh_args`, `--ask-pass`
can never work. `ssh_args` is placed **first** on the ssh command line and ssh uses the
**first** value it obtains for any option, so that pin beats everything Ansible appends
afterwards. The password is collected and never offered, and sshd's reply is identical to a
wrong password.

Ansible already handles this correctly on its own: with no password it appends
`PasswordAuthentication=no` plus a publickey-only list; with a password it deliberately
appends neither. Verify against a dead endpoint so you add no failed attempts on the real
host:

```bash
printf '[probe]\nnowhere ansible_host=127.0.0.1 ansible_port=1\n' > /tmp/probe.ini
ansible -i /tmp/probe.ini nowhere -m ping -e ansible_password=x -vvv 2>&1 \
  | grep -oE 'PreferredAuthentications=[^ ]*|PasswordAuthentication=[^ ]*' | sort -u
```

With a password supplied this must print **nothing**.

---

## 11. Special case: enrolling a host that has been attacked

A SIEM agent is exactly the right thing to put on a server you are worried about — but the
order matters, and a few of its outputs mean less than they appear to on a host that may
already be compromised.

**What the agent cannot tell you.** FIM, SCA and rootcheck all establish a *baseline* on
first run. On an already-compromised host that baseline records the compromised state as
normal: a planted binary or modified config becomes the reference, and you will never get
an alert about it. Wazuh will report faithfully on everything that changes *from now on*,
which is useful, but it is not a compromise assessment.

**Treat agent output as untrusted on a host you believe is owned.** The agent runs on the
box, so anything with root there can stop it, filter it, or lie to it. The alerts you do
receive are evidence; their absence is not.

**Order of operations.** If the machine is genuinely compromised, the standard answer is
still to rebuild it from a known-good image and enrol the *new* host — then FIM's baseline
is meaningful. If rebuilding is not possible yet, enrolling now is still worth doing,
because it starts the evidence trail and will catch reinfection attempts. Just record
*why* the baseline is untrustworthy, so a future you does not over-read a quiet dashboard.

**Check what the box was patched to.** A large backlog of pending security updates is a
common route in:

```bash
ssh -p "$VPS_PORT" "wazuh-ansible@$VPS_IP" \
  'apt list --upgradable 2>/dev/null | wc -l; ls -la /var/log/apt/history.log'
```

Once enrolled, Wazuh's vulnerability detection will list the CVEs it can see from the
package inventory — which is the same information, correlated and kept up to date. Do not
mistake that for the host being safe.

**Be careful with what you enable during an incident.** `report_changes` on a busy
directory raises alert volume sharply; SCA and rootcheck scans add I/O. On a host already
under pressure from an attack, start with the default policy and widen it deliberately
rather than enabling everything at once.

---

## What this runbook does not cover

- **Hosts that cannot accept inbound UDP** (behind NAT you do not control, or a container
  without WireGuard kernel support). See
  [PRODUCTION-VPS.md](PRODUCTION-VPS.md#which-direction-dials).
- **Making the manager publicly reachable.** As long as the manager sits behind home NAT,
  every agent must either be dialable or share a reachable rendezvous. The durable fix is
  an always-on manager with a stable address and ≥4 GiB RAM and real disk.
- **Index retention.** Worth having, but measure first: on this deployment all indices were
  ~16 MiB while the CVE feed was ~11 GiB, so retention policies address a much smaller
  problem than the name suggests.
