<h1 align="center">Matrix All-in-One for Unraid</h1>

<a href="https://matrix.org">
  <img src="https://raw.githubusercontent.com/junkerderprovinz/matrix/main/.github/assets/matrix-banner.svg" alt="Matrix" width="100%">
</a>

<p align="center">
  <a href="https://github.com/junkerderprovinz/matrix/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/junkerderprovinz/matrix/build.yml?branch=main&label=Build&style=for-the-badge&logo=githubactions&logoColor=white" alt="Build" height="36"></a>&nbsp;
  <a href="https://github.com/junkerderprovinz/matrix/actions/workflows/lint.yml"><img src="https://img.shields.io/github/actions/workflow/status/junkerderprovinz/matrix/lint.yml?branch=main&label=Lint&style=for-the-badge&logo=githubactions&logoColor=white" alt="Lint" height="36"></a>&nbsp;
  <a href="https://github.com/junkerderprovinz/matrix/pkgs/container/matrix"><img src="https://img.shields.io/badge/Image-ghcr.io-1d99f3?style=for-the-badge&logo=docker&logoColor=white" alt="Image" height="36"></a>&nbsp;
  <a href="https://github.com/junkerderprovinz/matrix/pkgs/container/matrix"><img src="https://img.shields.io/badge/Arch-amd64%20%7C%20arm64-success?style=for-the-badge&logo=linux&logoColor=white" alt="Arch" height="36"></a>&nbsp;
  <a href="https://github.com/element-hq/synapse"><img src="https://img.shields.io/badge/Synapse-homeserver-0dbd8b?style=for-the-badge&logo=matrix&logoColor=white" alt="Synapse" height="36"></a>&nbsp;
  <a href="https://element.io"><img src="https://img.shields.io/badge/Element-web%20client-0dbd8b?style=for-the-badge&logo=element&logoColor=white" alt="Element" height="36"></a>&nbsp;
  <a href="https://unraid.net"><img src="https://img.shields.io/badge/Unraid-Template-f15a2c?style=for-the-badge&logo=unraid&logoColor=white" alt="Unraid" height="36"></a>&nbsp;
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge&logo=opensourceinitiative&logoColor=white" alt="License" height="36"></a>
</p>

<p align="center">
A complete, plug-and-play Docker image for running your own <b>Matrix homeserver</b> on Unraid.
No manual config file editing, no SSH access to the container required —
just enter your domain and database credentials and the container handles the rest.
</p>

---

## ⚠️ Before You Start — Two Things You Must Do

The container itself is plug-and-play, but two things outside the container must be set up
correctly or Synapse will not work:

**1. Create the PostgreSQL database with the right locale** (UTF8 + `C` collation).
In your Postgres container console (`psql -U postgres`):

```sql
CREATE USER admin WITH PASSWORD 'yoursecretpassword';
CREATE DATABASE matrix
    ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C'
    TEMPLATE template0 OWNER admin;
```

