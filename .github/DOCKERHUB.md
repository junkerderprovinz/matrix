<a href="https://matrix.org">
  <img src="https://raw.githubusercontent.com/junkerderprovinz/matrix/main/.github/assets/matrix-banner.png" alt="Matrix" width="100%">
</a>

<p align="center">
  <a href="https://github.com/junkerderprovinz/matrix/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/junkerderprovinz/matrix/build.yml?branch=main&label=Build&style=for-the-badge&logo=githubactions&logoColor=white" alt="Build" height="36"></a>&nbsp;
  <a href="https://hub.docker.com/r/junkerderprovinz/matrix"><img src="https://img.shields.io/docker/pulls/junkerderprovinz/matrix?style=for-the-badge&logo=docker&logoColor=white&label=Pulls&color=1d99f3" alt="Docker Pulls" height="36"></a>&nbsp;
  <a href="https://hub.docker.com/r/junkerderprovinz/matrix"><img src="https://img.shields.io/docker/image-size/junkerderprovinz/matrix/latest?style=for-the-badge&logo=docker&logoColor=white&label=Size&color=1d99f3" alt="Image Size" height="36"></a>&nbsp;
  <a href="https://github.com/junkerderprovinz/matrix"><img src="https://img.shields.io/badge/Arch-amd64%20%7C%20arm64-success?style=for-the-badge&logo=linux&logoColor=white" alt="Arch" height="36"></a>&nbsp;
  <a href="https://github.com/element-hq/synapse"><img src="https://img.shields.io/badge/Synapse-homeserver-0dbd8b?style=for-the-badge&logo=matrix&logoColor=white" alt="Synapse" height="36"></a>&nbsp;
  <a href="https://element.io"><img src="https://img.shields.io/badge/Element-web%20client-0dbd8b?style=for-the-badge&logo=element&logoColor=white" alt="Element" height="36"></a>
</p>

<p align="center">
A complete, plug-and-play Docker image for running your own <b>Matrix homeserver</b> on Unraid.
No manual config file editing, no SSH access to the container required —
just enter your domain and database credentials and the container handles the rest.
</p>

## What is this?

A **wrapper around the official Synapse image** from Element (`ghcr.io/element-hq/synapse`) that adds everything a working homeserver needs. The build pipeline checks **every hour** for new Synapse releases and rebuilds automatically, so the image is always current without a custom Synapse build.

| Component | Purpose | Port |
|---|---|---|
| **Synapse** | Matrix homeserver (core component) | 8008 |
| **coturn** | TURN/STUN server for voice and video calls | 3478, 5349, 49160–49200/udp |
| **Element Web** | Modern Matrix client (web UI) | 8080/element/ |
| **Synapse-Admin** | Admin interface (users, rooms, tokens) | 8080/admin/ |
| **Prometheus metrics** | Internal Synapse metrics endpoint | 9090 |

**PostgreSQL is external** — Synapse requires specific locale settings (below), and keeping the database external gives you full control over backups and performance.

## Before you start — two things you must do

**1. Create the PostgreSQL database with the right locale** (UTF8 + `C` collation) — any other locale and Synapse refuses to start. In your Postgres container console (`psql -U postgres`); `admin`/`matrix` are the template defaults, use your own values consistently:

```sql
CREATE USER admin WITH PASSWORD 'yoursecretpassword';
CREATE DATABASE matrix
    ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C'
    TEMPLATE template0 OWNER admin;
GRANT ALL PRIVILEGES ON DATABASE matrix TO admin;
```

**2. Add this to your reverse proxy** for `matrix.yourdomain.tld` (in NPM: proxy host → Edit → **Advanced** tab). Without it, media uploads fail and Sync requests time out:

