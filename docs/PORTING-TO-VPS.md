# Moving this to a VPS

The project is structured so this is a bounded change rather than a rewrite. Work through
it in order — each section depends on the one before.

---

## 1. Swap the VM module

`modules/libvirt-vm` exposes a deliberately small contract:

```
ip_address    hostname    fqdn    ssh_user
```

Nothing downstream knows libvirt is involved. `local_file.ansible_inventory` consumes
those four outputs and the entire Ansible layer consumes the inventory.

So a cloud VM module that emits the same four names is a drop-in replacement. For Hetzner:

```hcl
module "wazuh_server" {
  source = "./modules/hcloud-vm"

  vm_name    = var.vm_name
  server_type = "cx32"          # 4 vCPU / 8 GiB — comfortable for Wazuh
  image      = "debian-13"
  location   = "nbg1"

  ssh_public_key = local.ssh_public_key
  admin_username = var.admin_username
  timezone       = var.timezone
}
```

Write that module with `outputs.tf` naming `ip_address`, `hostname`, `fqdn` and `ssh_user`,
delete the `libvirt_network` resource, and `main.tf` is done. Keep the same
`user-data.yaml.tftpl` — cloud-init is cloud-init, and every serious provider supports the
NoCloud/user-data path.

**What disappears with libvirt:** the DHCP reservation. A cloud VM's address comes from the
provider, so `ip_address` becomes a real computed output instead of a value you assert. If
you want it stable across rebuilds, attach a floating IP and output that instead.

**What disappears from the module:** all the domain-XML correctness work — `features`,
`cpu`, `serials`, `channels`, `rngs`. Those are libvirt's problem, not a cloud provider's.
You lose `make console` too; use the provider's web console.

---

## 2. Move the state

Local state has no locking and no history. As soon as more than one thing can run
Terraform — you and CI, or you on two machines — you need a remote backend.

`terraform/backend.tf` has the target configuration written out and commented. Uncomment
one, then:

```bash
terraform -chdir=terraform init -migrate-state
```

Terraform copies the local state up and switches over in one step.

Non-negotiable properties of whatever you choose:

- **Encryption at rest.** State holds every resource attribute in plaintext.
- **Locking.** For S3 that is `use_lockfile = true`; the old DynamoDB table is no longer
  needed.
- **Versioning.** Object versioning is your only undo for a bad apply.

And confirm `*.tfstate` is still gitignored *before* the first push, not after. A state
file in git history is a credential leak that requires a history rewrite to fix.

---

## 3. Close the ports

**This is the step that matters most, and the lab's configuration is actively wrong for a
public host.**

The lab publishes 443, 1514, 1515, 514/udp and 55000 on all interfaces. On a NAT network
that is fine — nothing can route to it. On a VPS every one of those is exposed to the
internet, and `ufw` **will not** stop it: Docker's rules are traversed before ufw's, so a
published port bypasses the policy entirely.

Decide, per port:

| Port | On a VPS |
|---|---|
| 443 dashboard | Public, behind a real TLS certificate (see §4) |
| 1514/1515 agents | Public only if agents are off-host. Otherwise bind to the private network |
| 514/udp syslog | Bind to the private network. An open syslog port on the internet is an invitation |
| 55000 API | **Never public.** Only the dashboard needs it, over the compose network |
| 9200 indexer | **Never public.** Already unpublished by default here |

Bind explicitly rather than trusting the firewall:

```yaml
ports:
  - "127.0.0.1:55000:55000"      # loopback only
  - "10.0.0.5:1514:1514"         # private network only
```

Then pick one of these so ufw actually applies to what remains:

- put the container ports on loopback and a reverse proxy in front — simplest and best;
- write rules into the `DOCKER-USER` chain, which *is* traversed before Docker's;
- set `"iptables": false` in `/etc/docker/daemon.json` and manage forwarding yourself —
  understand the consequences first.

Also add SSH rate limiting and fail2ban, neither of which the lab bothers with.

---

## 4. Real TLS

The lab's dashboard serves a certificate from the private CA that
`wazuh-certs-generator` creates. Your browser will never trust it, and you should not try
to make it.

Leave the internal certificates alone — manager↔indexer and dashboard↔indexer TLS is
working correctly and depends on those container-hostname certificates. Terminate
browser-facing TLS in front of the dashboard instead:

```
Browser ──HTTPS (Let's Encrypt)──▶ Caddy/nginx ──HTTPS (private CA)──▶ wazuh.dashboard
```

Caddy is the least work — it obtains and renews certificates by itself. Point it at
`https://127.0.0.1:5601` with certificate verification relaxed for the internal hop only.

---

## 5. Secrets in CI

`--ask-vault-pass` does not work unattended. Options, best first:

1. **A secrets manager.** Read the vault password from Vault/AWS Secrets Manager/SOPS at
   run time and pass `--vault-password-file /dev/fd/…`. Nothing durable on disk.
2. **A CI secret.** Write it to a temp file, `chmod 600`, pass
   `--vault-password-file`, delete it in a `trap`. Every mainstream CI encrypts secrets at
   rest and masks them in logs.

`make configure VAULT_PASS_FILE=path` already supports the file form.

Rotate the Wazuh passwords when you migrate. Anything that existed on a laptop should not
be what protects a public host.

---

## 6. Sizing

Reconsider what the lab's constraints forced:

| Setting | Lab | VPS |
|---|---|---|
| RAM | 4096 MiB (the floor) | 8192 MiB |
| `wazuh_indexer_heap` | `1g` | `2g` — roughly half of RAM, never above 32 GiB |
| Swapfile | 2 GiB, load-bearing | Keep it, but it should stay unused |
| `cluster.routing.allocation.disk.threshold_enabled` | `false` (upstream) | **`true`** — you want the indexer to stop writing before it fills the disk |
| Index retention | none | Set an ISM policy. Alerts accumulate indefinitely otherwise |

That last row is the one that bites people six weeks in.

---

## 7. Environments

Once local and VPS both exist, you need to keep them apart. Two conventions:

**Directory per environment** — duplicated root modules, complete isolation, different
backends per environment. Verbose, and the industry default for anything with a production
environment.

**Workspaces** — one root module, `terraform workspace select`. Less duplication, but a
single backend and one careless `select` away from applying to the wrong place.

For this project: keep the single root module and add `env/local.tfvars` and
`env/vps.tfvars`, invoked with `-var-file`. It is the lightest thing that stays correct,
and there is no ambiguity about which environment you are touching because you name it on
every command.

---

## Checklist

- [ ] `modules/hcloud-vm` (or equivalent) emits `ip_address`, `hostname`, `fqdn`, `ssh_user`
- [ ] `libvirt_network` removed; stable address via a floating IP if needed
- [ ] State migrated to a remote backend with encryption, locking and versioning
- [ ] `*.tfstate` confirmed gitignored before the first push
- [ ] 55000 and 9200 bound to loopback or the private network
- [ ] 514/udp not internet-facing
- [ ] Firewall rules in `DOCKER-USER`, or ports on loopback behind a proxy
- [ ] Reverse proxy with a real certificate in front of the dashboard
- [ ] `fail2ban` and SSH rate limiting
- [ ] Vault password supplied non-interactively from a secrets manager
- [ ] Wazuh passwords rotated for the new environment
- [ ] Indexer heap raised; disk watermarks **enabled**
- [ ] Index retention (ISM) policy configured
- [ ] Backups of the indexer volume, and a restore you have actually tested
