# Enrolling Wazuh agents

A Wazuh server with no agents is an empty SIEM. This is the step that makes it do
something.

## The first agent: this workstation

The KVM host is the natural first target — it reaches the lab network directly, and it is
the machine you actually care about monitoring.

```bash
make agent-local
```

It prompts for your sudo password (this host has no passwordless sudo), installs
`wazuh-agent` from `packages.wazuh.com/4.x/yum/`, points it at the manager, and waits for
the connection to be confirmed in the agent's own log.

Then check the dashboard: **Endpoints Summary** should list it as *Active* within about a
minute.

## Other hosts

Add them to an inventory and run:

```bash
make agent HOSTS=web01
make agent HOSTS=all
```

The role handles Debian/Ubuntu (apt) and RHEL/Fedora (dnf). The manager address comes from
the inventory Terraform generated, so you rarely need to pass it. When you do:

```bash
cd ansible
ansible-playbook agent.yml -i my-inventory.ini \
  -e target_hosts=web01 \
  -e wazuh_manager_address=192.168.140.10
```

## Reachability

Agents connect **outbound** to the manager on 1514/tcp, and to 1515/tcp once at enrolment.
The manager never initiates a connection to an agent, so agents behind NAT need no inbound
rules.

What matters is that the agent can route to the manager:

| Agent location | Reaches the manager at | Works? |
|---|---|---|
| The KVM host itself | `192.168.140.10` | Yes — it owns the bridge |
| A VM on the `wazuh-lab` network | `192.168.140.10` | Yes |
| A VM on libvirt's `default` network | — | **No** by default — see below |
| Another machine on your LAN | — | No — the network is NAT-only |
| **A VPS on the internet** | **`10.88.0.1` (the tunnel)** | **Yes, over WireGuard** |

libvirt puts every virtual bridge in firewalld's `libvirt` zone, but that zone does **not**
permit forwarding *between* networks — verified in this lab: a VM on `192.168.122.0/24`
cannot reach `192.168.140.10` in either direction. Attaching the VM a second NIC on
`wazuh-lab` gives it a path; the overlay below is what the agent actually uses.

### Hosts outside your LAN: the WireGuard overlay

A VPS cannot reach `192.168.140.10` at all. The manager sits on a private network behind a
workstation behind a router, and **agents connect outbound to the manager** — so there is
nothing for the VPS to connect to.

`roles/wireguard` puts the manager and each remote host on a private subnet that exists
only inside the tunnel:

```
   VPS  10.88.0.2 ──dials──▶ 10.88.0.1  wazuh.manager   (hub, listens :51820)
   agent ────── 1514/tcp ──▶ 10.88.0.1  and nowhere else
```

**Why plain WireGuard rather than Tailscale or Headscale:** no third-party account, no
auth key to obtain, and no SaaS in the trust path of a security tool. It is also the
protocol those products are built on, so what you learn here transfers to them and not the
other way round.

Setup — note that there is no secret to create:

```bash
make bootstrap HOSTS=bootstrap_targets BOOTSTRAP_USER=<existing-user> ASK_PASS=1  # once per host
make vps-inventory       # then add the host under [wazuh_agents_tunnel]
make tunnel              # builds the overlay on the hub and every spoke
make agent-check HOSTS=wazuh_agents_tunnel
make agent       HOSTS=wazuh_agents_tunnel
```

