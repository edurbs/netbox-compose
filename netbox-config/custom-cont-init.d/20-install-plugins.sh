#!/usr/bin/with-contenv bash
# Install NetBox plugins into the /lsiopy venv on every container start.
# Skips packages already installed; reinstalls automatically after an image
# update (fresh venv). Runs as root before NetBox services start.
#
# After installing, waits for the configuration symlink and the database and
# then applies migrations + superuser itself: the image's own init
# (init-netbox-prepare) can run while pip is still downloading and fail on
# the missing plugin package; it is a oneshot and never retries. Both steps
# here are idempotent — whichever of the two paths runs last wins cleanly.

set -e

PLUGINS="netbox-topology-views"

for PLUGIN in ${PLUGINS}; do
    if pip show "${PLUGIN}" >/dev/null 2>&1; then
        echo "[plugin-install] ${PLUGIN} already installed, skipping."
    else
        echo "[plugin-install] Installing ${PLUGIN}..."
        pip install --no-cache-dir "${PLUGIN}"
    fi
done

# Wait for the configuration symlink the image's init creates (max ~30s).
for i in $(seq 1 30); do
    [[ -e /app/netbox/netbox/netbox/configuration.py ]] && break
    sleep 1
done
if [[ ! -e /app/netbox/netbox/netbox/configuration.py ]]; then
    echo "[plugin-install] configuration.py not found after 30s; cannot continue."
    exit 1
fi

cd /app/netbox/netbox

# Wait for the database (max ~60s), then apply all pending migrations,
# including the plugins'.
MIGRATE_OK=""
for i in $(seq 1 30); do
    if s6-setuidgid abc python3 manage.py migrate; then
        MIGRATE_OK=1
        break
    fi
    echo "[plugin-install] database not ready yet (attempt ${i}/30), retrying in 2s..."
    sleep 2
done
if [[ -z "${MIGRATE_OK}" ]]; then
    echo "[plugin-install] migrate failed after 30 attempts."
    echo "[plugin-install] Upgrading plugins in case a compatible version was published..."
    pip install --no-cache-dir --upgrade ${PLUGINS} || true
    RETRY_OK=""
    for i in $(seq 1 5); do
        if s6-setuidgid abc python3 manage.py migrate; then
            RETRY_OK=1
            break
        fi
        echo "[plugin-install] migrate still failing after upgrade (attempt ${i}/5), retrying in 2s..."
        sleep 2
    done
    if [[ -z "${RETRY_OK}" ]]; then
        echo "[plugin-install] migrate still failing. If a NetBox major release outran the plugin, recreate the container once a compatible plugin version is published:"
        echo "[plugin-install]   docker compose up -d --force-recreate netbox"
        exit 1
    fi
fi

# Create the superuser like the image's init does (if configured and missing).
if [[ -n "${SUPERUSER_EMAIL}" ]] && [[ -n "${SUPERUSER_PASSWORD}" ]]; then
cat << EOF | s6-setuidgid abc python3 manage.py shell
from users.models import Token, User;

username = 'admin';
password = '$SUPERUSER_PASSWORD';
email = '$SUPERUSER_EMAIL';

if not User.objects.filter(username='admin'):
    User.objects.create_superuser(username, email, password);
    print('Superuser created.');
else:
    print('Superuser creation skipped. Already exists.');
EOF
fi

echo "[plugin-install] Done."
