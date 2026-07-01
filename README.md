<a href="https://matrix.org">
  <img src="https://raw.githubusercontent.com/junkerderprovinz/matrix/main/.github/assets/matrix-banner.png" alt="Matrix" width="100%">
</a>

<p align="center">
  <a href="https://github.com/junkerderprovinz/matrix/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/junkerderprovinz/matrix/build.yml?branch=main&label=Build&style=for-the-badge&logo=githubactions&logoColor=white" alt="Build" height="36"></a>&nbsp;
  <a href="https://github.com/junkerderprovinz/matrix/actions/workflows/lint.yml"><img src="https://img.shields.io/github/actions/workflow/status/junkerderprovinz/matrix/lint.yml?branch=main&label=Lint&style=for-the-badge&logo=githubactions&logoColor=white" alt="Lint" height="36"></a>&nbsp;
  <a href="https://hub.docker.com/r/junkerderprovinz/matrix"><img src="https://img.shields.io/docker/pulls/junkerderprovinz/matrix?style=for-the-badge&logo=docker&logoColor=white&label=Pulls&color=1d99f3" alt="Docker Pulls" height="36"></a>&nbsp;
  <a href="https://hub.docker.com/r/junkerderprovinz/matrix"><img src="https://img.shields.io/docker/image-size/junkerderprovinz/matrix/latest?style=for-the-badge&logo=docker&logoColor=white&label=Size&color=1d99f3" alt="Image Size" height="36"></a>&nbsp;
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

<br>

<p align="center">
  <a href="https://buymeacoffee.com/junkerderprovinz">
    <img src=".github/assets/button-buy-me-a-coffee.svg" alt="Buy me a coffee" width="220">
  </a>
</p>

<br>

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

