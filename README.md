# Matrix All-in-One für Unraid

[![Build & Push](https://github.com/junkerderprovinz/matrix/actions/workflows/build.yml/badge.svg)](https://github.com/junkerderprovinz/matrix/actions/workflows/build.yml)
[![Lint](https://github.com/junkerderprovinz/matrix/actions/workflows/lint.yml/badge.svg)](https://github.com/junkerderprovinz/matrix/actions/workflows/lint.yml)
[![Image: ghcr.io/junkerderprovinz/matrix](https://img.shields.io/badge/image-ghcr.io%2Fjunkerderprovinz%2Fmatrix-blue)](https://ghcr.io/junkerderprovinz/matrix)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-green.svg)](LICENSE)

Ein vollständiges, Plug-and-Play-Docker-Image für deinen eigenen **Matrix-Homeserver** auf Unraid.
Kein manuelles Bearbeiten von Konfigurationsdateien, kein SSH-Zugang zum Container nötig –
trage einfach deine Domain und Datenbankdaten ein und der Container erledigt den Rest.

---

## Inhaltsverzeichnis

1. [Was ist das?](#1-was-ist-das)
2. [Schnellstart Unraid](#2-schnellstart-unraid)
3. [PostgreSQL vorbereiten](#3-postgresql-vorbereiten)
4. [NPM-Konfiguration](#4-npm-konfiguration-nginx-proxy-manager)
5. [Federation aktivieren](#5-federation-aktivieren)
6. [Ersten Admin-User anlegen](#6-ersten-admin-user-anlegen)
7. [Registration-Tokens erzeugen](#7-registration-tokens-erzeugen)
8. [Updates](#8-updates)
9. [Troubleshooting](#9-troubleshooting)
10. [Mitwirken / Lizenz](#10-mitwirken--lizenz)

---

## 1. Was ist das?

Dieses Image ist ein **Wrapper um das offizielle Synapse-Image** von Element (`ghcr.io/element-hq/synapse`).
Es ergänzt das nackte Synapse um alle Komponenten, die man für einen vollständig funktionierenden
Matrix-Homeserver braucht:

| Komponente | Zweck | Port |
|---|---|---|
| **Synapse** | Matrix-Homeserver (Kernkomponente) | 8008 |
| **coturn** | TURN/STUN-Server für Sprach- und Videoanrufe | 3478, 5349 |
| **Element Web** | Moderner Matrix-Client (Web-UI) | 8080/element/ |
| **Synapse-Admin** | Admin-Oberfläche (User, Räume, Tokens) | 8080/admin/ |
| **lighttpd** | Schlanker Webserver für Element + Admin | 8080 |

**Warum ein Wrapper statt selbst kompilieren?**
Das offizielle Synapse-Image erhält sofort Security-Patches und ist für jede neue Synapse-Version
getestet. Wir bauen *darauf auf* statt daneben – das bedeutet: immer aktuell, ohne eigenen
Synapse-Build-Prozess. Der GitHub Actions Workflow prüft stündlich auf neue Synapse-Releases und
baut das Image automatisch neu.

**Postgres ist extern** – das Image enthält keine eigene Datenbank. Synapse braucht PostgreSQL
mit speziellen Locale-Einstellungen (siehe Abschnitt 3), und du hast damit volle Kontrolle über
Backups, Verbindungen und Performance.

---

## 2. Schnellstart Unraid

### Schritt 1 – PostgreSQL-Datenbank anlegen

Bevor du das Matrix-Template installierst, muss die Datenbank bereit sein.
Folge Abschnitt 3 dieser Anleitung.

### Schritt 2 – Template installieren

**Option A: Community Applications (empfohlen)**

1. Öffne in Unraid: **Apps → Community Applications**
2. Suche nach `Matrix All-in-One`
3. Klicke **Install**

**Option B: Template-URL manuell**

1. Unraid → **Docker → Add Container**
2. Klicke rechts oben auf **Template-URLs**
3. Füge folgende URL ein:
   ```
   https://raw.githubusercontent.com/junkerderprovinz/matrix/main/unraid-template.xml
   ```
4. Klicke **Save** und wähle dann **Matrix** aus der Template-Liste

### Schritt 3 – Pflichtfelder ausfüllen

Im Template-Formular musst du folgende Felder anpassen:

| Feld | Beispielwert | Hinweis |
|---|---|---|
| `SERVER_NAME` | `matrix.deinedomain.tld` | **Kann nie geändert werden!** |
| `POSTGRES_HOST` | `PostgreSQL15` | Container-Name oder IP |
| `POSTGRES_USER` | `synapse` | Muss in PostgreSQL angelegt sein |
| `POSTGRES_PASSWORD` | `geheimespasswort` | Wird verdeckt gespeichert |
| `POSTGRES_DB` | `synapse` | Muss mit korrekter Locale existieren |

> **Wichtig:** Der `SERVER_NAME` ist der Kern deiner Matrix-Identität. Alle User-IDs haben die Form
> `@benutzername:SERVER_NAME`. Diese Einstellung **kann nach dem ersten Start nicht mehr geändert
> werden** ohne die gesamte Datenbank zu löschen.

### Schritt 4 – Container starten und Logs prüfen

1. Klicke **Apply** → Container startet
2. Öffne in Unraid: **Docker → Matrix → Logs**
3. Du solltest sehen: `[init] INFO: Container initialization complete. Starting services ...`
4. Nach ca. 30–60 Sekunden ist Synapse bereit

### Schritt 5 – NPM einrichten

Folge Abschnitt 4 dieser Anleitung, um Synapse über HTTPS erreichbar zu machen.

---

## 3. PostgreSQL vorbereiten

Synapse hat **strikte Anforderungen** an die PostgreSQL-Datenbank:
- Encoding: `UTF8`
- LC_COLLATE: `C`
- LC_CTYPE: `C`

Ohne diese genauen Einstellungen verweigert Synapse den Start mit einem Fehler wie
`database encoding is not UTF8` oder `collation mismatch`.

### Verbindung zur PostgreSQL-Konsole

**In Unraid via Docker-Terminal:**

1. Öffne **Docker → PostgreSQL15 → Console**
2. Gib ein:

```bash
psql -U postgres
```

### Benutzer und Datenbank anlegen

```sql
-- Synapse-Datenbankbenutzer anlegen
CREATE USER synapse WITH PASSWORD 'DEIN_SICHERES_PASSWORT';

-- Datenbank mit den von Synapse geforderten Locale-Einstellungen anlegen
-- WICHTIG: template0 verwenden, nicht template1 – nur template0 erlaubt
--          das Überschreiben von LC_COLLATE und LC_CTYPE
CREATE DATABASE synapse
    OWNER synapse
    ENCODING 'UTF8'
    LC_COLLATE = 'C'
    LC_CTYPE   = 'C'
    TEMPLATE template0;

-- Berechtigungen setzen
GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse;

-- Verbindung testen
\c synapse synapse
-- Wenn kein Fehler erscheint: alles korrekt
\q
```

### Verbindung zwischen Containern

Bei Unraid-Bridge-Network erreichst du den PostgreSQL-Container am einfachsten
über den **Container-Namen** (z. B. `PostgreSQL15`) als Hostname, wenn beide
Container im selben benutzerdefinierten Docker-Network sind.

**Empfohlene Methode – Custom Network:**

1. Unraid → **Settings → Docker → IPv4 custom network subnet** → aktivieren
2. Beide Container (PostgreSQL + Matrix) im selben Network starten
3. Als `POSTGRES_HOST` den Container-Namen `PostgreSQL15` verwenden

**Alternative – Bridge über Host-IP:**

Als `POSTGRES_HOST` die LAN-IP deines Unraid-Servers eintragen (z. B. `192.168.1.100`).
PostgreSQL muss dann auf `0.0.0.0` lauschen (nicht nur auf localhost).

---

## 4. NPM-Konfiguration (Nginx Proxy Manager)

Matrix-Clients erwarten HTTPS. Der Matrix-Container selbst macht kein TLS –
das übernimmt Nginx Proxy Manager als Reverse Proxy.

Du brauchst **zwei Proxy Hosts** in NPM:

### 4.1 Proxy Host: Matrix API (matrix.deinedomain.tld)

**NPM → Hosts → Add Proxy Host**

| Feld | Wert |
|---|---|
| Domain Names | `matrix.deinedomain.tld` |
| Scheme | `http` |
| Forward Hostname/IP | `UNRAID-IP` oder Container-Name |
| Forward Port | `8008` |
| Websockets Support | **aktiviert** |
| Block Common Exploits | aktiviert |

**SSL Tab:** Let's Encrypt Zertifikat ausstellen → Force SSL aktivieren

**Custom Nginx Configuration** (Advanced-Tab):

```nginx
# Matrix benötigt große Uploads (Medien, Dateien)
client_max_body_size 100M;

# WebSocket-Support für Matrix Sync (Long-Polling)
proxy_read_timeout 600s;
proxy_send_timeout 600s;

# Weitergabe der echten Client-IP (für x_forwarded: true in homeserver.yaml)
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;

# Matrix-spezifische Header
proxy_set_header Host $host;
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

### 4.2 Proxy Host: Element Web + Admin (optional eigene Domain)

Wenn du Element Web unter einer eigenen Domain (z. B. `element.deinedomain.tld`) erreichbar
machen willst:

| Feld | Wert |
|---|---|
| Domain Names | `element.deinedomain.tld` |
| Scheme | `http` |
| Forward Hostname/IP | `UNRAID-IP` |
| Forward Port | `8080` |

Element ist dann unter `https://element.deinedomain.tld/element/` erreichbar.

---

## 5. Federation aktivieren

Matrix-Federation erlaubt es, mit Benutzern auf anderen Servern zu kommunizieren.
Dafür müssen andere Server herausfinden können, wo dein Synapse läuft.

Der empfohlene Weg ist die `/.well-known/matrix/server`-Datei auf deiner **Hauptdomain**
(nicht der matrix.-Subdomain).

**Beispiel:** Wenn dein `SERVER_NAME` = `matrix.deinedomain.tld` ist, kannst du stattdessen
eine sauberere Identität `deinedomain.tld` verwenden – aber das ist komplexer.
Für den einfachsten Weg nimm `SERVER_NAME = matrix.deinedomain.tld`.

### Well-Known via NPM-Custom-Response

Wenn deine Hauptdomain bereits in NPM konfiguriert ist, füge folgende Custom Nginx Config ein:

```nginx
location /.well-known/matrix/server {
    add_header Content-Type application/json;
    add_header Access-Control-Allow-Origin *;
    return 200 '{"m.server": "matrix.deinedomain.tld:443"}';
}

location /.well-known/matrix/client {
    add_header Content-Type application/json;
    add_header Access-Control-Allow-Origin *;
    return 200 '{
        "m.homeserver": {
            "base_url": "https://matrix.deinedomain.tld"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    }';
}
```

### Federation testen

Nach dem Setup: [https://federationtester.matrix.org/](https://federationtester.matrix.org/)

Dort `matrix.deinedomain.tld` eingeben. Alle Checks sollten grün sein.

**Häufige Fehler beim Federation-Test:**

- `DNS SRV record not found` → Normal wenn Well-Known korrekt ist, kein Problem
- `Connection refused` → Port 8448 oder 443 nicht erreichbar → Firewall/NPM prüfen
- `Certificate error` → SSL-Zertifikat nicht korrekt für die Domain

---

## 6. Ersten Admin-User anlegen

Nach dem ersten Start gibt es noch keine Benutzer. Da offene Registrierung deaktiviert ist,
muss der erste Admin-User über die Kommandozeile angelegt werden.

### Via Unraid Container-Konsole

1. Unraid → **Docker → Matrix → Console**
2. Führe folgenden Befehl aus (ersetze die Werte):

```bash
register_new_matrix_user \
  -c /data/homeserver.yaml \
  -u DEIN_BENUTZERNAME \
  -p DEIN_PASSWORT \
  --admin \
  http://localhost:8008
```

Du wirst nach Benutzername, Passwort und ob es ein Admin sein soll gefragt, wenn du die Flags
`-u` und `-p` weglässt.

> **Sicherheitshinweis:** Das Passwort wird im Befehlshistory gespeichert. Für Produktion
> die Flags weglassen und interaktiv eingeben.

### Einloggen

Öffne `http://UNRAID-IP:8080/element/` im Browser.

1. Klicke auf **Sign In**
2. Wähle **Edit** beim Homeserver
3. Trage `https://matrix.deinedomain.tld` ein
4. Melde dich mit Benutzername und Passwort an

---

## 7. Registration-Tokens erzeugen

Registration-Tokens erlauben es, eingeladenen Benutzern die Registrierung zu ermöglichen,
ohne offene Registrierung für alle freizuschalten.

### Methode 1: Synapse-Admin (empfohlen)

1. Öffne `http://UNRAID-IP:8080/admin/`
2. Logge dich mit dem Admin-User ein
3. **Registration Tokens → Create Token**
4. Einstellungen: maximale Nutzungen, Ablaufdatum
5. Token kopieren und an den einzuladenden Benutzer weitergeben

### Methode 2: Admin API (curl)

```bash
# Erst einen Access-Token für den Admin-User holen:
curl -XPOST \
  'https://matrix.deinedomain.tld/_matrix/client/v3/login' \
  -H 'Content-Type: application/json' \
  -d '{"type":"m.login.password","user":"ADMIN_USER","password":"ADMIN_PASSWORT"}'

# Token aus der Antwort kopieren, dann:
curl -XPOST \
  'https://matrix.deinedomain.tld/_synapse/admin/v1/registration_tokens/new' \
  -H 'Authorization: Bearer DEIN_ACCESS_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"uses_allowed": 1}'
```

### Registration mit Token aktivieren

Damit Benutzer sich mit einem Token registrieren können, muss in `/data/homeserver.yaml`
(oder in `/data/homeserver-overrides.yaml`) folgendes gesetzt sein:

```yaml
enable_registration: true
registration_requires_token: true
```

Starte dann den Container neu: **Docker → Matrix → Restart**

---

## 8. Updates

### Automatisches Image-Update (GitHub Actions)

Der GitHub Actions Workflow prüft **stündlich**, ob es eine neue Synapse-Version gibt.
Wenn ja, wird das Image automatisch für `linux/amd64` und `linux/arm64` neu gebaut
und zu `ghcr.io/junkerderprovinz/matrix:latest` gepusht.

### Unraid: Container aktualisieren

1. Unraid → **Docker → Matrix**
2. Klicke auf das Container-Symbol → **Update available** erscheint wenn eine neue Version da ist
3. Klicke **Update** → Unraid zieht das neue Image und startet den Container neu

**Oder via Unraid Update-All:** Unraid → **Docker → Update All Containers**

> Das Update verändert keine Daten in `/data` – deine homeserver.yaml, Medien und Schlüssel
> bleiben erhalten. Synapse-Migrationen werden beim Start automatisch ausgeführt.

---

## 9. Troubleshooting

### Fehler: "database encoding is not UTF8" oder "LC_COLLATE mismatch"

**Ursache:** Die PostgreSQL-Datenbank wurde ohne die korrekten Locale-Einstellungen angelegt.

**Lösung:**
```sql
-- Datenbank löschen und neu anlegen (Datenverlust!)
DROP DATABASE synapse;
CREATE DATABASE synapse
    OWNER synapse
    ENCODING 'UTF8'
    LC_COLLATE = 'C'
    LC_CTYPE   = 'C'
    TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse;
```

### Fehler: "Permission denied" auf /data

**Ursache:** Die Dateien in `/mnt/user/appdata/matrix/` gehören einem anderen User als `PUID:PGID`.

**Lösung in Unraid-Terminal:**
```bash
chown -R 99:100 /mnt/user/appdata/matrix/
```

### Fehler: Container startet nicht – "SERVER_NAME not set"

**Ursache:** Die Umgebungsvariable `SERVER_NAME` ist im Template leer oder nicht gesetzt.

**Lösung:** Unraid → **Docker → Matrix → Edit** → `SERVER_NAME` ausfüllen → Apply

### Fehler: "Connection refused" zu PostgreSQL

**Ursache:** Der Matrix-Container kann den PostgreSQL-Container nicht erreichen.

**Prüfliste:**
1. Läuft der PostgreSQL-Container? → Unraid Docker-Tab prüfen
2. Richtiger `POSTGRES_HOST`? → Container-Name oder IP korrekt?
3. Beide Container im selben Docker-Network?
4. PostgreSQL hört auf `0.0.0.0`? → In PostgreSQL: `listen_addresses = '*'` in `postgresql.conf`
5. `pg_hba.conf` erlaubt Verbindungen vom Matrix-Container?

### Federation-Test schlägt fehl

**Häufige Ursachen:**

| Fehler | Ursache | Lösung |
|---|---|---|
| `No SRV or well-known` | Well-Known fehlt | Abschnitt 5 befolgen |
| `TLS certificate error` | Zertifikat ungültig | NPM SSL-Zertifikat erneuern |
| `Connection timeout` | Port 443/8448 geblockt | Router-Portweiterleitung prüfen |
| `Invalid JSON` | Well-Known Config fehlerhaft | JSON-Syntax prüfen |

### Logs einsehen

**In Unraid:**
- Docker → Matrix → Symbol → Logs

**Via Terminal:**
```bash
docker logs matrix --follow --tail 100
```

**Synapse-eigene Logs** (wenn in /data/logs/ konfiguriert):
```bash
tail -f /mnt/user/appdata/matrix/logs/homeserver.log
```

### TURN/Videoanrufe funktionieren nicht

1. Ports 3478 (TCP+UDP) im Router freigeben und auf Unraid-IP weiterleiten
2. In `homeserver.yaml` prüfen ob `turn_uris` korrekt gesetzt sind (passiert automatisch)
3. TURN-Secret in `homeserver.yaml` und `turnserver.conf` müssen übereinstimmen
   (beide werden aus `/data/.turn_secret` befüllt – bei Problemen Container-Logs prüfen)
4. `denied-peer-ip` in `turnserver.conf` blockiert private IPs – für LAN-Tests kann das
   relevant sein, für Internet-Anrufe nicht

---

## 10. Mitwirken / Lizenz

### Issues & Feature Requests

Fehler gefunden? Feature-Wunsch? → [GitHub Issues](https://github.com/junkerderprovinz/matrix/issues)

### Pull Requests

PRs sind willkommen. Bitte:
1. Fork erstellen
2. Feature-Branch anlegen (`git checkout -b feature/mein-feature`)
3. Shellcheck und hadolint lokal prüfen (oder dem lint-Workflow vertrauen)
4. PR gegen `main` öffnen

### Lizenz

Apache 2.0 — siehe [LICENSE](LICENSE)

Dieses Projekt ist nicht offiziell mit Element HQ, der Matrix Foundation oder
dem Element-Projekt assoziiert. Synapse, Element und coturn sind ihre jeweiligen
Marken/Projekte und werden hier unverändert als Basis-Images / Pakete verwendet.

---

*Gebaut mit ❤️ für die Unraid-Community.*
