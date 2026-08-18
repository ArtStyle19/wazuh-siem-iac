# Monitoring a production VPS

How a real internet-facing server gets enrolled, what the local rehearsal does and does
not prove, and the checklist that separates the two.

For migrating the *manager* to a VPS, see [PORTING-TO-VPS.md](PORTING-TO-VPS.md). This
document is about the other direction: the manager stays where it is, and a remote
server becomes a monitored endpoint.

---

## The problem, stated precisely

Wazuh agents connect **outbound** to the manager. The manager never dials an agent. So
enrolment needs exactly one thing: a path from the agent to the manager's port 1514.

A VPS on the internet has no such path to a manager behind a home router, and the naive
fixes are all worse than they look:

| Approach | Why not |
|---|---|
| Forward 1514/1515 from the router | Exposes Wazuh's agent protocol to the internet. Enrolment on 1515 accepts anyone who can reach it unless you pre-provision keys. |
| Put the manager on the VPS too | Legitimate, but now your SIEM shares a blast radius with the thing it monitors. |
| Expose the dashboard/API publicly | 443 and 55000 are far more attractive targets than one UDP port. |
| VPN with a SaaS control plane | Works well, but puts a third party in the trust path of a security tool, and needs an account and an enrolment token. |

This project uses **plain WireGuard**: one UDP port, keys generated on each host and
never transmitted, no third party, no shared secret to rotate.

---

## Topology

```
        ┌────────────── wg0: 10.88.0.0/24 ──────────────┐
  VPS   │                                               │   manager
  10.88.0.2 ──────dials 51820/udp──────▶ 10.88.0.1 (hub, listens)
  wazuh-agent ────── 1514/tcp ─────────▶ 10.88.0.1
        │                                               │
        └── underlay: the internet, carrying only ──────┘
            encrypted UDP on one port
```

**The agent is configured with `10.88.0.1`** — an address that exists nowhere except
inside the tunnel. That is deliberate: it means the overlay cannot be quietly bypassed,
and a tunnel failure surfaces as Wazuh's own *agent disconnected* alert rather than as
traffic silently taking some other route.

### Which direction dials

The default has the manager listen and agents dial in — the conventional shape, and what
a datacenter-hosted manager looks like. For a manager behind NAT you have two options,
and the role supports both by configuration alone:

**A. Forward one UDP port** (recommended). Forward `51820/udp` on your router to the
manager. This is a far smaller exposure than 1514/1515: WireGuard does not respond at
all to a packet that fails cryptographic authentication, so the port is unfindable by
scanning — it behaves exactly like a closed port to anyone without a valid key.

**B. Invert the tunnel.** Zero router configuration: each VPS listens and the manager
dials out with `PersistentKeepalive`. Set on the spoke:

```yaml
wireguard_listen: true
wireguard_endpoint: "<vps public ip>:51820"
```

and clear `wireguard_endpoint` on the hub. The cost is that each VPS now exposes a UDP
port and the manager must know every endpoint — so this scales worse, and is the reason
A is the default.

---

## What the local rehearsal proves — and what it does not

`lab-vm-01` was used as a stand-in. It is worth being exact about the limits, because
"it worked in the lab" is where production surprises come from.

**Proved by the rehearsal:**

- key generation on each host, exchange of public keys only, and a config file that
  contains no secret
- peer derivation from inventory: adding a host is one inventory line
- the tunnel establishing over an underlay the two hosts share
- the agent reaching the manager *through* the tunnel and appearing as Active
- the self-proving property: stopping `wg-quick@wg0` disconnects the agent
- `DOCKER-USER` rules restricting the agent ports to the overlay subnet

**Not proved, and worth expecting to bite:**

- **NAT traversal.** The lab underlay is one hop through a hypervisor. A real VPS
  involves at least two NATs, possibly CGNAT on the home side, and no control over the
  path. Option A above removes most of this risk; option B removes the rest.
- **MTU discovery.** `MTU = 1420` is set explicitly because the failure mode is nasty —
  the handshake and pings succeed while large payloads hang. On a path with additional
  encapsulation (PPPoE, another VPN, some mobile carriers) 1420 may still be too high.
  If agents connect but events do not arrive, drop to 1380 and retest.
- **Latency and loss.** Sub-millisecond locally. At 100 ms with 1% loss, agent buffering
  and the manager's queue behave differently, and `agents_disconnection_time` may need
  raising from its 10 m default.
- **Log volume.** One idle VM produces nothing like a real server. Event rate is what
  sizes indexer disk, shard count and retention — none of which the lab exercises.
- **Key rotation and revocation.** Removing a peer is an inventory deletion plus a
  `wg syncconf`, but that lifecycle has not been run here.

---

## Adding a new VPS, step by step

The whole procedure is six steps. Only **step 2** varies, and it varies on one question:
what access do you already have to the machine?

### Step 0 — find out what access you actually have

Do this in **one pass** and write down the answer. Every failed SSH attempt is a failed
auth attempt, and a VPS running fail2ban will ban your address and lock you out of your
own server — so probing by trial and error is the one approach that can make the problem
unrecoverable.

