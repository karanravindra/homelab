# homelab

Docker Compose setup for my homelab.

## Services

| Service | URL | Notes |
| --- | --- | --- |
| Traefik | `http://localhost:8081` (dashboard) | Reverse proxy, wildcard Let's Encrypt cert via Cloudflare DNS challenge |
| AdGuard Home | `https://adguard.<DOMAIN>` | DNS on :53, first-run setup at `:3000` |
| Beszel (hub + agent) | `https://beszel.<DOMAIN>` | Server monitoring; agent needs `BESZEL_KEY` from the hub |
| Home Assistant | `https://ha.<DOMAIN>` | Host networking; routed via `config/traefik/homeassistant.yml` |
| News (orbit-news) | `https://news.<DOMAIN>` | web + worker + Postgres/pgvector + Redis; image from GHCR, needs Ollama on the host |
| Samba | `smb://<host>/storage` | Shares `STORAGE_PATH` on :445 |

## Setup

```sh
cp .env.example .env   # fill in ACME_EMAIL and CF_DNS_API_TOKEN
docker compose up -d
```

Point `adguard.<DOMAIN>` (and any future subdomains) at the host's LAN IP.

## Scripts

Plain `sh`; run them from anywhere.

| Script | What it does |
| --- | --- |
| `scripts/update.sh` | `git pull`, merge new `.env.example` keys into `.env`, stop if a required key is blank, `docker compose pull` + `up -d`, then wait for health. `SERVICE...` limits it; `--no-pull` / `--no-wait` skip steps. |
| `scripts/status.sh` | Health table for every container. Exit `0` ok, `1` down or unhealthy, `2` still starting, `3` could not check. `-q` prints only problems (for cron); `-w SECS` waits for containers that are starting. |
| `scripts/env-sync.sh` | Append keys that are new in `.env.example` to `.env`; never changes existing values. `-n` is a dry run. |
| `scripts/lint-env.sh` | Fails if `.env.example` and the compose files disagree on variables. Needs no Docker; the header shows a pre-commit hook line. |

## Layout

```
compose.yml            # just `include:`s each service
services/traefik.yml
services/adguardhome.yml
services/...          # beszel, homeassistant, samba, news
config/traefik/        # Traefik file-provider routes (tracked)
scripts/               # update, status, env-sync, lint-env
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

## News

Pulls `ghcr.io/karanravindra/orbit-news` (private by default: `docker login ghcr.io` with a PAT
that has `read:packages`, or make the package public). Set `NEWS_POSTGRES_PASSWORD` and
`NEWS_REDIS_PASSWORD` in `.env`, run Ollama on the host with the models from `services/news.yml`, then:

```sh
docker compose pull news-web && docker compose up -d
docker compose run --rm news-web outlets import   # once, loads outlet ratings
```

Roll back with `NEWS_TAG=sha-<old>` in `.env`. Back up with
`docker compose exec news-db pg_dump -U news news > news.sql`.

## Secrets and data

`.env` and `data/` are gitignored.
