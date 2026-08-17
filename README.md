# Technitium DNS Cluster — Operations Guide

A 4-node HA Technitium DNS cluster with 2 floating VRRP VIPs, ad-blocking, Cloudflare DoH forwarding, and split-horizon DNS for `mihirfamily.com`. Deployed August 2025.

---

## Architecture

### Nodes & VIPs

| Node  | IP             | OS                      | Technitium Role |
|-------|----------------|-------------------------|-----------------|
| DNS-A | 192.168.74.241 | Debian 12 (DietPi)      | Primary         |
| DNS-B | 192.168.74.242 | Debian 12 (DietPi)      | Secondary       |
| DNS-C | 192.168.74.243 | Debian 13 (Proxmox LXC) | Secondary       |
| DNS-D | 192.168.74.244 | Debian 13 (Proxmox LXC) | Secondary       |

| VIP   | IP             | VRRP router_id | Normal master | Failover order |
|-------|----------------|----------------|---------------|----------------|
| VIP-A | 192.168.74.240 | 240            | DNS-A         | A > C > B > D  |
| VIP-B | 192.168.74.245 | 245            | DNS-B         | B > D > A > C  |

Both VIPs run on the `eth0` interface in unicast mode (no multicast — works across VLANs and inside Proxmox LXC containers). All 4 nodes run two VRRP instances; failover is automatic when keepalived detects a node down.

### keepalived Overview

Each node's `/etc/keepalived/keepalived.conf` declares two `vrrp_instance` blocks — one for VIP-A (router_id 240) and one for VIP-B (router_id 245) — with different priorities:

| Node  | VIP-A priority | VIP-B priority |
|-------|---------------|----------------|
| DNS-A | 110 (master)  | 90             |
| DNS-B | 90            | 110 (master)   |
| DNS-C | 100           | 80             |
| DNS-D | 80            | 100            |

Unicast peers list all other 3 nodes so VRRP advertisements bypass the LAN's multicast restrictions.

### Technitium Cluster Sync

Zones are managed on **DNS-A only** (the Primary). Changes replicate to B/C/D automatically via the catalog zone `cluster-catalog.dnscluster.home.arpa`. Zone transfer uses Technitium's native DNS Cluster feature (not BIND-style AXFR). Secondary nodes pull from primary within ~2–10 seconds.

**Exception**: server-level settings (block lists, forwarders, logging) are NOT replicated. Apply those to all 4 nodes separately (see scripts below).

### Upstream Forwarding

All recursive queries fall through to **Cloudflare DoH** (`https://cloudflare-dns.com/dns-query`). DNS-over-HTTPS is configured in Technitium's Forwarders settings on each node. No plain-UDP upstream queries leave the network.

### Ad-Blocking

Block lists loaded on all 4 nodes, auto-updated every 24 hours:
- StevenBlack consolidated hosts: `https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts`
- OISD Small: `https://small.oisd.nl`

### Router Integration (Orbi RBR750)

The Netgear Orbi (192.168.74.1) acts as a DNS proxy: its WAN DNS is set to VIP-A (primary) and VIP-B (secondary). DHCP clients receive the Orbi's IP as their DNS server; the Orbi forwards all queries to the VIPs.

- **Primary DNS (Orbi WAN):** 192.168.74.240
- **Secondary DNS (Orbi WAN):** 192.168.74.245
- DHCP clients cannot be pushed VIP addresses directly — the Orbi RBR750 firmware doesn't expose DHCP DNS server configuration in its UI, and the backup config is encrypted binary. The proxy approach is the supported workaround for this hardware.

---

## DNS Zones

### `lan` — LAN device A records

Primary authoritative zone for internal hostnames. Replicated to all nodes.

| Hostname                      | IP              |
|-------------------------------|-----------------|
| brother-printer.lan           | 192.168.74.12   |
| sonoff.lan                    | 192.168.74.20   |
| appolo-42.lan                 | 192.168.74.42   |
| appolo-43.lan                 | 192.168.74.43   |
| appolo-68.lan                 | 192.168.74.68   |
| amcrest-familyroom.lan        | 192.168.74.72   |
| amcrest-masterbedroom.lan     | 192.168.74.111  |
| esp32c3.lan                   | 192.168.74.159  |

### `74.168.192.in-addr.arpa` — Reverse DNS (PTR records)

PTR records exist for all `.lan` hostnames above plus any other statically registered hosts. Replicated to all nodes.

To check: `dig -x 192.168.74.12 @192.168.74.240`

### `mihirfamily.com` — Split-horizon overrides

**Forwarder zone** (not authoritative). Any record defined here overrides the public answer for LAN clients; everything else falls through to Cloudflare DoH and returns the real public record. Only add overrides here if you actually want LAN traffic to hit a local IP instead of the public one.

Current overrides:

| Name                              | Local IP       |
|-----------------------------------|----------------|
| unraid.mihirfamily.com            | 192.168.74.7   |
| proxmox.mihirfamily.com           | 192.168.74.13  |
| homeassistant.mihirfamily.com     | 192.168.74.11  |

### `dnscluster.home.arpa` — Cluster internal zone

Used for cluster node naming and TSIG. Don't touch this by hand.

---

## Common Tasks

**Make changes on DNS-A only.** Changes replicate automatically.

SSH aliases: `ssh DNS-A`, `ssh DNS-B`, `ssh DNS-C`, `ssh DNS-D` (root, key-based).

### Add a DNS record (A + PTR together)