```bash
VPS=203.0.113.10

# a) Does key auth already work, and for which account?
#    BatchMode=yes means "never prompt", so this cannot hang and cannot burn a password.
for u in root ubuntu debian admin cloud-user youruser; do
  printf '%-12s ' "$u"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$u@$VPS" 'echo OK' 2>&1 | tail -1
done
```

Read the failures, not just the successes. `Permission denied (publickey,password)` names
the methods **the server accepts** — so that string tells you password auth is available
even though your key was not. `Permission denied (publickey)` alone means passwords are
disabled entirely and a key is your only way in.

```bash
# b) For an account that DOES work, does sudo need a password?
ssh <user>@$VPS 'sudo -n true && echo "NOPASSWD sudo" || echo "sudo needs a password"'
```

### Step 1 — decide which end dials

This is a property of the network, not a preference. See
[Which direction dials](#which-direction-dials) above.

- **Hub dials the VPS** — needs inbound `51820/udp` open on the VPS. Correct when your
  manager is behind NAT with no port forward, which is the usual home-lab case.
- **VPS dials the hub** — needs the manager reachable at a stable address. Correct in a
  datacenter, or with a port forward plus dynamic DNS.

Confirm the direction you chose is actually possible before configuring it:

```bash
nc -zvu $VPS 51820                    # from the manager, if the hub dials
nc -zvu <manager endpoint> 51820      # from the VPS, if the VPS dials
```

For UDP, `succeeded` only means nothing refused the packet — it is weak evidence.
`Connection refused` is the *useful* answer: it proves the packet reached the host and
nothing was listening, so the path is open and only the service is missing.

### Step 2 — bootstrap the automation account

This is the step that depends on your Step 0 answer. It runs **once** per host and leaves
the machine reachable as `wazuh-ansible` by key with passwordless sudo, after which every
other playbook treats it like any other host.

| What you have | Command |
|---|---|
| Key works, **NOPASSWD** sudo (typical for `root` or a cloud-image account) | `make bootstrap HOSTS=<host> BOOTSTRAP_USER=<acct> NO_BECOME_PASS=1` |
| Key works, sudo **wants a password** | `make bootstrap HOSTS=<host> BOOTSTRAP_USER=<acct>` |
| **Password only**, sudo wants a password | `make bootstrap HOSTS=<host> BOOTSTRAP_USER=<acct> ASK_PASS=1` |
| **Password only**, logging in as `root` | `make bootstrap HOSTS=<host> BOOTSTRAP_USER=root ASK_PASS=1 NO_BECOME_PASS=1` |
| Neither — no key, passwords disabled | Add your key via the provider's web console, then use row 1 |

Both flags are on/off, and `=0`/`no`/`false` mean off:

- `ASK_PASS=1` → adds `--ask-pass`. **Only** needed when your key is not installed yet.
  Without it Ansible has no password to offer and fails as
  `Permission denied (publickey,password)` — which looks exactly like a wrong password.
- `NO_BECOME_PASS=1` → drops `--ask-become-pass`. Use it when the account already has
  NOPASSWD sudo. Leaving it off prompts for a password that does not exist, and an empty
  answer is not the same as not asking.

**Prompt order is not the order you would guess.** Ansible asks:

```
SSH password:                          <- the login password
BECOME password[defaults to SSH password]:   <- the sudo password (Enter reuses the above)
Vault password:                        <- your vault password
```

Add `VAULT_PASS_FILE=.vault-pass` to skip the third.

**Strongly preferred shortcut.** Install your key first and you are permanently in row 1
or 2, with no password anywhere in the automation path:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@$VPS
```

Two footnotes that only bite on minimal images:

- If you connect as `root` on an image with **no `sudo` binary**, escalation cannot work
  yet — you are already root, so skip it:
  `make bootstrap ... ANSIBLE_ARGS="-e ansible_become=false"`.
- The account cannot be named `wazuh`. The `wazuh-agent` package creates its own `wazuh`
  user (uid 113) and group, which is why this project uses `wazuh-ansible`.

Verify the outcome before going on — from here the password is never needed again:

```bash
ssh -o BatchMode=yes wazuh-ansible@$VPS 'id; sudo -n id -un'
```

### Step 3 — describe the host in the inventory

In `ansible/inventory/vps` (gitignored). The `wazuh-ansible` user is what you just
created; the three WireGuard settings encode the direction from Step 1.

```ini
[wazuh_agents_tunnel]
# Hub dials this host (manager behind NAT):
newvps ansible_host=203.0.113.10 ansible_user=wazuh-ansible wireguard_address=10.88.0.4 \
       wireguard_listen=true wireguard_endpoint=203.0.113.10:51820 wireguard_hub_endpoint=

# ...or this host dials the hub (manager reachable):
# newvps ansible_host=203.0.113.10 ansible_user=wazuh-ansible wireguard_address=10.88.0.4
```

`wireguard_hub_endpoint=` (empty) is what makes a host purely passive: it will not dial
out, so the hub must dial it. Give every host a unique `wireguard_address`.

### Step 4 — build the overlay, then enrol

```bash
make tunnel                        # hub + every spoke, in one play (key exchange needs that)
make agent-check HOSTS=newvps      # dry run — it is a real machine
make agent       HOSTS=newvps
```

On a host that has **never** been enrolled, `agent-check` stops at the Wazuh keyring:
`--check` only simulated the download, so the next task cannot find it. That is the dry
run running out of road, not a fault — see the comment on the `agent-check` target in the
Makefile.

### Step 5 — verify it for real

Four checks, in increasing strength. The last one is the only one that proves the overlay
is load-bearing rather than merely present.

```bash
# 1. the manager sees it
make exec CMD='sudo docker exec wazuh.manager /var/ossec/bin/agent_control -l'

# 2. the agent connected to the TUNNEL address, not a public one
ssh wazuh-ansible@$VPS 'sudo grep "Connected to the server" /var/ossec/logs/ossec.log | tail -1'
#    expect [10.88.0.1]:1514 — a public address here means the overlay is decorative

# 3. the interface really holds a key and a recent handshake
ssh wazuh-ansible@$VPS 'sudo wg show'
#    `public key: (none)` means the interface has NO identity: see handlers/main.yml

# 4. cut the tunnel and watch ONLY this agent stall
ssh wazuh-ansible@$VPS 'sudo systemctl stop wg-quick@wg0'
#    the new agent's `Last keep alive` must freeze while the others advance
ssh wazuh-ansible@$VPS 'sudo systemctl start wg-quick@wg0'
```

Then confirm convergence — a second run must report `changed=0`:

```bash
make tunnel && make agent HOSTS=newvps
```

### Step 6 — clean up

- If the host previously had a differently-named automation account, retire it: set
  `bootstrap_revoke_users='["<old>"]'` on the host line and re-run bootstrap **connecting
  as the replacement** (it refuses to revoke the account it is logged in as). A superseded
  account keeps its authorised key and its root grant, and nobody is watching it.
- Delete `.vault-pass` if you created one.
- The VPS has no host firewall unless you gave it one. A fresh cloud image typically has
  `ufw` absent and an `ACCEPT` input policy, so only your provider's firewall is in play.

---

## Checklist for a real VPS

**Before enrolling**

- [ ] Work through [Adding a new VPS](#adding-a-new-vps-step-by-step) — in particular
      Step 0, in one pass, before any blind retry.
- [ ] Confirm the underlay in the direction you chose: `nc -zvu <endpoint> 51820`.
- [ ] `make agent-check HOSTS=...` first. It is a real machine.

**Firewall**

- [ ] Forward **only** `51820/udp`. Never 1514, 1515, 443 or 9200.
- [ ] On the manager, confirm the `DOCKER-USER` rules are live:
      `sudo iptables -S DOCKER-USER`. ufw alone does **not** restrict Docker-published
      ports — see [ARCHITECTURE.md](ARCHITECTURE.md#what-the-firewall-does-and-does-not-do).
- [ ] On the VPS, nothing inbound is needed at all. The agent is outbound-only.
- [ ] Rate-limit SSH and install fail2ban. The lab does neither.

**Overlay**

- [ ] Keep `AllowedIPs` at `/32` per peer. Never `0.0.0.0/0` — that would route the
      server's entire egress through your home connection.
- [ ] Check the overlay subnet does not collide with anything on the VPS, especially
      Docker (`172.17+`) or another VPN. A collision breaks some flows and not others.
- [ ] Verify `wg show` reports a recent handshake, not merely that the unit is active.

**Wazuh**

- [ ] Put the host in the `vps` group so it gets the internet-facing FIM policy:
      `report_changes` on `/var/www`, cron directories, `/etc/systemd/system`, `~/.ssh`.
- [ ] Agent version must never exceed the manager's. The role pins and holds it.
- [ ] Set an index retention (ISM) policy before real volume arrives.
- [ ] Decide what an *agent disconnected* alert means operationally — with the agent
      pointed at a tunnel address, that alert is also your tunnel monitor.

---

## Failure modes, in the order you will meet them

| Symptom | Cause | Check |
|---|---|---|
| No handshake, ever | UDP blocked on the underlay | `nc -zvu <endpoint> 51820` from the spoke |
| Handshake, then silence after ~2 min | NAT mapping expired | `PersistentKeepalive` missing on the dialling side |
| Tunnel pings, agent never connects | `DOCKER-USER` rules or the manager's ports | `sudo iptables -S DOCKER-USER` on the manager |
| Agent connects, no events arrive | MTU | lower `wireguard_mtu` to 1380 and retest |
| Worked, then stopped after a reboot | iptables rules are not persistent | `systemctl status wazuh-docker-firewall` |
| Agent flaps Active/Disconnected | version skew, or tunnel instability | `wg show latest-handshakes`, agent vs manager version |

The first thing to check for any of these is whether the tunnel is genuinely up:

```bash
make wg                                    # on the manager
ssh <vps> 'sudo wg show; ping -c3 10.88.0.1'
```
