# Matrix All-in-One for Unraid

[![Build & Push](https://github.com/junkerderprovinz/matrix/actions/workflows/build.yml/badge.svg)](https://github.com/junkerderprovinz/matrix/actions/workflows/build.yml)
[![Lint](https://github.com/junkerderprovinz/matrix/actions/workflows/lint.yml/badge.svg)](https://github.com/junkerderprovinz/matrix/actions/workflows/lint.yml)
[![Image: ghcr.io/junkerderprovinz/matrix](https://img.shields.io/badge/image-ghcr.io%2Fjunkerderprovinz%2Fmatrix-blue)](https://ghcr.io/junkerderprovinz/matrix)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-green.svg)](LICENSE)

A complete, plug-and-play Docker image for running your own **Matrix homeserver** on Unraid.
No manual config file editing, no SSH access to the container required —
just enter your domain and database credentials and the container handles the rest.

---

## Table of Contents

1. [What is this?](#1-what-is-this)
2. [Quick Start on Unraid](#2-quick-start-on-unraid)
3. [Setting Up PostgreSQL](#3-setting-up-postgresql)
4. [NPM Configuration](#4-npm-configuration-nginx-proxy-manager)
5. [Enabling Federation](#5-enabling-federation)
6. [Creating the First Admin User](#6-creating-the-first-admin-user)
7. [Generating Registration Tokens](#7-generating-registration-tokens)
8. [Updates](#8-updates)
9. [Troubleshooting](#9-troubleshooting)
10. [Contributing / License](#10-contributing--license)

---

## 1. What Is This?

This image is a **wrapper around the official Synapse image** from Element (`ghcr.io/element-hq/synapse`).
It extends bare Synapse with all the components needed for a fully functional
Matrix homeserver:

| Component | Purpose | Port |
|---|---|---|
| **Synapse** | Matrix homeserver (core component) | 8008 |
| **coturn** | TURN/STUN server for voice and video calls | 3478, 5349 |
| **Element Web** | Modern Matrix client (web UI) | 8080/element/ |
| **Synapse-Admin** | Admin interface (users, rooms, tokens) | 8080/admin/ |
| **lighttpd** | Lightweight web server for Element + Admin | 8080 |

**Why a wrapper instead of building from scratch?**
The official Synapse image receives security patches immediately and is tested against every new
Synapse release. We build *on top of it* rather than alongside it — meaning: always up to date,
without maintaining our own Synapse build pipeline. The GitHub Actions workflow checks for new
Synapse releases every hour and rebuilds the image automatically.

**PostgreSQL is external** — this image does not include its own database. Synapse requires PostgreSQL
with specific locale settings (see section 3), and keeping it external gives you full control over
backups, connections, and performance.

---

## 2. Quick Start on Unraid

### Step 1 — Create the PostgreSQL database

Before installing the Matrix template, the database must be ready.
Follow section 3 of this guide.

### Step 2 — Install the template

**Option A: Community Applications (recommended)**

1. In Unraid, open: **Apps → Community Applications**
2. Search for `Matrix All-in-One`
3. Click **Install**

**Option B: Manual template URL**

1. Unraid → **Docker → Add Container**
2. Click **Template URLs** in the top right
3. Paste the following URL:
   ```
   https://raw.githubusercontent.com/junkerderprovinz/matrix/main/unraid-template.xml
   ```
4. Click **Save**, then select **Matrix** from the template list

### Step 3 — Fill in the required fields

In the template form, you must configure the following fields:

| Field | Example value | Note |
|---|---|---|
| `SERVER_NAME` | `matrix.yourdomain.tld` | **Can never be changed!** |
| `POSTGRES_HOST` | `PostgreSQL15` | Container name or IP |
| `POSTGRES_USER` | `synapse` | Must exist in PostgreSQL |
| `POSTGRES_PASSWORD` | `yoursecretpassword` | Stored masked |
| `POSTGRES_DB` | `synapse` | Must exist with correct locale settings |

> **Important:** `SERVER_NAME` is the foundation of your Matrix identity. All user IDs take the form
> `@username:SERVER_NAME`. This setting **cannot be changed after the first run** without dropping
> the entire database.

### Step 4 — Start the container and check the logs

1. Click **Apply** → the container starts
2. In Unraid, open: **Docker → Matrix → Logs**
3. You should see: `[init] INFO: Container initialization complete. Starting services ...`
4. After approximately 30–60 seconds, Synapse is ready

### Step 5 — Configure NPM

Follow section 4 of this guide to make Synapse accessible over HTTPS.

---

## 3. Setting Up PostgreSQL

Synapse has **strict requirements** for the PostgreSQL database:
- Encoding: `UTF8`
- LC_COLLATE: `C`
- LC_CTYPE: `C`

Without these exact settings, Synapse will refuse to start with an error such as
`database encoding is not UTF8` or `collation mismatch`.

### Connecting to the PostgreSQL console

**In Unraid via Docker terminal:**

1. Open **Docker → PostgreSQL15 → Console**
2. Enter:

```bash
psql -U postgres
```

### Creating the user and database

```sql
-- Create the Synapse database user
CREATE USER synapse WITH PASSWORD 'YOUR_SECURE_PASSWORD';

-- Create the database with the locale settings required by Synapse
-- IMPORTANT: use template0, not template1 — only template0 allows
--            overriding LC_COLLATE and LC_CTYPE
CREATE DATABASE synapse
    OWNER synapse
    ENCODING 'UTF8'
    LC_COLLATE = 'C'
    LC_CTYPE   = 'C'
    TEMPLATE template0;

-- Grant permissions
GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse;

-- Test the connection
\c synapse synapse
-- If no error appears: everything is correct
\q
```

### Connectivity between containers

On Unraid's bridge network, the easiest way to reach the PostgreSQL container is via its
**container name** (e.g. `PostgreSQL15`) as the hostname, provided both containers are on the
same custom Docker network.

**Recommended approach — custom network:**

1. Unraid → **Settings → Docker → IPv4 custom network subnet** → enable
2. Start both containers (PostgreSQL + Matrix) on the same network
3. Use the container name `PostgreSQL15` as `POSTGRES_HOST`

**Alternative — bridge via host IP:**

Set `POSTGRES_HOST` to the LAN IP of your Unraid server (e.g. `192.168.1.100`).
PostgreSQL must then listen on `0.0.0.0` (not just localhost).

---

## 4. NPM Configuration (Nginx Proxy Manager)

Matrix clients require HTTPS. The Matrix container itself does not handle TLS —
that is delegated to Nginx Proxy Manager as the reverse proxy.

You need **two proxy hosts** in NPM:

### 4.1 Proxy host: Matrix API (matrix.yourdomain.tld)

**NPM → Hosts → Add Proxy Host**

| Field | Value |
|---|---|
| Domain Names | `matrix.yourdomain.tld` |
| Scheme | `http` |
| Forward Hostname/IP | `UNRAID-IP` or container name |
| Forward Port | `8008` |
| Websockets Support | **enabled** |
| Block Common Exploits | enabled |

**SSL tab:** Issue a Let's Encrypt certificate → enable Force SSL

**Custom Nginx configuration** (Advanced tab):

```nginx
# Matrix requires large uploads (media, files)
client_max_body_size 100M;

# WebSocket support for Matrix Sync (long-polling)
proxy_read_timeout 600s;
proxy_send_timeout 600s;

# Forward the real client IP (for x_forwarded: true in homeserver.yaml)
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;

# Matrix-specific headers
proxy_set_header Host $host;
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

### 4.2 Proxy host: Element Web + Admin (optional custom domain)

If you want Element Web accessible under its own domain (e.g. `element.yourdomain.tld`):

| Field | Value |
|---|---|
| Domain Names | `element.yourdomain.tld` |
| Scheme | `http` |
| Forward Hostname/IP | `UNRAID-IP` |
| Forward Port | `8080` |

Element is then available at `https://element.yourdomain.tld/element/`.

---

## 5. Enabling Federation

Matrix federation allows you to communicate with users on other servers.
For this to work, other servers need to be able to discover where your Synapse instance is running.

The recommended approach is the `/.well-known/matrix/server` file on your **root domain**
(not the matrix. subdomain).

**Example:** If your `SERVER_NAME` is `matrix.yourdomain.tld`, you could instead use
a cleaner identity like `yourdomain.tld` — but that is more complex to configure.
For the simplest setup, use `SERVER_NAME = matrix.yourdomain.tld`.

### Well-known via NPM custom response

If your root domain is already configured in NPM, add the following custom Nginx config:

```nginx
location /.well-known/matrix/server {
    add_header Content-Type application/json;
    add_header Access-Control-Allow-Origin *;
    return 200 '{"m.server": "matrix.yourdomain.tld:443"}';
}

location /.well-known/matrix/client {
    add_header Content-Type application/json;
    add_header Access-Control-Allow-Origin *;
    return 200 '{
        "m.homeserver": {
            "base_url": "https://matrix.yourdomain.tld"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    }';
}
```

### Testing federation

After setup, use: [https://federationtester.matrix.org/](https://federationtester.matrix.org/)

Enter `matrix.yourdomain.tld`. All checks should be green.

**Common federation test errors:**

- `DNS SRV record not found` → Normal when well-known is correctly configured, not a problem
- `Connection refused` → Port 8448 or 443 not reachable → check firewall/NPM
- `Certificate error` → SSL certificate not valid for the domain

---

## 6. Creating the First Admin User

After the first run there are no users yet. Since open registration is disabled,
the first admin user must be created via the command line.

### Via the Unraid container console

1. Unraid → **Docker → Matrix → Console**
2. Run the following command (replace the placeholder values):

```bash
register_new_matrix_user \
  -c /data/homeserver.yaml \
  -u YOUR_USERNAME \
  -p YOUR_PASSWORD \
  --admin \
  http://localhost:8008
```

You will be prompted for a username, password, and admin status interactively if you omit the
`-u` and `-p` flags.

> **Security note:** The password is stored in the shell history when passed as a flag. For
> production use, omit the flags and enter credentials interactively.

### Signing in

Open `http://UNRAID-IP:8080/element/` in your browser.

1. Click **Sign In**
2. Click **Edit** next to the homeserver
3. Enter `https://matrix.yourdomain.tld`
4. Sign in with your username and password

---

## 7. Generating Registration Tokens

Registration tokens let you invite specific users to register without enabling open registration
for everyone.

### Method 1: Synapse-Admin (recommended)

1. Open `http://UNRAID-IP:8080/admin/`
2. Sign in with the admin user
3. **Registration Tokens → Create Token**
4. Configure: maximum uses, expiry date
5. Copy the token and share it with the invited user

### Method 2: Admin API (curl)

```bash
# First, obtain an access token for the admin user:
curl -XPOST \
  'https://matrix.yourdomain.tld/_matrix/client/v3/login' \
  -H 'Content-Type: application/json' \
  -d '{"type":"m.login.password","user":"ADMIN_USER","password":"ADMIN_PASSWORD"}'

# Copy the token from the response, then:
curl -XPOST \
  'https://matrix.yourdomain.tld/_synapse/admin/v1/registration_tokens/new' \
  -H 'Authorization: Bearer YOUR_ACCESS_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"uses_allowed": 1}'
```

### Enabling token-based registration

For users to register with a token, the following must be set in `/data/homeserver.yaml`
(or in `/data/homeserver-overrides.yaml`):

```yaml
enable_registration: true
registration_requires_token: true
```

Then restart the container: **Docker → Matrix → Restart**

---

## 8. Updates

### Automatic image updates (GitHub Actions)

The GitHub Actions workflow checks **every hour** for a new Synapse release.
When one is found, the image is automatically rebuilt for `linux/amd64` and `linux/arm64`
and pushed to `ghcr.io/junkerderprovinz/matrix:latest`.

### Updating the container on Unraid

1. Unraid → **Docker → Matrix**
2. Click the container icon → **Update available** appears when a new version is out
3. Click **Update** → Unraid pulls the new image and restarts the container

**Or use Unraid's bulk update:** Unraid → **Docker → Update All Containers**

> Updates do not affect data in `/data` — your homeserver.yaml, media files, and signing keys
> are preserved. Synapse database migrations run automatically on startup.

---

## 9. Troubleshooting

### Error: "database encoding is not UTF8" or "LC_COLLATE mismatch"

**Cause:** The PostgreSQL database was created without the correct locale settings.

**Fix:**
```sql
-- Drop and recreate the database (data loss!)
DROP DATABASE synapse;
CREATE DATABASE synapse
    OWNER synapse
    ENCODING 'UTF8'
    LC_COLLATE = 'C'
    LC_CTYPE   = 'C'
    TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse;
```

### Error: "Permission denied" on /data

**Cause:** Files in `/mnt/user/appdata/matrix/` are owned by a different user than `PUID:PGID`.

**Fix in the Unraid terminal:**
```bash
chown -R 99:100 /mnt/user/appdata/matrix/
```

### Error: Container won't start — "SERVER_NAME not set"

**Cause:** The `SERVER_NAME` environment variable is empty or missing in the template.

**Fix:** Unraid → **Docker → Matrix → Edit** → fill in `SERVER_NAME` → Apply

### Error: "Connection refused" to PostgreSQL

**Cause:** The Matrix container cannot reach the PostgreSQL container.

**Checklist:**
1. Is the PostgreSQL container running? → Check the Unraid Docker tab
2. Correct `POSTGRES_HOST`? → Is the container name or IP right?
3. Are both containers on the same Docker network?
4. Is PostgreSQL listening on `0.0.0.0`? → In PostgreSQL: `listen_addresses = '*'` in `postgresql.conf`
5. Does `pg_hba.conf` allow connections from the Matrix container?

### Federation test failing

**Common causes:**

| Error | Cause | Fix |
|---|---|---|
| `No SRV or well-known` | well-known missing | Follow section 5 |
| `TLS certificate error` | Certificate invalid | Renew SSL certificate in NPM |
| `Connection timeout` | Port 443/8448 blocked | Check router port forwarding |
| `Invalid JSON` | well-known config malformed | Check JSON syntax |

### Viewing logs

**In Unraid:**
- Docker → Matrix → icon → Logs

**Via terminal:**
```bash
docker logs matrix --follow --tail 100
```

**Synapse's own logs** (if configured in /data/logs/):
```bash
tail -f /mnt/user/appdata/matrix/logs/homeserver.log
```

### TURN/video calls not working

1. Open ports 3478 (TCP+UDP) in your router and forward them to the Unraid IP
2. Verify that `turn_uris` is correctly set in `homeserver.yaml` (this happens automatically)
3. The TURN shared secret in `homeserver.yaml` and `turnserver.conf` must match
   (both are populated from `/data/.turn_secret` — check container logs if there are issues)
4. `denied-peer-ip` in `turnserver.conf` blocks private IP ranges — this may affect LAN testing
   but is not relevant for calls over the internet

---

## 10. Contributing / License

### Issues & feature requests

Found a bug? Have a feature request? → [GitHub Issues](https://github.com/junkerderprovinz/matrix/issues)

### Pull requests

PRs are welcome. Please:
1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Run shellcheck and hadolint locally (or rely on the lint workflow)
4. Open a PR against `main`

### License

Apache 2.0 — see [LICENSE](LICENSE)

This project is not officially affiliated with Element HQ, the Matrix Foundation, or
the Element project. Synapse, Element, and coturn are their respective
trademarks/projects and are used here unmodified as base images / packages.

---

*Built with ❤️ for the Unraid community.*
