# Technitium DNS Cluster — Operations Guide

A 4-node HA Technitium DNS cluster with 2 floating VIPs, ad-blocking, Cloudflare
DoH forwarding, and split-horizon DNS for `mihirfamily.com`. This doc covers the
two things you'll do most often: **adding DNS records** and **editing allow/block
lists**. See the bottom for cluster reference info and known quirks.

## Topology

| Node   | IP              | OS                  | Role in Technitium Cluster |
|--------|-----------------|---------------------|------------------------------|
| DNS-A  | 192.168.74.241  | Debian 12 (DietPi)  | Primary                     |
| DNS-B  | 192.168.74.242  | Debian 12 (DietPi)  | Secondary                   |
| DNS-C  | 192.168.74.243  | Debian 13 (Proxmox LXC) | Secondary               |
| DNS-D  | 192.168.74.244  | Debian 13 (Proxmox LXC) | Secondary               |

| VIP    | IP              | Managed by          |
|--------|-----------------|----------------------|
| VIP-A  | 192.168.74.240  | keepalived VRRP (router_id 240), any node can hold it, priority order: A > C > B > D |
| VIP-B  | 192.168.74.245  | keepalived VRRP (router_id 245), any node can hold it, priority order: B > D > A > C |

SSH: `ssh DNS-A` / `DNS-B` / `DNS-C` / `DNS-D` (root, key-based, aliases already
configured in `~/.ssh/config`).

Technitium web console: `https://<any node IP or VIP>:53443/` or
`http://<any node IP or VIP>:5380/` — login with username `admin` and your
Technitium admin password.

All API examples below use `user=admin&pass=<TECH_ADMIN_PASS>` — substitute
your actual admin password when running them (or export it as an env var,
e.g. `TECH_PASS=...`, and swap it into the `curl` calls).

---

## Adding DNS records manually

There are three zones you'll actually touch. **In all cases, make changes on
DNS-A only** — it's the Primary in Technitium's native DNS Cluster feature, and
changes replicate automatically to B/C/D within a few seconds via the catalog
zone (`cluster-catalog.dnscluster.home.arpa`). Don't edit B/C/D directly; your
change will just get overwritten by the next sync from A.

### 1. `mihirfamily.com` — split-horizon zone (most common case)

This is a **Forwarder zone**, not a full authoritative copy of your public
zone. Any record you explicitly add here is a **local override** served only to
LAN clients. Anything you *don't* add falls through automatically to Cloudflare
DoH and returns the real public answer — so you never need to mirror MX/TXT/etc.

Current overrides:
- `unraid.mihirfamily.com` → 192.168.74.7
- `proxmox.mihirfamily.com` → 192.168.74.13
- `homeassistant.mihirfamily.com` → 192.168.74.11

**Via web console**: Zones → `mihirfamily.com` → Add Record → choose type (A/AAAA/CNAME/etc), enter name + value → Save.

**Via API** (run on DNS-A):
```bash
ssh DNS-A '
TOKEN=$(curl -s "http://127.0.0.1:5380/api/user/login?user=admin&pass=<TECH_ADMIN_PASS>&includeInfo=true" | jq -r ".token")
curl -s -G "http://127.0.0.1:5380/api/zones/records/add" \
  --data-urlencode "token=$TOKEN" \
  --data-urlencode "domain=NEWNAME.mihirfamily.com" \
  --data-urlencode "zone=mihirfamily.com" \
  --data-urlencode "type=A" \
  --data-urlencode "ipAddress=192.168.74.X" \
  --data-urlencode "ttl=300"
'
```
Replace `NEWNAME` and the IP. To remove an override later, use
`api/zones/records/delete` with the same `domain`/`type`/`ipAddress` params.

⚠️ Only add a record here if you actually want to **override** what the public
internet sees for that name. If you add a record for a name that already has
a real public record you didn't mean to touch, the local one silently wins
for LAN clients — that's by design, but it's easy to forget.

### 2. `dnscluster.home.arpa` — internal cluster domain

Used for the cluster's own internal naming (node hostnames, TSIG key,
etc). You generally shouldn't need to touch this by hand.

### 3. `74.168.192.in-addr.arpa` — reverse DNS (PTR records) for your LAN

Add/edit PTR records here for reverse lookups (IP → hostname) on your
192.168.74.0/24 subnet. Same pattern as above — console or API, on DNS-A only.

### Creating a brand-new zone

If you want to manage a totally different domain locally, decide first:
- **Full authority** (`type=Primary`) — Technitium becomes the sole source of
  truth for the whole domain; anything not defined returns NXDOMAIN. Fine for
  domains with no public presence.
- **Split-horizon** (`type=Forwarder`) — same pattern as `mihirfamily.com`
  above; use this for any domain that also has real public DNS you don't want
  to accidentally shadow.

Either way, after creating it, set its `catalog` to
`cluster-catalog.dnscluster.home.arpa` if you want it to replicate to B/C/D:
```bash
curl -s -G "http://127.0.0.1:5380/api/zones/options/set" \
  --data-urlencode "token=$TOKEN" \
  --data-urlencode "zone=yourzone.com" \
  --data-urlencode "catalog=cluster-catalog.dnscluster.home.arpa"
```