`ASK_PASS=1` is needed only while your SSH key is not yet installed on the host; add
`NO_BECOME_PASS=1` instead when the account you connect as already has NOPASSWD sudo.
The full procedure for a real machine — including how to establish which of those you
have without burning failed auth attempts — is
[PRODUCTION-VPS.md → Adding a new VPS](PRODUCTION-VPS.md#adding-a-new-vps-step-by-step).

For a single new server end to end — preconditions, the access probe, bootstrap, tunnel,
enrolment, verification and troubleshooting — use
[RUNBOOK-ENROL-PUBLIC-VPS.md](RUNBOOK-ENROL-PUBLIC-VPS.md).

Three addresses are involved and conflating them is the main source of confusion:

| Variable | Meaning |
|---|---|
| `ansible_host` | how **Ansible** reaches the host, to configure it |
| `wireguard_address` | the host's address **inside** the tunnel — you assign it |
| `wazuh_manager_address` | where the **agent** sends events: the hub's tunnel address |

The underlay — whatever routable path carries the encrypted packets — never appears in the
inventory at all. WireGuard needs only the hub's endpoint.

**Keys never leave the host.** `wg genkey` runs on each machine, writing the private key
`0600 root`; Ansible reads back only the public half and exchanges those through inventory
facts. `wg0.conf` contains no secret — the private key reaches the interface via
`PostUp = wg set %i private-key <file>`. So a leaked config is not a leaked tunnel, and
there is no shared enrolment token to rotate.

**Why the agent points at `10.88.0.1`:** that address exists nowhere except inside
WireGuard. No firewall rule is needed to prove the overlay carries the traffic — stop
`wg-quick@wg0` and the agent goes Disconnected, because there is no other route.

**On the firewall:** `roles/common` now restricts the Docker-published agent ports to the
overlay subnet using the `DOCKER-USER` chain — the one chain Docker jumps to first and
never flushes, and therefore the only place a rule can actually restrict a published port.
This is the fix for the ufw limitation documented in
[ARCHITECTURE.md](ARCHITECTURE.md#what-the-firewall-does-and-does-not-do): on a VPS it is
the difference between 1514/1515 open to the internet and open to nobody.

Run against a real VPS in check mode first — the role installs packages and brings up a
network interface on a machine you care about:

```bash
make agent-check HOSTS=wazuh_agents_tunnel
```

### What the agent actually monitors

Connected is not the same as monitored. A bare agent reports little more than that it is
alive.

`roles/wazuh_stack` pushes a shared `agent.conf` per group — Wazuh's centralised
configuration mechanism — so a class of host gets one policy and a new VPS inherits it on
registration. Hosts in `wazuh_agents_tunnel` default to the `vps` group, which adds FIM on
the paths an attacker touches (`/var/www`, cron directories, `/etc/systemd/system`,
`~/.ssh`) on top of the baseline `/etc`, `/usr/bin`, `/boot`, plus SCA, rootcheck and
syscollector.

Edit `roles/wazuh_stack/templates/agent.conf.j2` and re-run `make configure`. Agents pick
changes up within ~10 minutes with no restart. Do not edit it on the manager, and do not
configure agents individually — that is how monitoring drifts from what you think it is.

## Groups

Groups are how you give different classes of host different rule sets and file-integrity
policies:

```bash
cd ansible
ansible-playbook agent.yml -e target_hosts=web01 -e wazuh_agent_group=webservers
```

Create the group in the dashboard first (**Endpoints → Groups**), or the agent registers
into `default`.

## Version pinning

The role installs the agent at the manager's version and then holds it — `dpkg_selections`
on Debian, `exclude=` in `dnf.conf` on RHEL.

This is deliberate: **an agent must never be newer than its manager.** An unattended
upgrade that bumps an agent past the server's version silently breaks its connection, and
the symptom — an agent that was working and is now *Disconnected* — gives no hint about
the cause. When you upgrade Wazuh, raise `wazuh_version` and re-run both playbooks: server
first, then agents.

## When an agent will not connect

```bash
# On the agent
sudo /var/ossec/bin/wazuh-control status
sudo tail -50 /var/ossec/logs/ossec.log
grep -c "Connected to the server" /var/ossec/logs/ossec.log

# Is the manager reachable at all?
nc -zv 192.168.140.10 1514
```

| Log message | Cause |
|---|---|
| `Unable to connect to enrollment service` | 1515 blocked, or the manager is not up yet |
| `Invalid server address` | `<address>` in `ossec.conf` is wrong — re-run the playbook |
| `Duplicate agent name` | An agent with this name is already registered; remove it in the dashboard or use a different `wazuh_agent_name` |
| `Connected to the server` then repeated disconnects | Version skew — check the agent is not newer than the manager |

Agent state on the manager side:

```bash
make ssh
sudo docker exec wazuh.manager /var/ossec/bin/agent_control -l
```