```nginx
client_max_body_size 100M;
proxy_read_timeout 600s;
proxy_send_timeout 600s;
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Host $host;
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

## Quick start on Unraid

1. **Database first** — create it exactly as above.
2. **Install the template** — Apps → Community Applications → search `Matrix All-in-One`. Or add the template URL manually under Docker → Add Container → Template URLs:
   ```
   https://raw.githubusercontent.com/junkerderprovinz/unraid-apps/main/matrix/matrix.xml
   ```
3. **Fill in the required fields:**

   | Field | Example value | Note |
   |---|---|---|
   | `SERVER_NAME` | `matrix.yourdomain.tld` | **Can never be changed!** All user IDs become `@user:SERVER_NAME` |
   | `POSTGRES_HOST` | `192.168.1.10` | Use the Unraid host IP — container names don't resolve on the default bridge network |
   | `POSTGRES_USER` | `admin` | Must exist in PostgreSQL |
   | `POSTGRES_PASSWORD` | `yoursecretpassword` | Stored masked |
   | `POSTGRES_DB` | `matrix` | Must exist with the locale settings above |

   Optional extras: `ENABLE_REGISTRATION` (open signup + Element's **Create Account** button, default `false`), `TURN_DOMAIN`/`TURN_PORT` (route TURN through a dedicated subdomain/port), `ADMIN_USER`/`ADMIN_PASSWORD` (first server admin, below).

4. **Apply and check the logs** — a loud `MATRIX IS READY` banner appears after 30–60 seconds once Synapse is serving.
5. **Point your reverse proxy** (`matrix.yourdomain.tld`, scheme `http`, forward to Unraid-IP:`8008`, WebSockets **enabled**, Let's Encrypt + Force SSL) and paste the Advanced block above. Path-scoped proxies (SWAG/Traefik) must forward the **whole `/_synapse` prefix**, not just `/_synapse/client`, or Synapse-Admin shows "Server communication error".

## Federation

Enabled by default (template variable `Enable Federation`; set `false` for a private island server). Synapse serves both `/.well-known/matrix/*` endpoints itself — the proxy host above already covers them, nothing extra to configure. Verify:

```bash
curl -s https://matrix.yourdomain.tld/.well-known/matrix/server
# expected: {"m.server": "matrix.yourdomain.tld:443"}
```

Then run [federationtester.matrix.org](https://federationtester.matrix.org/) — all checks should be green.

## First admin user

Set the optional template variables `ADMIN_USER` + `ADMIN_PASSWORD` and restart — the container registers the account as a **Synapse server admin** (or **promotes an existing account** — exactly what Synapse-Admin needs; an Element *room* admin is a different thing). **Clear both variables afterwards.** Then sign in at `http://UNRAID-IP:8080/element/` with homeserver `https://matrix.yourdomain.tld`, and manage users/rooms/registration tokens at `http://UNRAID-IP:8080/admin/`.

## Voice / video calls

coturn runs over UDP and cannot pass through an HTTP proxy or Cloudflare Tunnel — forward port `3478` (TCP+UDP) plus the relay range (`49160-49200/udp`) to your Unraid host either way. `TURN_DOMAIN`/`TURN_PORT` let you route TURN through a dedicated subdomain and/or remapped port. TURN over TLS (port 5349) is optional: mount `fullchain.pem`/`privkey.pem` into `/data/certs/`.

## Updates

The image rebuilds automatically (hourly upstream check) for `linux/amd64` + `linux/arm64`. Every rebuild must pass a **boot smoke test** against a real PostgreSQL (no silent SQLite fallback) before `:latest` ships, gets a Trivy CVE scan, and carries SBOM + provenance attestations. On Unraid just click **Update** when it appears — `/data` (homeserver.yaml, media, signing keys) is preserved and Synapse migrations run automatically on startup.

## Full documentation & support

The complete README — PostgreSQL details, NPM / Cloudflare Tunnel trade-offs, monitoring (Prometheus/Grafana), **bridges** (WhatsApp/Telegram/Signal via mautrix), registration tokens, and a full **troubleshooting** section (database locale, federation, Synapse-Admin 403/404, TURN) — lives on GitHub:

**[github.com/junkerderprovinz/matrix](https://github.com/junkerderprovinz/matrix)**

Found a bug? Have a feature request? → [GitHub issues](https://github.com/junkerderprovinz/matrix/issues)

<a href="https://buymeacoffee.com/junkerderprovinz">
  <img src="https://raw.githubusercontent.com/junkerderprovinz/matrix/main/.github/assets/button-buy-me-a-coffee.svg" alt="Buy me a coffee" height="40">
</a>

## License

MIT — see [LICENSE](https://github.com/junkerderprovinz/matrix/blob/main/LICENSE). Not officially affiliated with Element HQ, the Matrix Foundation, or the Element project; Synapse, Element and coturn are their respective projects (under their own licenses), used unmodified.

---

<sub>Part of a family of self-hosted Unraid apps + plugins by <b>junkerderprovinz</b> — see them all at <a href="https://github.com/junkerderprovinz">github.com/junkerderprovinz</a>, or install from <a href="https://unraid.net/community/apps">Community Applications</a>.</sub>
