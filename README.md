# xboard-node

Node backend for [Xboard](https://github.com/cedar2025/Xboard). Supports `sing-box` / `xray-core` dual kernels.

> **Disclaimer**: This project is for educational and learning purposes only.

## Features

- Protocols: V2Ray family, Trojan, Shadowsocks, Hysteria2, TUIC, AnyTLS
- Sync: WebSocket push + REST polling dual channel
- User controls: speed limit, device limit, alive-IP tracking, hot update
- Deploy modes: node mode, machine mode, standalone mode
- Multi-instance: single process binding multiple panels / nodes

## Install

### Docker

```bash
docker run -d --restart=always --network=host \
  -e apiHost=https://panel.com -e apiKey=TOKEN -e nodeID=1 \
  ghcr.io/sohefan5118-cmd/xboard-node:latest
```

### Docker Compose

```bash
git clone -b compose --depth 1 https://github.com/sohefan5118-cmd/xboard-node.git
cd xboard-node
vim config/config.yml   # set panel.url / token / node_id
docker compose up -d
```

### Installer (Linux systemd)

```bash
# Node mode
curl -fsSL https://raw.githubusercontent.com/sohefan5118-cmd/xboard-node/dev/install.sh | \
  sudo bash -s -- --mode node --panel https://panel.example.com --token TOKEN --node-id 1

# Machine mode
curl -fsSL https://raw.githubusercontent.com/sohefan5118-cmd/xboard-node/dev/install.sh | \
  sudo bash -s -- --mode machine --panel https://panel.example.com --token TOKEN --machine-id 1

## xbctl

Run `xbctl` after installation for help. Common commands:

```bash
xbctl list                          # list all instances
xbctl status                        # running status
xbctl bind add-node --panel URL --token TOKEN --node-id 1
xbctl bind add-machine --panel URL --token TOKEN --machine-id 1
xbctl bind remove-node --panel URL --node-id 1
xbctl service restart
```

## Configuration

Legacy single-panel config is fully compatible. Appending bindings auto-migrates to `instances` format. See `config.yml.example`.

### Cross-node device limits (optional)

To enforce a user's device limit across multiple nodes, point every **sing-box** node at the same private Redis instance. Redis carries only device-admission state; proxy traffic still goes directly through each node and does not pass through the panel or Redis.

YAML configuration:

```yaml
device_claim:
  enabled: true
  type: redis
  addr: "10.0.0.10:6379"
  password: "use-an-environment-variable-in-production"
  db: 0
  prefix: "xboard:device-claim"
  ttl: 300
```

For Docker or systemd, keep the password out of the file and use environment variables:

```bash
export DEVICE_CLAIM_ENABLED=true
export DEVICE_CLAIM_ADDR=10.0.0.10:6379
export DEVICE_CLAIM_PASSWORD='replace-with-redis-password'
```

Restrict Redis to the node private network/firewall. Do not expose Redis publicly. The Redis instance should be shared by nodes that enforce the same panel's device limits; use a different `DEVICE_CLAIM_PREFIX` for unrelated panels.

### One-command deployment for every node

Run the same installer on A, B, C, or any later node. It tests the shared
Redis first, installs the node, atomically enables Redis device claims,
restarts the service, and fails if the service is not healthy. Set a unique
`IDENT` for each panel binding and use the same Redis and claim prefix on
every node:

```bash
curl --fail --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/sohefan5118-cmd/xboard-node/dev/oneclick-install.sh |
sudo env NONINTERACTIVE=1 MODE=machine \
  PANEL='https://panel.example.com' TOKEN='machine-token' IDENT='4' \
  REDIS_ADDR='10.66.0.1:6379' REDIS_PASS='redis-password' \
  CLAIM_TTL=300 CLAIM_PREFIX='xboard:device-claim' bash
```

For a node binding, use `MODE=node` and `IDENT` as the node ID. For every
additional node, run the same command with its own `TOKEN` and `IDENT`; the
cross-node restriction is enforced by shared Redis, not by a person or an
approval step. Prefer a protected environment file over inline secrets to
avoid shell history and process-list exposure.

## Extensions

- Custom routes: [docs-custom-routes.md](docs-custom-routes.md)
- Custom outbounds: [docs-custom-outbounds.md](docs-custom-outbounds.md)
- DNS providers (ACME DNS-01): [docs-dns-providers.md](docs-dns-providers.md)

## License

MPL-2.0.
