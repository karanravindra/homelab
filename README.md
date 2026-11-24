# homelab

Docker Compose setup for my homelab.

## Services

| Service | URL | Notes |
| --- | --- | --- |
| Traefik | `http://localhost:8081` (dashboard) | Reverse proxy, wildcard Let's Encrypt cert via Cloudflare DNS challenge |
| AdGuard Home | `https://adguard.<DOMAIN>` | DNS on :53, first-run setup at `:3000` |
| Beszel (hub + agent) | `https://beszel.<DOMAIN>` | Server monitoring; agent needs `BESZEL_KEY` from the hub |
| Home Assistant | `https://ha.<DOMAIN>` | Host networking; routed via `config/traefik/homeassistant.yml` |
| Samba | `smb://<host>/storage` | Shares `STORAGE_PATH` on :445 |

## Setup

```sh
cp .env.example .env   # fill in ACME_EMAIL and CF_DNS_API_TOKEN
docker compose up -d
```

Point `adguard.<DOMAIN>` (and any future subdomains) at the host's LAN IP.

## Layout

```
compose.yml            # just `include:`s each service
services/traefik.yml
services/adguardhome.yml
services/...          # beszel, homeassistant, samba
config/traefik/        # Traefik file-provider routes (tracked)
data/                  # service volumes (gitignored)
```

Each service lives in its own file under `services/`. Relative paths in an included
file resolve from `services/`, so volumes use `../data/<service>/...`. `.env` at the
repo root is shared by all of them.

## Adding a service

Create `services/myapp.yml` with Traefik labels, then add `- services/myapp.yml` to the
`include:` list in the root `compose.yml`:

```yaml
labels:
  - traefik.enable=true
  - traefik.http.routers.myapp.rule=Host(`myapp.${DOMAIN}`)
  - traefik.http.routers.myapp.entrypoints=websecure
  - traefik.http.routers.myapp.tls=true
  - traefik.http.services.myapp.loadbalancer.server.port=8080
```

The wildcard cert covers it automatically. Run a single service with
`docker compose up -d myapp`.

## Secrets and data

`.env` and `data/` are gitignored.