Any other locale and Synapse refuses to start. Full details in [section 3](#3-setting-up-postgresql).

**2. Add NPM Advanced config** to your `matrix.yourdomain.tld` proxy host.
NPM → your proxy host → **Edit** → **Advanced** tab → paste this complete block into
*Custom Nginx Configuration*:

```nginx
# Matrix media uploads can be large
client_max_body_size 100M;

# Long-polling sync needs generous timeouts
proxy_read_timeout 600s;
proxy_send_timeout 600s;

# Forward real client IP (matches x_forwarded: true in homeserver.yaml)
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Host $host;

# WebSocket / HTTP-1.1 upgrade for /_matrix/client/*/sync
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

Without these, media uploads fail and Sync requests time out. Details and the
federation `well-known` snippet are in [section 4](#4-npm-configuration-nginx-proxy-manager) and [section 5](#5-enabling-federation).

---

## Table of Contents

1. [What is this?](#1-what-is-this)
2. [Quick Start on Unraid](#2-quick-start-on-unraid)
3. [Setting Up PostgreSQL](#3-setting-up-postgresql)
4. [NPM Configuration](#4-npm-configuration-nginx-proxy-manager)
5. [Enabling Federation](#5-enabling-federation)
6. [Monitoring (Prometheus)](#7-monitoring-prometheus)
7. [Adding Bridges](#8-adding-bridges)
8. [Creating the First Admin User](#9-creating-the-first-admin-user)
9. [Generating Registration Tokens](#10-generating-registration-tokens)
10. [Updates](#11-updates)
11. [Troubleshooting](#12-troubleshooting)
12. [Contributing / License](#13-contributing--license)

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
| **lighttpd** | Lightweight web server for Element, Admin, and well-known | 8080 |
| **Prometheus metrics** | Internal Synapse metrics endpoint | 9090 |

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

Before installing the Matrix template, the database must be ready (UTF8 + `LC_COLLATE='C'`).
See [section 3](#3-setting-up-postgresql) for the exact SQL — Synapse will not start without it.

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
   https://raw.githubusercontent.com/junkerderprovinz/matrix/main/templates/matrix.xml
   ```
4. Click **Save**, then select **Matrix** from the template list

### Step 3 — Fill in the required fields

In the template form, you must configure the following fields:

| Field | Example value | Note |
|---|---|---|
| `SERVER_NAME` | `matrix.yourdomain.tld` | **Can never be changed!** |
| `POSTGRES_HOST` | `192.168.1.10` | Unraid host IP (see "Why IP?" below) |
| `POSTGRES_USER` | `admin` | Must exist in PostgreSQL |
| `POSTGRES_PASSWORD` | `yoursecretpassword` | Stored masked |
| `POSTGRES_DB` | `matrix` | Must exist with correct locale settings |

> **Important:** `SERVER_NAME` is the foundation of your Matrix identity. All user IDs take the form
> `@username:SERVER_NAME`. This setting **cannot be changed after the first run** without dropping
> the entire database.

### Step 4 — Start the container and check the logs

1. Click **Apply** → the container starts
2. In Unraid, open: **Docker → Matrix → Logs**
3. You should see: `[init] INFO: Container initialization complete. Starting services ...`
4. After approximately 30–60 seconds, Synapse is ready

### Step 5 — Configure NPM

Follow [section 4](#4-npm-configuration-nginx-proxy-manager) to make Synapse accessible over HTTPS.
**Don't forget the Advanced tab** — `client_max_body_size 100M;` and `proxy_read_timeout 600s;`
are required for media uploads and Sync to work.

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

The SQL below uses `admin` as the database user and `matrix` as the database name —
these are the **template defaults** documented here. You are free to choose different
names; just make sure the `POSTGRES_USER` and `POSTGRES_DB` fields in the Unraid
template match whatever values you actually create.

```sql
-- Create the Synapse database user
-- (you may use any username; 'admin' is the template default)
CREATE USER admin WITH PASSWORD 'yoursecretpassword';

-- Create the database with the locale settings required by Synapse
-- IMPORTANT: use template0, not template1 — only template0 allows
--            overriding LC_COLLATE and LC_CTYPE
CREATE DATABASE matrix
    ENCODING 'UTF8'
    LC_COLLATE='C'
    LC_CTYPE='C'
    TEMPLATE template0
    OWNER admin;

-- Grant permissions
GRANT ALL PRIVILEGES ON DATABASE matrix TO admin;

-- Test the connection
\c matrix admin
-- If no error appears: everything is correct
\q
```

### Why IP instead of container name?

By default, Unraid runs all containers on the standard `bridge` network. On this network,
**container name resolution does not work** — Docker only resolves container names to IPs
when both containers are on the same *custom* Docker network.

Using your Unraid host IP + the published PostgreSQL port works on any network type:

```
POSTGRES_HOST = 192.168.1.10
POSTGRES_PORT = 5432
```

This avoids "connection refused" errors that often happen when using the container name
(`PostgreSQL15`) on the default bridge network.

**If you prefer container names:** create a custom Docker network in Unraid
(*Settings → Docker → IPv4 custom network subnet* → enable), start both containers on it,
and set `POSTGRES_HOST` to the PostgreSQL container name.

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
| Forward Hostname/IP | `192.168.1.10` (your Unraid host IP) |
| Forward Port | `8008` |
| Websockets Support | **enabled** |
| Block Common Exploits | enabled |

> **Why IP instead of container name?**  
> Container names only resolve inside custom Docker networks. Using `192.168.1.10:8008`
> (Unraid host IP + published container port) works reliably on bridge networks too.

**SSL tab:** Issue a Let's Encrypt certificate → enable Force SSL

**Custom Nginx configuration** (Advanced tab) — paste as one block:

```nginx
# Matrix media uploads can be large
client_max_body_size 100M;

# Long-polling sync needs generous timeouts
proxy_read_timeout 600s;
proxy_send_timeout 600s;

# Forward real client IP (matches x_forwarded: true in homeserver.yaml)
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Host $host;

# WebSocket / HTTP-1.1 upgrade for /_matrix/client/*/sync
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
| Forward Hostname/IP | `192.168.1.10` (your Unraid host IP) |
| Forward Port | `8080` |

Element is then available at `https://element.yourdomain.tld/element/`.

---

## 5. Enabling Federation

Matrix federation lets your users chat with people on other Matrix servers
(like `@user:matrix.org`). It is **enabled by default** and controlled by the
`Enable Federation` template variable. Set it to `false` if you want to run
a private island server instead.

For federation to work, other servers must be able to discover where your
Synapse runs. This is done via two well-known JSON endpoints that the
container hosts automatically:

- `/.well-known/matrix/server` — tells other Matrix servers where to reach you
- `/.well-known/matrix/client` — tells Matrix clients which homeserver to use

Both files are generated on every container start from your `SERVER_NAME` and
served by the built-in lighttpd on port 8080 — you do not need to write any
JSON yourself.

### Reverse-proxy setup (one host, no second proxy needed)

You only need **one proxy host** in NPM — the same one that already proxies
Synapse on `matrix.yourdomain.tld`. Add two custom locations to it:

**NPM → `matrix.yourdomain.tld` proxy host → Edit → Custom locations tab:**

| Location | Forward Scheme | Forward Host/IP | Forward Port |
|---|---|---|---|
| `/.well-known/matrix/server` | `http` | *Unraid IP* | `8080` |
| `/.well-known/matrix/client` | `http` | *Unraid IP* | `8080` |

That's it. Save and reload NPM.

#### Alternative: paste this into Advanced → Custom Nginx Configuration

If you prefer a single block of config instead of two custom-location entries,
paste this into the `Advanced → Custom Nginx Configuration` field of the
`matrix.yourdomain.tld` proxy host (replace `192.168.1.10` with your Unraid IP):

```nginx
location /.well-known/matrix/server {
    proxy_pass http://192.168.1.10:8080/.well-known/matrix/server;
    proxy_set_header Host $host;
}

location /.well-known/matrix/client {
    proxy_pass http://192.168.1.10:8080/.well-known/matrix/client;
    proxy_set_header Host $host;
}
```

### Verifying

After saving the proxy host, test the endpoints:

```bash
curl -s https://matrix.yourdomain.tld/.well-known/matrix/server
# expected: {"m.server": "matrix.yourdomain.tld:443"}

curl -s https://matrix.yourdomain.tld/.well-known/matrix/client
# expected: {"m.homeserver": {"base_url": "https://matrix.yourdomain.tld"}}
```

Then run the federation tester:

[https://federationtester.matrix.org/](https://federationtester.matrix.org/)

Enter `matrix.yourdomain.tld`. All checks should be green and `FederationOK: true`.

**Common errors:**

- `No .well-known found` → the two custom locations above are not active yet
- `context deadline exceeded` on port 8448 → normal when well-known points to
  port 443; the tester just falls back to direct 8448. Once well-known is set up,
  this error becomes irrelevant
- `Certificate error` → SSL certificate not valid for the domain

---

## 7. Monitoring (Prometheus)

The container exposes Synapse's internal **Prometheus metrics** on port **9090**, bound to
`0.0.0.0` so Prometheus can reach them from the host network.

- **Port:** `9090`
- **Path:** `/_synapse/metrics`
- **Bind:** `0.0.0.0` (all interfaces)

> Keep port 9090 on a private network — these metrics expose detailed internal Synapse state
> and should not be publicly accessible.

### Prometheus scrape_config example

Add this to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'synapse'
    metrics_path: /_synapse/metrics
    static_configs:
      - targets: ['192.168.1.10:9090']
        labels:
          instance: 'matrix.yourdomain.tld'
```

### Grafana dashboard

The Synapse project maintains an official Grafana dashboard at:
[https://github.com/element-hq/synapse/tree/develop/contrib/grafana](https://github.com/element-hq/synapse/tree/develop/contrib/grafana)

Import the JSON dashboard into Grafana and point it at your Prometheus datasource to get
a full view of federation lag, event processing rates, cache hit ratios, and more.

---

## 8. Adding Bridges

**Bridges** connect your Matrix homeserver to other messaging platforms — WhatsApp, Telegram,
Signal, Discord, iMessage, and more. They appear as bots in your Matrix rooms and relay
messages transparently between networks.

### Bridges are not bundled in this image

This image deliberately does not include any bridges. Keeping the core image focused on
Synapse, coturn, and the web UIs ensures a smaller attack surface and simpler upgrades.
Each bridge has its own release cycle and dependencies that are better managed separately.

### Recommended approach: mautrix bridges as separate containers

The [mautrix bridge collection](https://docs.mau.fi/bridges/) is the most actively maintained
set of Matrix bridges and covers WhatsApp, Telegram, Signal, Discord, Meta (Instagram/Facebook),
Google Chat, and more. Run each bridge as its own Docker container alongside this one.

**General workflow:**

1. Run the bridge container once to generate its `config.yaml`
2. Edit `config.yaml` to point at your Synapse homeserver URL and PostgreSQL database
3. Run the bridge with `--generate-registration` to produce a `registration.yaml` file
4. Copy `registration.yaml` into `/data/appservices/` inside the Matrix container
5. Restart the Matrix container — Synapse will automatically load all `.yaml` files from
   `/data/appservices/` at startup

The `/data/appservices/` directory on your Unraid host maps to
`/mnt/user/appdata/matrix/appservices/`. Create it manually if it does not yet exist.

### Bridge documentation

Full installation guides for every supported platform:
**[https://docs.mau.fi/bridges/](https://docs.mau.fi/bridges/)**

---

## 9. Creating the First Admin User

After the first run there are no users yet. Since open registration is disabled,
the first admin user must be created. There are two ways to do this.

### Method 1: Auto-create via template variables (recommended)

The template ships with two optional environment variables:

| Variable         | Description                                      |
| ---------------- | ------------------------------------------------ |
| `ADMIN_USER`     | Localpart of the admin account, e.g. `admin`     |
| `ADMIN_PASSWORD` | Password for the auto-created admin account      |

1. Edit the Matrix container in Unraid
2. Set `ADMIN_USER` and `ADMIN_PASSWORD`
3. Apply — the container restarts and creates the admin user automatically

On the next boot, after Synapse is ready, the bootstrap service registers the
user as an admin and writes a marker file (`/data/.admin_created`) so the
operation is never repeated. **You can safely clear both variables afterwards.**

The resulting Matrix ID is `@<ADMIN_USER>:<SERVER_NAME>`, e.g. `@admin:matrix.yourdomain.tld`.

### Method 2: Manually via the Unraid container console

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

## 10. Generating Registration Tokens

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

## 11. Updates

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

## 12. Troubleshooting

### Error: "database encoding is not UTF8" or "LC_COLLATE mismatch"

**Cause:** The PostgreSQL database was created without the correct locale settings.

**Fix:**
```sql
-- Drop and recreate the database (data loss!)
DROP DATABASE matrix;
CREATE DATABASE matrix
    OWNER admin
    ENCODING 'UTF8'
    LC_COLLATE='C'
    LC_CTYPE='C'
    TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE matrix TO admin;
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
2. Correct `POSTGRES_HOST`? → Use the Unraid host IP (e.g. `192.168.1.10`) instead of a container name
3. Correct `POSTGRES_PORT`? → Default is `5432`
4. Is PostgreSQL listening on `0.0.0.0`? → In PostgreSQL: `listen_addresses = '*'` in `postgresql.conf`
5. Does `pg_hba.conf` allow connections from the Matrix container?

### Federation test failing

**Common causes:**

| Error | Cause | Fix |
|---|---|---|
| `No SRV or well-known` | well-known missing | Follow section 6 |
| `TLS certificate error` | Certificate invalid | Renew SSL certificate in NPM |
| `Connection timeout` | Port 443/8448 blocked | Check router port forwarding |
| `Invalid JSON` | well-known config malformed | Restart container to re-render well-known files |

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

#### TURN over TLS (optional)

To enable TURN over TLS on port 5349, mount a directory containing `fullchain.pem` and
`privkey.pem` to `/data/certs/` inside the container. The filenames must be exactly:

- `/data/certs/fullchain.pem`
- `/data/certs/privkey.pem`

**Tip:** NPM stores Let's Encrypt certificates in
`/mnt/user/appdata/NginxProxyManager/letsencrypt/live/npm-X/`. You can symlink or copy them:

```bash
mkdir -p /mnt/user/appdata/matrix/certs
cp /mnt/user/appdata/NginxProxyManager/letsencrypt/live/npm-1/fullchain.pem \
   /mnt/user/appdata/matrix/certs/fullchain.pem
cp /mnt/user/appdata/NginxProxyManager/letsencrypt/live/npm-1/privkey.pem \
   /mnt/user/appdata/matrix/certs/privkey.pem
```

Then set the **TURN-TLS Certs** path in the Unraid template to `/mnt/user/appdata/matrix/certs`
(mapped to `/data/certs` inside the container). If the cert files are missing, plain TURN on
port 3478 still works — TLS is entirely optional.

---

## 13. Contributing / License

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

*Built with care for the Unraid community.*