```bash
ssh DNS-A bash -s <<'EOF'
TOKEN=$(curl -s "http://127.0.0.1:5380/api/user/login?user=admin&pass=TechDNS%23Cluster2025&includeInfo=true" | jq -r .token)
HOST=mydevice
IP=192.168.74.X
OCTET=$(echo $IP | cut -d. -f4)

curl -s "http://127.0.0.1:5380/api/zones/records/add?token=$TOKEN&zone=lan&domain=${HOST}.lan&type=A&ttl=3600&ipAddress=$IP"
curl -s "http://127.0.0.1:5380/api/zones/records/add?token=$TOKEN&zone=74.168.192.in-addr.arpa&domain=${OCTET}.74.168.192.in-addr.arpa&type=PTR&ttl=3600&ptrName=${HOST}.lan"
EOF
```

### Add a split-horizon override (mihirfamily.com)

```bash
ssh DNS-A bash -s <<'EOF'
TOKEN=$(curl -s "http://127.0.0.1:5380/api/user/login?user=admin&pass=TechDNS%23Cluster2025&includeInfo=true" | jq -r .token)
curl -s -G "http://127.0.0.1:5380/api/zones/records/add" \
  --data-urlencode "token=$TOKEN" \
  --data-urlencode "domain=NEWNAME.mihirfamily.com" \
  --data-urlencode "zone=mihirfamily.com" \
  --data-urlencode "type=A" \
  --data-urlencode "ipAddress=192.168.74.X" \
  --data-urlencode "ttl=300"
EOF
```

### Allow-list a domain (override a blocked site)

Uses the bundled script — handles all 4 nodes and flushes cache:

```bash
export TECH_PASS='TechDNS#Cluster2025'
./technitium-allow-sync.sh add somedomain.com      # whitelist
./technitium-allow-sync.sh remove somedomain.com   # re-block
./technitium-allow-sync.sh list                    # show current allow list on all nodes
```

### Update block lists across all nodes

```bash
for h in DNS-A DNS-B DNS-C DNS-D; do
  ssh "$h" bash -s <<'EOF'
TOKEN=$(curl -s "http://127.0.0.1:5380/api/user/login?user=admin&pass=TechDNS%23Cluster2025&includeInfo=true" | jq -r .token)
curl -s -G "http://127.0.0.1:5380/api/settings/set" \
  --data-urlencode "token=$TOKEN" \
  --data-urlencode "blockListUrls=https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts,https://small.oisd.nl" \
  --data-urlencode "blockListUpdateIntervalHours=24"
curl -s "http://127.0.0.1:5380/api/settings/forceUpdateBlockLists?token=$TOKEN" > /dev/null
EOF
done
```

Note: `blockListUrls` is the full replacement list — include every URL you want, not just new ones.

---

## Health Checks

```bash
# Which node holds each VIP right now?
for h in DNS-A DNS-B DNS-C DNS-D; do echo -n "$h: "; ssh "$h" "ip -4 -br addr show eth0"; done

# End-to-end resolution test
dig @192.168.74.240 homeassistant.mihirfamily.com A   # should return 192.168.74.11
dig @192.168.74.245 doubleclick.net A                 # should be NXDOMAIN (blocked)
dig @192.168.74.240 google.com A                      # should resolve via Cloudflare DoH
dig -x 192.168.74.72 @192.168.74.240                  # PTR for amcrest-familyroom

# keepalived status on a node
ssh DNS-A systemctl status keepalived

# Technitium service health
ssh DNS-A systemctl status technitium-dnsserver
```

Web console: `http://192.168.74.240:5380` or `http://192.168.74.245:5380` (login: `admin`).

---

## Known Quirks

- **Propagation lag**: Zone changes take 2–10 s to fully replicate and take effect. Retry a `dig` if the first result looks stale.
- **Cached answers linger**: Re-blocking a recently-allowed domain requires a cache flush. The allow-sync script does this automatically; manual API changes don't.
- **OISD Small flakiness**: `oisd.nl` has had occasional outages where the block list fails to download. Technitium keeps the last good copy and retries. Check the Blocking page in the console if you suspect it.
- **Kernel updates (DNS-A/B)**: `apt-get upgrade` holds back `linux-image-amd64`. To apply: `apt-get install linux-image-amd64` then reboot. DNS-C/D are LXC containers and share the Proxmox host kernel.
- **openssh upgrades in LXC (DNS-C/D)**: You may see `Could not execute systemctl` — this is cosmetic. SSH restarts fine; verify with `systemctl status ssh` before assuming you're locked out.
- **Rolling changes**: For changes touching all 4 nodes (keepalived config, OS upgrades), do one node at a time and verify VIP failover before continuing.
- **Orbi DNS proxy**: LAN clients always query the Orbi (192.168.74.1); the Orbi forwards to the VIPs. DNS traffic is Orbi → VIP, not client → VIP directly. DHCP DNS field is not configurable on the RBR750 firmware.

---

## Access Reference

| Resource               | URL / Address                         | Credential          |
|------------------------|---------------------------------------|---------------------|
| Technitium web console | http://192.168.74.240:5380 (VIP-A)    | admin / (see vault) |
| Technitium web console | http://192.168.74.245:5380 (VIP-B)    | admin / (see vault) |
| Technitium API login   | `GET /api/user/login?user=admin&pass=` | URL-encode password |
| SSH into any node      | `ssh DNS-A` / `DNS-B` / `DNS-C` / `DNS-D` | root, key-based |
| Orbi router            | http://192.168.74.1                    | (see vault)         |