Any other locale and Synapse refuses to start. Full details in [section 4](#4-setting-up-postgresql).

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
federation `well-known` snippet are in [section 5](#5-npm-configuration-nginx-proxy-manager) and [section 6](#6-enabling-federation).

<br>

## Table of Contents

1. [What Is This?](#1-what-is-this)
2. [Screenshots](#2-screenshots)
3. [Quick Start on Unraid](#3-quick-start-on-unraid)
4. [Setting Up PostgreSQL](#4-setting-up-postgresql)
5. [NPM Configuration (Nginx Proxy Manager)](#5-npm-configuration-nginx-proxy-manager)
6. [Enabling Federation](#6-enabling-federation)
7. [Monitoring (Prometheus)](#7-monitoring-prometheus)
8. [Adding Bridges](#8-adding-bridges)
9. [Creating the First Admin User](#9-creating-the-first-admin-user)
10. [Generating Registration Tokens](#10-generating-registration-tokens)
11. [Updates](#11-updates)
12. [Troubleshooting](#12-troubleshooting)
13. [Contributing / License](#13-contributing--license)
14. [Support this project](#14-support-this-project)
<br>

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
| **lighttpd** | Lightweight web server for Element Web + Synapse-Admin | 8080 |
| **Prometheus metrics** | Internal Synapse metrics endpoint | 9090 |

**Why a wrapper instead of building from scratch?**
The official Synapse image receives security patches immediately and is tested against every new
Synapse release. We build *on top of it* rather than alongside it — meaning: always up to date,
without maintaining our own Synapse build pipeline. The GitHub Actions workflow checks for new
Synapse releases every hour and rebuilds the image automatically.

**PostgreSQL is external** — this image does not include its own database. Synapse requires PostgreSQL
with specific locale settings (see section 3), and keeping it external gives you full control over
backups, connections, and performance.

<br>

## 2. Screenshots

Element is the recommended web client for Synapse (separate Unraid template, e.g. LSIO's `element-web`).

<p align="center">
  <img src="https://raw.githubusercontent.com/junkerderprovinz/matrix/main/.github/assets/screenshots/matrix-1.jpg" alt="Element web client — first login on this Synapse server" width="90%">
  <br><em>First login — Element home view served by your own Synapse homeserver.</em>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/junkerderprovinz/matrix/main/.github/assets/screenshots/matrix-2.jpg" alt="Element — Create a Space dialog" width="90%">
  <br><em>Public vs. private Spaces — group rooms and people by topic or team.</em>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/junkerderprovinz/matrix/main/.github/assets/screenshots/matrix-3.jpg" alt="Element — Preferences with language and timezone settings" width="90%">
  <br><em>Preferences — application language, room list, Spaces, time format, presence.</em>
</p>

<br>

## 3. Quick Start on Unraid

### Step 1 — Create the PostgreSQL database

Before installing the Matrix template, the database must be ready (UTF8 + `LC_COLLATE='C'`).
See [section 4](#4-setting-up-postgresql) for the exact SQL — Synapse will not start without it.

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
   https://raw.githubusercontent.com/junkerderprovinz/unraid-apps/main/matrix/matrix.xml
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

Follow [section 5](#5-npm-configuration-nginx-proxy-manager) to make Synapse accessible over HTTPS.
**Don't forget the Advanced tab** — `client_max_body_size 100M;` and `proxy_read_timeout 600s;`
are required for media uploads and Sync to work.

<br>

## 4. Setting Up PostgreSQL

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

<br>

## 5. NPM Configuration (Nginx Proxy Manager)

Matrix clients require HTTPS. The Matrix container itself does not handle TLS —
that is delegated to a reverse proxy (or a Cloudflare Tunnel).

### 5.1 Access options: reverse proxy vs. Cloudflare Tunnel

There are two ways to reach Matrix from the internet. **Both use the ports this
template already publishes** (`8008` for Synapse, `8080` for Element / Admin /
well-known), so **no template change is needed** for either one.

| | Reverse proxy (NPM / Traefik / Caddy) | Cloudflare Tunnel |
|---|---|---|
| Open router ports | `443` | none |
| TLS handled by | the proxy (Let's Encrypt) | Cloudflare's edge |
| Media upload size | you choose (this README uses `100M`) | hard `100 MB` cap on free/pro plans |
| Federation | well-known delegation (section 6) | same well-known delegation (section 6) |
| Voice / video (TURN) | forward the TURN ports | forward the TURN ports (UDP, **not** tunnelable) |

**Recommended:** a reverse proxy, which is what the rest of this section documents.
A Cloudflare Tunnel is a fine alternative if you would rather not open any ports —
just keep the 100 MB upload cap in mind and apply the same well-known delegation
(section 6) so federation works. If you ever put the domain on Cloudflare's regular
**orange-cloud** proxy instead of a tunnel, switch the Matrix subdomain to **DNS only
(grey cloud)**: the orange proxy throws bot challenges at non-browser clients and
breaks federation.

> **Voice / video, either way:** coturn (TURN/STUN) runs over UDP and cannot pass
> through an HTTP reverse proxy or a Cloudflare Tunnel. For working calls, forward
> the TURN ports (`3478` plus the relay range) to your Unraid host regardless of
> which option you pick.

For the reverse-proxy route you need **two proxy hosts** in NPM:

### 5.2 Proxy host: Matrix API (matrix.yourdomain.tld)

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

> **Using a path-scoped reverse proxy instead (SWAG, Traefik, hand-written nginx)?**
> The NPM host above forwards the whole subdomain to Synapse, so it covers every
> endpoint. Path-based configs must forward the **entire `/_synapse` prefix**, not just
> `/_synapse/client`. A `location ~ ^(/_matrix|/_synapse/client)` block omits
> `/_synapse/admin`, so Synapse-Admin loads but its data calls return **404** and it
> shows **"Server communication error"**. Widen it to `^(/_matrix|/_synapse)`. See
> [Troubleshooting → Synapse-Admin](#synapse-admin-server-communication-error).

### 5.3 Proxy host: Element Web + Admin (optional custom domain)

If you want Element Web accessible under its own domain (e.g. `element.yourdomain.tld`):

| Field | Value |
|---|---|
| Domain Names | `element.yourdomain.tld` |
| Scheme | `http` |
| Forward Hostname/IP | `192.168.1.10` (your Unraid host IP) |
| Forward Port | `8080` |

Element is then available at `https://element.yourdomain.tld/element/`.

<br>

## 6. Enabling Federation

Matrix federation lets your users chat with people on other Matrix servers
(like `@user:matrix.org`). It is **enabled by default** and controlled by the
`Enable Federation` template variable. Set it to `false` if you want to run
a private island server instead.

For other servers to find yours, two well-known endpoints must be reachable at
your domain. **Synapse now serves both itself** (`serve_server_wellknown` +
`public_baseurl`, set automatically from your `SERVER_NAME`):

- `/.well-known/matrix/server` — tells other Matrix servers to federate with you over port **443**
- `/.well-known/matrix/client` — tells Matrix clients which homeserver to use

### Reverse-proxy setup (nothing extra to configure)

Because Synapse serves these on the same listener as `/_matrix`, the
`matrix.yourdomain.tld` proxy host from [section 5.2](#52-proxy-host-matrix-api-matrixyourdomaintld)
already covers them. There are **no custom `/.well-known/...` locations to add and
no JSON to write by hand** — just make sure that proxy host forwards `https://
matrix.yourdomain.tld/` to Synapse (it does by default).

> Upgrading from an older build where you added manual `/.well-known/matrix/*`
> proxy locations (or a `return 200 '{...}'` snippet)? You can remove them — the
> container handles delegation now. Leaving them in place is harmless but
> redundant.

### Verifying

Once the container is up and the proxy host is in place, test the endpoints:

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

<br>

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

<br>

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

<br>

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
user as an admin — or **promotes an existing account to server admin** if that
username already exists. **Clear both variables afterwards** so it doesn't run
again on every restart.

The resulting Matrix ID is `@<ADMIN_USER>:<SERVER_NAME>`, e.g. `@admin:matrix.yourdomain.tld`.

> **Already registered that account in Element?** Set `ADMIN_USER`/`ADMIN_PASSWORD` to its
> name and restart — the bootstrap **promotes the existing account to server admin** (it only
> sets the admin flag; it won't change the password). This is what **Synapse-Admin** needs: a
> Synapse *server admin*, which is different from an Element *room* admin. Without it,
> Synapse-Admin loads but shows **"Server communication error"** because the `/_synapse/admin`
> API returns 403.

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

<br>

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

<br>

## 11. Updates

### Automatic image updates (GitHub Actions)

The GitHub Actions workflow checks **every hour** for a new Synapse release.
When one is found, the image is automatically rebuilt for `linux/amd64` and `linux/arm64`
and pushed to `junkerderprovinz/matrix` on Docker Hub (mirrored to `ghcr.io/junkerderprovinz/matrix`).

### Updating the container on Unraid

1. Unraid → **Docker → Matrix**
2. Click the container icon → **Update available** appears when a new version is out
3. Click **Update** → Unraid pulls the new image and restarts the container

**Or use Unraid's bulk update:** Unraid → **Docker → Update All Containers**

> Updates do not affect data in `/data` — your homeserver.yaml, media files, and signing keys
> are preserved. Synapse database migrations run automatically on startup.

<br>

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
| `No SRV or well-known` | well-known missing | Follow section 5 |
| `TLS certificate error` | Certificate invalid | Renew SSL certificate in NPM |
| `Connection timeout` | Port 443/8448 blocked | Check router port forwarding |
| `Invalid JSON` | well-known config malformed | Restart container to re-render well-known files |

### Synapse-Admin: "Server communication error"

The Synapse-Admin page loads and you can log in, but the user / room lists stay empty
and you get a **"Server communication error"**. Open the browser DevTools (`F12`) →
**Network** tab, reproduce, and check the status of the failing `/_synapse/admin/...`
request:

| Status | Cause | Fix |
|---|---|---|
| **403** | The account is not a Synapse **server admin** (an Element *room* admin is a different thing). | Set `ADMIN_USER` / `ADMIN_PASSWORD` to that account and restart — the bootstrap promotes it (see [section 9](#9-creating-the-first-admin-user)). Or run `UPDATE users SET admin = 1 WHERE name = '@you:yourdomain';` in Postgres and restart. |
| **404** | Your reverse proxy forwards `/_matrix` and `/_synapse/client` but **not** `/_synapse/admin`. | Forward the **whole** `/_synapse` prefix, not just `/_synapse/client`. |

The 404 trap hits path-scoped configs (SWAG, Traefik, hand-written nginx). A SWAG
`matrix.subdomain.conf` typically ships with:

```nginx
location ~ ^(/_matrix|/_synapse/client) {   # ← misses /_synapse/admin
```

Widen it so the admin API is forwarded too:

```nginx
location ~ ^(/_matrix|/_synapse) {          # ← covers /_synapse/admin
```

NPM users following [section 5.2](#52-proxy-host-matrix-api-matrixyourdomaintld) are not
affected: that proxy host forwards the entire subdomain to Synapse on `8008`, so
`/_synapse/admin` is already covered.

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

<br>

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

*Built with care for the Unraid community.*

<br>

## 14. Support this project

If this template saves you a setup hassle or a debug night, consider buying me a coffee:

<p align="center">
  <a href="https://buymeacoffee.com/junkerderprovinz">
    <img src=".github/assets/button-buy-me-a-coffee.svg" alt="Buy me a coffee" width="220">
  </a>
</p>

---

<sub>Part of a family of self-hosted Unraid apps + plugins by <b>junkerderprovinz</b> — see them all at <a href="https://github.com/junkerderprovinz">github.com/junkerderprovinz</a>, or install from <a href="https://unraid.net/community/apps">Community Applications</a>.</sub>