---

## Editing allow/block lists

These are **server-level settings, not zone data** — they do NOT replicate via
the DNS Cluster feature. Every change here needs to be applied to all 4 nodes.

### Block lists (site-wide ad/malware blocking)

Current config: `StevenBlack` hosts list + `OISD Small`, auto-updates every 24h,
applies server-wide to all queries on all 4 nodes/both VIPs.

**Via web console** (repeat on each of DNS-A/B/C/D): Settings → Blocking →
edit the "Block List URLs" field → Save → click "Force Update" to apply
immediately instead of waiting for the 24h cycle.

**Via API**, scripted across all 4 nodes:
```bash
for h in DNS-A DNS-B DNS-C DNS-D; do
  ssh "$h" '
TOKEN=$(curl -s "http://127.0.0.1:5380/api/user/login?user=admin&pass=<TECH_ADMIN_PASS>&includeInfo=true" | jq -r ".token")
curl -s -G "http://127.0.0.1:5380/api/settings/set" \
  --data-urlencode "token=$TOKEN" \
  --data-urlencode "blockListUrls=https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts,https://small.oisd.nl,https://YOUR-NEW-LIST-HERE" \
  --data-urlencode "blockListUpdateIntervalHours=24"
curl -s "http://127.0.0.1:5380/api/settings/forceUpdateBlockLists?token=$TOKEN" > /dev/null
'
done
```
Note: `blockListUrls` is the **full replacement list** — always include every
URL you want, not just the one you're adding.

### Allow list (whitelist a single over-blocked domain)

Use the script — it handles all 4 nodes and flushes each node's DNS cache so
the change is immediate (a bare API call without a flush can leave a stale
cached answer for a bit):

```bash
cd /Users/mihirpatel/synced-ollama-claude-projects/dns-cluster
export TECH_PASS='your-technitium-admin-password'   # set once per shell session
./technitium-allow-sync.sh add somedomain.com        # whitelist it
./technitium-allow-sync.sh remove somedomain.com     # re-block it
./technitium-allow-sync.sh list                      # see current allow list on all 4 nodes
```

If you ever prefer the console instead (you'll need to repeat this on all 4
nodes manually): Zones → Add Zone → check "Add as Allowed Zone" (or similar,
depending on console version) → enter the domain.

---

## Health checks / quick reference

Check which node currently holds each VIP:
```bash
for h in DNS-A DNS-B DNS-C DNS-D; do echo -n "$h: "; ssh "$h" "ip -4 -br addr show eth0"; done
```

Check Technitium cluster node status (run from any node):
```bash
ssh DNS-A '
TOKEN=$(curl -s "http://127.0.0.1:5380/api/user/login?user=admin&pass=<TECH_ADMIN_PASS>&includeInfo=true" | jq -r ".token")
curl -s "http://127.0.0.1:5380/api/user/login?user=admin&pass=<TECH_ADMIN_PASS>&includeInfo=true" | jq -r ".info.clusterNodes[] | \"\(.name): \(.type) - \(.state)\""
'
```

Test resolution end to end (run from anywhere):
```bash
dig @192.168.74.240 homeassistant.mihirfamily.com A   # via VIP-A, should hit local override
dig @192.168.74.245 doubleclick.net A                 # via VIP-B, should be NXDOMAIN (blocked)
dig @192.168.74.240 google.com A                      # should resolve via Cloudflare forwarder
```

---

## Known quirks

- **Propagation lag**: zone and allow-list changes typically take 2–10 seconds
  to fully apply across the cluster / take effect for new queries. Don't
  panic if a `dig` immediately after a change looks stale — wait a few
  seconds and retry.
- **Cached answers linger**: if you re-block a domain that was recently
  allowed (or vice versa), clients (and Technitium's own cache) may keep
  serving the old answer until its TTL expires. The allow-sync script flushes
  cache automatically; if you make changes another way, you may want to hit
  `POST /api/cache/flush` yourself.
- **OISD Small can be flaky**: `oisd.nl` has had outages where the blocklist
  fails to download. Not a config problem — Technitium keeps using the last
  successfully downloaded copy and retries automatically. Check via the
  console's Blocking page or the DNS log (`/var/log/technitium/dns/`) if
  you're unsure whether it's currently loaded.
- **Kernel updates on DNS-A/DNS-B**: a plain `apt-get upgrade` holds back
  `linux-image-amd64` (normal apt behavior for new kernel packages). To
  actually apply it: `apt-get install linux-image-amd64` then reboot. DNS-C/D
  are Proxmox LXC containers and share the host kernel — no kernel package to
  update there.
- **LXC + openssh-server upgrades** (DNS-C/D): you may see `Could not execute
  systemctl` during an `apt upgrade` that touches `openssh-server`. It's a
  transient container/D-Bus quirk — sshd actually does restart fine (confirmed
  via `systemctl status ssh`), just double-check before assuming you're locked
  out.
- **Rolling changes**: for anything that touches all 4 nodes (keepalived
  config, apt upgrades, kernel updates), go one node at a time and verify
  VIP failover + service health before moving to the next, rather than doing
  all 4 simultaneously.
