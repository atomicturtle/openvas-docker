# Greenbone Vulnerability Management (GVM) Docker Container

Self-contained, enterprise-grade **Greenbone Vulnerability Management (GVM)** container rebased on **Rocky Linux 10**.

Maintained and packaged by **Atomicorp, Inc.**

## Features
- **Modern Architecture:** GVM 26.43, OpenVAS Scanner 23.52, Valkey 8 (key-value store), PostgreSQL 16, Mosquitto 2 (MQTT broker), and Greenbone Security Assistant (GSA React Web UI).
- **Turnkey Setup:** Includes automated database initialization, certificate generation, Valkey/Mosquitto coordination, and administrative user bootstrapping.
- **Built-in CLI Automation:** Includes `gvm-tools` (26.1.2) and `python3-gvm` (27.10.1) for automated command-line scans and GMP scripting.
- **FIPS & Enterprise Ready:** Based on Rocky Linux 10 with distribution security standards.

---

## Quick Start

### 1. Launch Container
```bash
docker run -d \
  --name openvas \
  -p 443:443 \
  -p 9392:9392 \
  atomicorp/openvas
```

Access the web interface at:
- **URL:** `https://<IP>/` (or `https://<IP>:9392/`)
- **Default Username:** `admin`
- **Default Password:** `admin`

---

## Persistent Storage (Volumes)

For production deployments, persist vulnerability feeds, PostgreSQL databases, and scan history across container restarts and upgrades:

```bash
docker volume create gvm_data
docker volume create gvm_plugins
docker volume create gvm_db

docker run -d \
  --name openvas \
  -p 443:443 \
  -v gvm_data:/var/lib/gvm \
  -v gvm_plugins:/var/lib/openvas \
  -v gvm_db:/var/lib/pgsql \
  atomicorp/openvas
```

---

## Configuration Options

Configure container behavior via environment variables:

| Variable | Default | Description |
|---|---|---|
| `OV_PASSWORD` | `admin` | Custom administrative password for the `admin` user account. |
| `OV_UPDATE` | `no` | Set to `yes` to perform a full feed sync (`greenbone-feed-sync`) on container start. |
| `GSAD_PORT` | `443` | Port for the HTTPS web interface (defaults to `443`, alternative: `9392`). |

### Examples

#### Set Custom Admin Password
```bash
docker run -d \
  --name openvas \
  -p 443:443 \
  -e OV_PASSWORD=MySecurePassword123! \
  atomicorp/openvas
```

#### Sync Feeds on Startup
```bash
docker run -d \
  --name openvas \
  -p 443:443 \
  -e OV_UPDATE=yes \
  atomicorp/openvas
```

#### Proxy Configuration
If running behind a proxy, pass standard proxy environment variables. `run.sh` automatically normalizes `RSYNC_PROXY` if an `http://` or `https://` prefix is included:

```bash
docker run -d \
  --name openvas \
  -p 443:443 \
  -e http_proxy=http://proxy.example.com:3128 \
  -e https_proxy=http://proxy.example.com:3128 \
  -e RSYNC_PROXY=proxy.example.com:3128 \
  -e OV_UPDATE=yes \
  atomicorp/openvas
```

---

## Command Line Automation (`gvm-cli`)

Attach to the running container or execute scans directly:

```bash
# Open interactive shell
docker exec -it openvas bash

# Run GMP query via local socket
docker exec -it openvas runuser -u gvm -- \
  gvm-cli socket --gmp-username admin --gmp-password admin --xml "<get_version/>"
```

---

## Graceful Shutdown

The container handles `SIGTERM` and `SIGINT` signals, cleanly shutting down GSAD, GVMD, OSPd-openvas, Mosquitto, Valkey, and PostgreSQL:

```bash
docker stop openvas
```

---

## License & Credits

Copyright Atomicorp, Inc. Licensed under the AGPLv3.  
Special thanks to Greenbone AG and the Greenbone Community.
