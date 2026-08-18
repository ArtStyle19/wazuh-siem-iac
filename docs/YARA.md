# YARA — content-based malware identification

FIM tells you **that** a file appeared. YARA tells you **what it is**.

This document covers what the `yara` role builds, how the detection chain fits together,
how to turn it on, how to schedule it, and — at the end, in detail — **what does not work
yet**. Read that last section before you rely on any of this.

---

## Why it exists

On 2026-08-12 an internet-facing host in this lab was compromised. Wazuh recorded the
behaviour faithfully: **910 FIM events** in three hours, a randomly named binary created
and deleted in `/usr/bin` every five seconds. Every one of those was an independent level
5 or 7 alert saying *"file added to the system"*.

Nobody reviews 910 level 5 alerts. And even reading them, they never named the thing.
The identification was done by hand: capture a copy through `/proc/<pid>/exe`, pull
strings out of it with `tr` because `strings` was not installed, and recognise the family
from `BB2FA36AAA9541F0`, a TencentTraveler User-Agent and `cp /lib/libudev.so`. That took
hours. It was **XorDDoS**.

Two things follow from that, and both are implemented here:

1. **The alert should name the family.** That is YARA. It matches on file *content*, so
   this family's polymorphism — three captured copies, three different SHA256 sums —
   does not defeat it. The pinned rule set identified all three.
2. **The behaviour itself should raise one alert, not 910.** That is rule `110010`, a
   composite rule that aggregates the create/delete pattern.

A third gap turned up while fixing the first two, and it is the reason FIM's scope was
widened in the same change: **FIM was not watching `/lib` or `/etc/init.d`**, which is
exactly where the persistence lived. Without widening it, YARA would never have been
handed `libudev.so` to look at.

---

## The chain

There are two independent paths into the same alerts. That is deliberate: they cover
different failure modes.

### Path A — active response (event-driven)

```
  agent                                    manager
  ─────                                    ───────
  FIM sees a new/changed file  ──────────▶  rule 554 / 550
                                                │
       yara.sh  ◀───── active response ─────────┘   (location: local)
         │
         │  three guards, then: yara -w index.yar <file>
         ▼
  /var/ossec/logs/active-responses.log
         │
         └── shipped by logcollector ──────▶  decoder wazuh-yara-scan-result
                                                │
                                                ▼
                                             rule 110001 — level 12
                                             "YARA: Linux_Trojan_Xorddos_2aef46a6
                                              matched on /usr/bin/dmbnwiyxaa"
```

