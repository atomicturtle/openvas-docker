#!/usr/bin/env bash
#
# OpenVAS / Greenbone Community Edition Container Startup Script
# Copyright Atomicorp, Inc.
#

set -Eeuo pipefail

# Allow arbitrary commands to be executed directly via docker run
if [ $# -gt 0 ]; then
    exec "$@"
fi

# Configuration & Defaults
OV_PASSWORD="${OV_PASSWORD:-admin}"
OV_UPDATE="${OV_UPDATE:-no}"
GSAD_PORT="${GSAD_PORT:-443}"
FEED_OWNER_UUID="78eceaec-3385-11ea-b237-28d24461215b"
RUN_DIR="/run"
VALKEY_SOCK="/run/valkey/valkey.sock"
OSPD_SOCK="/run/ospd/ospd-openvas.sock"
GVMD_SOCK="/run/gvmd/gvmd.sock"
PG_DATA="/var/lib/pgsql/data"

echo "=========================================================="
echo " Starting Greenbone Vulnerability Management (GVM)"
echo " Operating System: Rocky Linux 10"
echo " Atomicorp Packaging (GVM 26.43 / OpenVAS 23.52 / Valkey 8)"
echo "=========================================================="

# Ensure gvm user shell is bash
usermod -s /bin/bash gvm 2>/dev/null || true

# Ensure runtime directories and permissions
mkdir -p /run/valkey /run/redis /run/ospd /run/gvmd /run/gsad /run/postgresql /run/mosquitto \
         /var/log/gvm /var/log/valkey /var/log/mosquitto \
         /var/lib/gvm/.ssh /var/lib/openvas /var/lib/notus /etc/openvas/gnupg

chown -R valkey:valkey /run/valkey /var/log/valkey
chmod 770 /run/valkey

chown -R mosquitto:mosquitto /run/mosquitto /var/log/mosquitto
chmod 740 /run/mosquitto

chown -R postgres:postgres /run/postgresql /var/lib/pgsql
chmod 755 /run/postgresql

chown -R gvm:gvm /run/ospd /run/gvmd /run/gsad /var/log/gvm /var/lib/gvm /var/lib/openvas /var/lib/notus /etc/openvas
chmod 755 /run/ospd /run/gvmd /run/gsad
chmod 700 /etc/openvas/gnupg /var/lib/gvm/.ssh

# Compatibility symlink for tools hardcoded to /run/redis/redis.sock
ln -sf "$VALKEY_SOCK" /run/redis/redis.sock

# -----------------------------------------------------------
# Signal Handling / Graceful Shutdown
# -----------------------------------------------------------
shutdown_all() {
    echo ""
    echo "Caught termination signal! Shutting down GVM services..."

    if [ -n "${TAIL_PID:-}" ]; then
        kill "$TAIL_PID" 2>/dev/null || true
    fi
    
    # Stop GSAD
    if [ -f /run/gsad/gsad.pid ]; then
        echo "Stopping GSAD..."
        kill -TERM "$(cat /run/gsad/gsad.pid)" 2>/dev/null || true
    fi
    pkill -f gsad 2>/dev/null || true

    # Stop GVMD
    if [ -f /run/gvmd/gvmd.pid ]; then
        echo "Stopping GVMD..."
        kill -TERM "$(cat /run/gvmd/gvmd.pid)" 2>/dev/null || true
    fi
    pkill -f gvmd 2>/dev/null || true

    # Stop OSPd-openvas
    if [ -f /run/ospd/ospd-openvas.pid ]; then
        echo "Stopping OSPd-openvas..."
        kill -TERM "$(cat /run/ospd/ospd-openvas.pid)" 2>/dev/null || true
    fi
    pkill -f ospd-openvas 2>/dev/null || true

    # Stop Mosquitto
    echo "Stopping Mosquitto..."
    pkill -f mosquitto 2>/dev/null || true

    # Stop Valkey
    if [ -f /run/valkey/valkey.pid ]; then
        echo "Stopping Valkey..."
        kill -TERM "$(cat /run/valkey/valkey.pid)" 2>/dev/null || true
    fi
    pkill -f valkey-server 2>/dev/null || true

    # Stop PostgreSQL
    echo "Stopping PostgreSQL..."
    runuser -u postgres -- /usr/bin/pg_ctl -D "$PG_DATA" stop -m fast 2>/dev/null || true

    echo "All services stopped cleanly."
    exit 0
}

trap shutdown_all SIGTERM SIGINT SIGHUP

# -----------------------------------------------------------
# 1. PostgreSQL Initialization & Startup
# -----------------------------------------------------------
if [ ! -f "$PG_DATA/PG_VERSION" ]; then
    echo "Initializing PostgreSQL database..."
    runuser -u postgres -- /usr/bin/initdb -D "$PG_DATA"
fi

echo "Starting PostgreSQL..."
runuser -u postgres -- /usr/bin/pg_ctl -D "$PG_DATA" -l /var/lib/pgsql/pg.log start

# Wait for PostgreSQL to accept connections
until runuser -u postgres -- /usr/bin/pg_isready -q; do
    echo "Waiting for PostgreSQL to accept connections..."
    sleep 1
done
echo "PostgreSQL is ready."

# Initialize GVM database if not already created
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='gvm'" | grep -q 1; then
    echo "Creating gvm database role..."
    runuser -u postgres -- createuser -DRS gvm
fi

if ! runuser -u postgres -- psql -lqt | cut -d \| -f 1 | grep -qw gvmd; then
    echo "Creating gvmd database and extensions..."
    runuser -u postgres -- createdb -O gvm gvmd
    runuser -u postgres -- psql gvmd -q -c "create role dba with superuser noinherit;" || true
    runuser -u postgres -- psql gvmd -q -c "grant dba to gvm;" || true
    runuser -u postgres -- psql gvmd -q -c 'create extension "uuid-ossp";'
    runuser -u postgres -- psql gvmd -q -c 'create extension "pgcrypto";'
    runuser -u postgres -- psql gvmd -q -c 'create extension "pg-gvm";'
    echo "gvmd database initialized."
fi

# -----------------------------------------------------------
# 2. Valkey Startup
# -----------------------------------------------------------
VALKEY_CONF="/etc/valkey/valkey.conf"
if [ ! -f "$VALKEY_CONF" ]; then
    VALKEY_CONF="/etc/valkey.conf"
fi

sed -i -E "s|^#?\s*unixsocket .*|unixsocket $VALKEY_SOCK|" "$VALKEY_CONF"
if ! grep -q "^unixsocket $VALKEY_SOCK" "$VALKEY_CONF"; then
    echo "unixsocket $VALKEY_SOCK" >> "$VALKEY_CONF"
fi
sed -i -E "s|^#?\s*unixsocketgroup.*|unixsocketgroup valkey|" "$VALKEY_CONF"
sed -i -E "s|^#?\s*unixsocketperm.*|unixsocketperm 770|" "$VALKEY_CONF"
sed -i -E "s|^#?\s*port [0-9]+|port 0|" "$VALKEY_CONF"
sed -i -E "s|^#?\s*databases [0-9]+|databases 512|" "$VALKEY_CONF"
sed -i -E "s|^#?\s*daemonize.*|daemonize yes|" "$VALKEY_CONF"
sed -i -E "s|^#?\s*pidfile.*|pidfile /run/valkey/valkey.pid|" "$VALKEY_CONF"

if ! id -nG gvm | grep -qw valkey; then
    usermod -aG valkey gvm
fi

echo "Starting Valkey..."
valkey-server "$VALKEY_CONF"

until [ -S "$VALKEY_SOCK" ] && [ "$(valkey-cli -s "$VALKEY_SOCK" ping 2>/dev/null)" == "PONG" ]; do
    echo "Waiting for Valkey socket..."
    sleep 1
done
echo "Valkey is ready."

# -----------------------------------------------------------
# 3. Mosquitto MQTT Startup
# -----------------------------------------------------------
echo "Starting Mosquitto MQTT..."
mosquitto -c /etc/mosquitto/mosquitto.conf -d
sleep 1

# Configure openvas.conf
cat << 'EOF' > /etc/openvas/openvas.conf
db_address = /run/valkey/valkey.sock
mqtt_server_uri = localhost:1883
EOF
chown gvm:gvm /etc/openvas/openvas.conf
chmod 644 /etc/openvas/openvas.conf

# -----------------------------------------------------------
# 4. GPG Community Signing Key Import
# -----------------------------------------------------------
if [ ! -f /etc/openvas/gnupg/pubring.kbx ]; then
    echo "Importing Greenbone Community Feed signing key..."
    GNUPG_TMP=$(mktemp -d /tmp/openvas-gnupg-XXXXXX)
    if [ -f /etc/pki/openvas/GBCommunitySigningKey.asc ]; then
        cp /etc/pki/openvas/GBCommunitySigningKey.asc "$GNUPG_TMP/"
    else
        curl -f -s -L https://www.greenbone.net/GBCommunitySigningKey.asc -o "$GNUPG_TMP/GBCommunitySigningKey.asc" || true
    fi
    if [ -f "$GNUPG_TMP/GBCommunitySigningKey.asc" ]; then
        GNUPGHOME="$GNUPG_TMP" gpg --import "$GNUPG_TMP/GBCommunitySigningKey.asc" >/dev/null 2>&1 || true
        echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | GNUPGHOME="$GNUPG_TMP" gpg --import-ownertrust >/dev/null 2>&1 || true
        cp -r "$GNUPG_TMP"/* /etc/openvas/gnupg/ 2>/dev/null || true
        chown -R gvm:gvm /etc/openvas/gnupg
        chmod 700 /etc/openvas/gnupg
        chmod 600 /etc/openvas/gnupg/* 2>/dev/null || true
    fi
    rm -rf "$GNUPG_TMP"
fi

# -----------------------------------------------------------
# 5. Certificates
# -----------------------------------------------------------
if [ ! -f /var/lib/gvm/CA/cacert.pem ] || [ ! -f /var/lib/gvm/CA/servercert.pem ]; then
    echo "Generating GVM certificates..."
    runuser -u gvm -- /usr/bin/gvm-manage-certs -a >/dev/null 2>&1 || true
fi

# -----------------------------------------------------------
# 6. Feed Sync (if requested via OV_UPDATE=yes)
# -----------------------------------------------------------
if [ "$OV_UPDATE" = "yes" ]; then
    echo "Updating vulnerability feeds (greenbone-feed-sync)..."
    runuser -u gvm -- greenbone-feed-sync --type nvt || true
    runuser -u gvm -- greenbone-feed-sync --type gvmd-data || true
    runuser -u gvm -- greenbone-feed-sync --type scap || true
    runuser -u gvm -- greenbone-feed-sync --type cert || true
    runuser -u gvm -- openvas --update-vt-info >/dev/null 2>&1 || true
fi

# -----------------------------------------------------------
# 7. Database Migration
# -----------------------------------------------------------
echo "Running database migration..."
runuser -u gvm -- /usr/sbin/gvmd --migrate >/dev/null 2>&1 || true

# -----------------------------------------------------------
# 8. Start OSPd-openvas
# -----------------------------------------------------------
echo "Starting OSPd-openvas..."
runuser -u gvm -- /usr/bin/ospd-openvas --config /etc/gvm/ospd-openvas.conf

until [ -S "$OSPD_SOCK" ]; do
    echo "Waiting for OSPd socket..."
    sleep 1
done
echo "OSPd-openvas is ready."

# -----------------------------------------------------------
# 9. Start GVMD
# -----------------------------------------------------------
echo "Starting GVMD..."
runuser -u gvm -- /usr/sbin/gvmd --osp-vt-update="$OSPD_SOCK" --listen-group=gvm

until [ -S "$GVMD_SOCK" ] && runuser -u gvm -- /usr/sbin/gvmd --get-users >/dev/null 2>&1; do
    echo "Waiting for GVMD..."
    sleep 1
done
echo "GVMD is ready."

# -----------------------------------------------------------
# 10. Admin User Setup & Feed Owner
# -----------------------------------------------------------
if ! runuser -u gvm -- /usr/sbin/gvmd --get-users | grep -qw admin; then
    echo "Creating admin user..."
    runuser -u gvm -- /usr/sbin/gvmd --create-user=admin >/dev/null 2>&1 || true
    runuser -u gvm -- /usr/sbin/gvmd --user=admin --new-password="$OV_PASSWORD"
else
    if [ -n "$OV_PASSWORD" ]; then
        echo "Updating admin password..."
        runuser -u gvm -- /usr/sbin/gvmd --user=admin --new-password="$OV_PASSWORD"
    fi
fi

# Ensure Feed Owner UUID is configured
FEED_OWNER=$(runuser -u gvm -- /usr/sbin/gvmd --get-users --verbose | awk '/^admin / {print $2}')
if [ -n "$FEED_OWNER" ]; then
    runuser -u gvm -- /usr/sbin/gvmd --modify-setting "$FEED_OWNER_UUID" --value "$FEED_OWNER" >/dev/null 2>&1 || true
fi

# Rebuild scan configs and port lists if data objects exist
if [ -d /var/lib/gvm/data-objects/gvmd ]; then
    runuser -u gvm -- /usr/sbin/gvmd --rebuild-gvmd-data=all >/dev/null 2>&1 || true
fi

# -----------------------------------------------------------
# 11. Start GSAD (Web UI)
# -----------------------------------------------------------
echo "Starting Greenbone Security Assistant (GSAD) on port ${GSAD_PORT}..."
/usr/sbin/gsad --listen=0.0.0.0 --port="${GSAD_PORT}" \
               -k /var/lib/gvm/private/CA/serverkey.pem \
               -c /var/lib/gvm/CA/servercert.pem \
               --pid-file=/run/gsad/gsad.pid

echo "=========================================================="
echo " Greenbone Vulnerability Management is Ready!"
echo " Web UI: https://<container-ip>:${GSAD_PORT}/"
echo " Default Username: admin"
echo "=========================================================="

if [ "${BUILD:-false}" = "true" ]; then
    echo "Build phase complete; exiting."
    shutdown_all
fi

# Stream logs while keeping bash as PID 1 to handle signals gracefully
tail -F /var/log/gvm/gvmd.log /var/log/gvm/ospd-openvas.log /var/log/gvm/gsad.log 2>/dev/null &
TAIL_PID=$!

wait "$TAIL_PID"