Five hops, and **any of them can break without showing**. That is what the canary rule is
for — see [Verifying the chain](#verifying-the-chain).

### Path B — the sweep (state-driven)

Active response only sees what **changes**. It never sees what was *already on disk* when
the agent was installed, and on a host compromised beforehand that is precisely where the
malware is: FIM's baseline recorded the implant as normal state, so no event ever fires
and no alert ever mentions it.

The sweep looks at what **is there**:

```
  make yara-scan HOSTS=<pattern> [PATHS="/lib /usr/bin"]
         │
         ▼
  yara-scan.sh on the agent
         ├── disk:      find -xdev -type f -size -50000k  │ one yara --scan-list
         └── processes: /proc/<pid>/exe, deduplicated      │ one yara --scan-list
         │
         ▼
  /var/ossec/logs/yara-scan.log  ──▶ same decoders ──▶ 110001 (disk) / 110004 (process)
```

The process scan is the half that matters most, and it is not an extra: this family's
technique is *create the binary, execute it, delete it within a second*. Nothing is left
on disk. But `/proc/<pid>/exe` still points at the inode while the process lives, so it
can be read and scanned there. On the compromised host the sweep found
`/usr/bin/mskgdnhkdv (deleted) [pid 77990]` — invisible to any disk scan, at any depth.

The sweep writes to **its own log**, not to `active-responses.log`. Two reasons: the
agent's local `ossec.conf` already declares `active-responses.log`, and declaring it twice
makes logcollector warn `is duplicated` and drop one of the declarations; and that file is
the active-response audit trail, which on a host under investigation is evidence and
should not be mixed with scan output.

---

## What is deployed where

| Where | What | Managed by |
|---|---|---|
| control node | `~/.cache/wazuh-siem-iac/protections-artifacts` — sparse git checkout at the pinned commit | `roles/yara/tasks/rules.yml` |
| agent | `/var/ossec/yara/rules/public.yar` — 248 `Linux_*.yar` files concatenated, 902 rules | `rules.yml` |
| agent | `/var/ossec/yara/rules.local/` — our own rules, versioned in this repo | `rules.yml` |
| agent | `/var/ossec/yara/index.yar` — one file `include`-ing both | `rules.yml` |
| agent | `/var/ossec/yara/PROVENANCE` — repo, commit, filter | `rules.yml` |
| agent | `/var/ossec/active-response/bin/yara.sh` | `templates/yara.sh.j2` |
| agent | `/var/ossec/active-response/bin/yara-scan.sh` | `templates/yara-scan.sh.j2` |
| agent | `/var/ossec/logs/yara-scan.log` — `root:wazuh 0660` | `tasks/main.yml` |
| manager | `/var/ossec/etc/decoders/local_decoder.xml` | `roles/wazuh_stack/templates/local_decoder.xml.j2` |
| manager | `/var/ossec/etc/rules/local_rules.xml` | `roles/wazuh_stack/templates/local_rules.xml.j2` |
| manager | `<command>yara_scan</command>` + `<active-response>` | `templates/wazuh_manager.conf.j2` |

### The rule set, and why this one

`elastic/protections-artifacts`, pinned to a commit SHA.

The obvious candidate was `Neo23x0/signature-base`, and it was rejected on measurement:
it **does not cover XorDDoS**, and only 5 of its 746 rule files are Linux — it targets
Windows and APT tooling. Elastic ships 248 `Linux_*` files with 902 rules, including 24
XorDDoS variants. The rule that fired, `Linux_Trojan_Xorddos_2aef46a6`, was authored
2021-01-12 by Elastic, five years before this incident. Nobody here wrote a rule for the
malware that was found — which is the entire point.

The pin is a **commit SHA, not a tarball plus `sha256`**. A git SHA *is* a content hash,
so git verifies the checkout by itself, and GitHub's generated tarballs have changed bytes
through recompression before now and broken `sha256` pins doing it.

To bump the version: change `yara_rules_commit` in
[ansible/roles/yara/defaults/main.yml](../ansible/roles/yara/defaults/main.yml) and re-run
`make agent HOSTS=<pattern>`. Nothing else. The local rules live in a separate directory
so a bump can never delete them.

### Own rules

Drop a `.yar` file into
[ansible/roles/yara/files/rules.local/](../ansible/roles/yara/files/rules.local/) and
re-run the role. It is copied to the agent, added to `index.yar`, and **compile-checked at
deploy time** — a `.yar` with a syntax error copies perfectly and then fails on every scan
silently, inside active response, where nobody is looking. `tasks/verify.yml` compiles each
file against `/dev/null` and fails the play naming the file.

Only one rule ships today: `WAZUH_Canary_ChainTest`, the chain self-test.

---

## Rules and decoders

Range 110000–110099. Wazuh reserves 100000 and above for user rules; below that the IDs
belong to the factory ruleset and an upgrade would overwrite them.

| ID | Level | Fires on |
|---|---|---|
| `110000` | 0 | Container. Everything `decoded_as wazuh-yara` — raises nothing itself |
| `110001` | **12** | **A file on disk matches a signature.** The alert that matters |
| `110002` | 5 | The canary matched — chain self-test passed, not malware |
| `110003` | 3 | A scan was skipped (size ceiling, or lock held) |
| `110004` | **13** | **A RUNNING process matches a signature.** MITRE T1620 |
| `110010` | 12 | 8+ new binaries in system paths within 120s — the create/delete pattern |
| `110011` | 10 | Change under `/lib/*.so`, `/etc/init.d/`, `/etc/rc*.d/` — persistence paths |

`110004` sits **above** `110001`, and the difference is not cosmetic: a file on disk can be
an inert leftover of an already contained infection, but a live process matching a
signature is acting right now.

Two details in there are load-bearing and easy to get wrong:

- **`110001` requires the `yara_file` field.** The memory line
  `INFO - Memory scan result: ...` contains the substring `Scan result:`. Without
  anchoring the decoder *and* requiring `yara_file` (which the process decoder does not
  set), the level 12 rule swallows the level 13 events.
- **`110001` excludes the canary** with `^(?!WAZUH_Canary_).+`. Without that, every chain
  test produces a level 12 alert indistinguishable from a genuine finding, which is the
  fastest way to teach a team to ignore level 12 alerts.

An invalid `local_rules.xml` stops `wazuh-analysisd` from starting, and then the manager
processes **nothing** — no alerts, no FIM — with the failure arriving at the next restart,
possibly days after the deploy that caused it. So
[`custom_rules.yml`](../ansible/roles/wazuh_stack/tasks/custom_rules.yml) puts three
barriers in front of it: XML well-formedness on the host, `wazuh-analysisd -t` inside the
container, and a `rescue` block that withdraws the files so the manager can still start
before failing loudly.

---

## Turning it on

**Two switches, on purpose.**

```yaml
# ansible/inventory/group_vars/<group>.yml  — or per host in the inventory
yara_enabled: true                  # install the scanner on these agents
```

```yaml
# ansible/inventory/group_vars/all/vars.yml — manager side
wazuh_yara_active_response: true    # let the manager request scans
```

Then:

```bash
make agent HOSTS=<pattern>      # installs yara, rules, both scripts
make configure                  # manager: decoder, rules, active-response block
```

They are separate because the manager must not request scans on agents where YARA is not
installed, and — more importantly — because **active response runs a scan as root on every
FIM event that gets past the guards**. On the compromised host that would have been 910
scans in three hours on a machine already at 275% CPU. Nothing here is enabled because it
happens to be available; it is enabled per host, once someone has decided that host can
afford it.

`yara_enabled` defaults to `false` and `wazuh_yara_active_response` defaults to `false`.

### The three guards

The manager can only express the first one. The other two live in the script, because
`<active-response>` has no way to say them.

| Guard | Where | What it stops |
|---|---|---|
| `<rules_id>550,554</rules_id>` | `wazuh_manager.conf.j2` | Any alert at all triggering a scan |
| Path allowlist (`yara_scan_paths`) | `yara.sh` | A `git clone` under `/home` launching hundreds of root scans |
| Size ceiling (`yara_max_file_size_kb`) | `yara.sh` | Scanning a 2 GB disk image |
| `flock -n` + `timeout` | `yara.sh` | A burst of events overlapping scans |

`flock -n` **fails immediately rather than waiting**, and that is the point: in a burst the
overlapping scans should be *dropped*, not queued. Queuing them is what turns a burst into
an outage, because each one compiles 902 rules.

---

## Scheduling the sweep

**This project does not schedule the sweep.** It installs the script and runs it on demand:

```bash
make yara-scan HOSTS=web01
make yara-scan HOSTS=web01 PATHS="/lib /usr/bin"
```

Findings do not come back through Ansible's output — the playbook launches the script with
`async`/`poll: 0` and returns. They arrive through Wazuh's own pipeline, as rule `110001`
and `110004` alerts in the dashboard, and on the host in `/var/ossec/logs/yara-scan.log`.

Scheduling is left to the operator deliberately: a recursive sweep reads thousands of
files, and how often that is acceptable is a per-host decision nobody should make on your
behalf. Three ways to do it, in the order they should be considered:

### 1. systemd timer on the agent (recommended)

Per host, survives reboots, and `systemctl list-timers` shows you the schedule and the
last result — which cron does not.

```ini
# /etc/systemd/system/yara-sweep.service
[Unit]
Description=YARA sweep (wazuh-siem-iac)
After=wazuh-agent.service

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/var/ossec/active-response/bin/yara-scan.sh
```

```ini
# /etc/systemd/system/yara-sweep.timer
[Unit]
Description=Daily YARA sweep

[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now yara-sweep.timer
systemctl list-timers yara-sweep.timer
```

`RandomizedDelaySec` matters once there is more than one agent: without it every host in
the estate starts its sweep at the same second, and they all report into the same manager.
`Persistent=true` runs a missed sweep after a host comes back up.

The script already carries its own `flock`, so a timer firing while a sweep is running logs
`Sweep skipped: another sweep already running` and exits — it will not pile up.

### 2. cron on the agent

Equivalent, less observable. Use it if the host has no systemd.

```cron
17 3 * * *  /var/ossec/active-response/bin/yara-scan.sh
```

### 3. cron on the control node

```cron
0 4 * * *  cd /path/to/wazuh-siem-iac && make yara-scan HOSTS=wazuh_agents
```

The one advantage: the schedule stays in one place, in the repo's terms. The disadvantage
is that it needs the control node up, its SSH keys, and the vault passphrase — a
scheduled job that needs an interactive secret is a scheduled job that stops working.

### Why not a Wazuh `wodle command`

It looks like the natural answer — Wazuh can schedule commands on agents itself — and it is
the wrong place *in this project*, for a structural reason worth understanding:
`agent.conf` is rendered **per group by the manager**, while `yara_enabled` is a **per-host**
decision. A wodle in the shared `agent.conf` would run the sweep on every agent in the
group, including ones where YARA was never installed. Putting it in the agent's *local*
`ossec.conf` would be per-host and correct, but that file is the package default here,
edited surgically for the manager address only — adding XML surgery to it buys nothing a
systemd timer does not already give you, and costs a fragile edit.

---

## Verifying the chain

Five hops, any of which can break silently. Do not test with malware; use the canary.

```bash
# on the agent
printf 'WAZUH_YARA_CANARY_a7f3e1' | sudo tee /usr/bin/canary-test >/dev/null
```

Then, in order — and the order is the diagnosis:

| Check | Where | If it is missing |
|---|---|---|
| Rule 554 fired | dashboard, or `/var/ossec/logs/alerts/alerts.json` on the manager | FIM does not watch that path, or the agent is not reporting |
| `Scan result: WAZUH_Canary_ChainTest` | `/var/ossec/logs/active-responses.log` on the agent | The manager never dispatched the active response — see below |
| Rule 110002, level 5 | dashboard | The decoder does not match, or logcollector is not reading the log |

```bash
sudo rm /usr/bin/canary-test        # clean up; there is nothing to revert
```

The string is deliberately improbable so it never matches a legitimate binary by accident,
and the rule is level 5 rather than 12 so a self-test never looks like an incident.

To test only the second half of the chain — script, decoder, rules — without depending on
active response dispatch:

```bash
make yara-scan HOSTS=<host> PATHS="/usr/bin"
```

That runs the sweep directly and should produce the same `110002` alert.

---

## What this cost, measured

Numbers from the compromised host, because guesses are not useful here.

| | |
|---|---|
| Sweep of `/usr`, `/lib`, `/etc/init.d`, `/tmp`, `/var/tmp`, `/dev/shm` | 23,049 files |
| Time for one `yara --scan-list` pass over 21,732 of them | **3 seconds** |
| Disk matches | 3 (`/usr/bin/dmbnwiyxaa`, `/usr/bin/hqqjdcvydx`, `/usr/lib/libudev.so`) |
| Process matches | including `/usr/bin/mskgdnhkdv (deleted) [pid 77990]` |
| False positives across all of it | **0** |
| Rule set on disk | ~7 MB checkout, 902 rules in one file |

Two findings behind those three seconds, both of which were bugs first:

- **`--scan-list`, not one invocation per file.** The first version looped
  `yara ... "$f"` over `find` output, and every invocation recompiles all 902 rules. A
  sweep of `/usr/lib` ran past ten minutes and was still going. With `--scan-list` yara
  compiles once and walks the list.
- **`readlink -f` before `find`.** On merged-`/usr` distros `/lib`, `/bin` and `/sbin` are
  *symlinks*. `find` does not follow symlinks, so `find /lib -type f` returns **nothing** —
  the sweep reported "0 files scanned" for a directory containing the implant. Resolving
  and then deduplicating the target list fixes it.

And one that cost an agent: **`realtime` on `/usr/lib`** — 21,704 files, one inotify watch
each plus MD5+SHA1+SHA256 on every change — overflowed the agent's queue
(`Target 'agent' message queue is full (1024)`), at which point the agent stops sending
*everything*, not just FIM events, and shows as `Disconnected` on the manager with all its
processes alive. `/lib,/usr/lib` is now watched by the scheduled scan only; realtime is
reserved for small high-value trees like `/etc/init.d`. `client_buffer.queue_size` was
also raised to 16384.

---

## Known limitations

Read this before relying on any of the above. Both items are open.

### 1. Active response dispatch is unreliable

**Symptom.** The manager fires the active response on the agent inconsistently. The canary
chain has been observed working end to end — rule `110002` twice — and then the same test
on the same host produces alert 554 with no scan on the agent at all.

**What is known.** `active-responses.log` on the agent shows nothing for the missed
attempts, so the script is not running and failing; it is not being launched.
`ar.conf` is present and correct on the agent, and `wazuh-execd` is running. The
`<active-response>` block validates and the manager restarted cleanly.

**What has not been done.** Confirming from the manager side whether the dispatch is
actually sent, which needs `execd.debug=2` in the manager's `internal_options.conf` and a
correlated read of both sides' logs.

**Impact and workaround.** Path A cannot be treated as a reliable control. Path B — the
sweep — is deterministic and has been verified repeatedly, so **use the sweep as the
control and treat active response as an accelerator**, not the other way round. The
detection content (rules, decoders, scripts) is the same for both, so nothing is lost but
latency.

### 2. A rooted host cannot be reliably monitored from inside itself

The compromised agent goes `Disconnected` roughly 7–8 minutes after every restart, with:

```
Authentication error. Wrong key or corrupt payload
```

The agent's and manager's `rids` counters were cleared on both sides. **That did not fix
it.** A stale `remoted` session (`Agent key already in use`) was also cleared, and did not
fix it either. Meanwhile a second internet-facing agent with an *identical* configuration,
enrolled the same way over the same tunnel, has been flawless throughout.

The difference between the two hosts is not the configuration; it is that one of them is
still compromised. Persistence survived a reboot and added two further generations —
four `/etc/init.d` entries plus `S90` links across `rc1`–`rc5`. The conclusion, stated
plainly because it is the operationally important one: **the answer to that host is a
rebuild, not more monitoring.** An agent's reports are only worth what the host's
integrity is worth, and the level 13 process alerts it did manage to send were the
evidence for the rebuild, not a substitute for it.

### 3. Rules are not tuned against a package upgrade

`110010` (8 new binaries in system paths within 120s) will fire during a large
`apt upgrade`. The thresholds are a starting point chosen from the incident's shape, not a
measured baseline; `ignore="600"` stops it looping. Watch a full upgrade cycle on each host
before treating it as high-confidence. A false positive during an upgrade is acceptable —
missing the real pattern is not.

### 4. Active response is a privileged execution path

Worth stating as a trust boundary rather than a bug: `<active-response>` lets the manager
run a script **as root on any agent**. A compromised manager therefore has root execution
across the whole estate. `yara.sh` is written accordingly — it reads a file and runs yara;
it does not delete, does not kill processes and does not touch the network — but the
capability itself is the exposure, not the script.

---

## Files

| Path | Role |
|---|---|
| [ansible/roles/yara/](../ansible/roles/yara/) | Everything agent-side |
| [`defaults/main.yml`](../ansible/roles/yara/defaults/main.yml) | Every knob, with the reasoning |
| [`tasks/rules.yml`](../ansible/roles/yara/tasks/rules.yml) | Pinned fetch on the control node, index, provenance |
| [`tasks/verify.yml`](../ansible/roles/yara/tasks/verify.yml) | Compile-check at deploy time |
| [`templates/yara.sh.j2`](../ansible/roles/yara/templates/yara.sh.j2) | Active response script — the three guards |
| [`templates/yara-scan.sh.j2`](../ansible/roles/yara/templates/yara-scan.sh.j2) | Sweep, disk + `/proc` |
| [`files/rules.local/`](../ansible/roles/yara/files/rules.local/) | Own rules — add yours here |
| [`local_rules.xml.j2`](../ansible/roles/wazuh_stack/templates/local_rules.xml.j2) | Rules 110000–110011 |
| [`local_decoder.xml.j2`](../ansible/roles/wazuh_stack/templates/local_decoder.xml.j2) | The four decoders |
| [`custom_rules.yml`](../ansible/roles/wazuh_stack/tasks/custom_rules.yml) | Validation and rollback |

See also [TROUBLESHOOTING.md](TROUBLESHOOTING.md) and
[ARCHITECTURE.md](ARCHITECTURE.md).
