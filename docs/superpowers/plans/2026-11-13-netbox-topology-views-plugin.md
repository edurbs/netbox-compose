# NetBox topology-views plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **As-built amendment (2026-11-13, final review):** Task 1's migrate-exhaustion branch now attempts a plugin `--upgrade` plus a bounded 5-attempt re-retry, and logs the recreate recovery command, before exiting 1 (final-review Important #1; verified on a throwaway compose project).

**Goal:** NetBox (docker compose, LinuxServer.io image) always starts with the `netbox-topology-views` plugin installed and enabled.

**Architecture:** LSIO's `/custom-cont-init.d` hook pip-installs the plugin into the `/lsiopy` venv on every boot (skipped when already present). The image's own startup then applies plugin migrations (`manage.py migrate`) and static files (`collectstatic` uwsgi hook). Enabling is one line in the mounted `configuration.py`.

**Tech Stack:** docker compose, `lscr.io/linuxserver/netbox:latest`, pip package `netbox-topology-views`, Django setting `PLUGINS`.

**Spec:** `docs/superpowers/specs/2026-11-13-netbox-topology-views-plugin-design.md`

## Global Constraints

- No git repo in this directory: there are no commit steps; "done" = files on disk + verification output.
- Package name is hyphenated (`netbox-topology-views`); the Django app/`PLUGINS` entry is underscored (`netbox_topology_views`). Never mix them.
- Do not change DB, Redis, superuser, port, or restart settings in `compose.yaml`.
- Do not overwrite the user's existing `netbox-config/configuration.py` beyond the `PLUGINS` line.

## Review Focus

1. Script not executable after mount → pip never runs → uwsgi crash-loops on missing plugin. Expected: file mode `755` before `up`. Test: Task 1 Step 3.
2. Volume path typo in compose → script absent in container, same crash. Test: Task 4 Step 2 lists `/custom-cont-init.d` inside the container.
3. `PLUGINS` entry written with hyphens → NetBox treats it as unknown app and errors. Expected: `PLUGINS = ["netbox_topology_views"]`. Test: Task 3 Step 3 grep.
4. No internet on first boot → pip fails → NetBox stays down. Expected: log shows clear `[plugin-install]` failure, not silent skip. Test: Task 4 Step 4 inspects logs.
5. Existing NetBox data (user already has DB volume) → plugin migrations must apply non-destructively. Expected: `migrate` output shows `netbox_topology_views` migrations applied, app answers 200/302 on `:8000`. Test: Task 4 Steps 4–5.

---

### Task 1: Plugin install script

**Files:**
- Create: `netbox-config/custom-cont-init.d/20-install-plugins.sh`

**Interfaces:**
- Consumes: nothing (standalone).
- Produces: script path `netbox-config/custom-cont-init.d/20-install-plugins.sh`, executable, mounted by Task 2.

- [x] **Step 1: Write the script**

```bash
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
```

- [x] **Step 2: Make it executable**

Run: `chmod +x netbox-config/custom-cont-init.d/20-install-plugins.sh`

- [x] **Step 3: Verify syntax and exec bit**

Run: `bash -n netbox-config/custom-cont-init.d/20-install-plugins.sh && ls -l netbox-config/custom-cont-init.d/20-install-plugins.sh`
Expected: `bash -n` silent (no syntax errors); mode shows `rwxr-xr-x` (755).

### Task 2: Compose volume mount

**Files:**
- Modify: `compose.yaml` (volumes block of the `netbox` service, currently lines 33–34)

**Interfaces:**
- Consumes: script path from Task 1 (`./netbox-config/custom-cont-init.d`).
- Produces: in-container path `/custom-cont-init.d` present at runtime (checked in Task 4).

- [x] **Step 1: Add the mount**

In `compose.yaml`, inside `services.netbox.volumes`, add one line after `- ./netbox-config:/config`:

```yaml
      - ./netbox-config/custom-cont-init.d:/custom-cont-init.d
```

- [x] **Step 2: Validate compose file**

Run: `docker compose config --quiet`
Expected: exit code 0, no output.

### Task 3: Enable the plugin in configuration.py

**Files:**
- Modify: `netbox-config/configuration.py:229` (`PLUGINS = []`)

**Interfaces:**
- Consumes: Django app name `netbox_topology_views` (installed by the script from Task 1 at runtime).
- Produces: plugin active in the running NetBox (verified in Task 4).

- [x] **Step 1: Edit the PLUGINS line**

`PLUGINS = []` → `PLUGINS = ["netbox_topology_views"]`

Leave `PLUGINS_CONFIG` untouched (plugin defaults apply).

- [x] **Step 2: Verify the edit**

Run: `grep -n "^PLUGINS" netbox-config/configuration.py`
Expected: exactly one line, `PLUGINS = ["netbox_topology_views"]` (the `PLUGINS_CONFIG` comment block must remain untouched).

### Task 4: Recreate and verify

**Files:** none (runtime verification).

**Interfaces:**
- Consumes: all three prior tasks in place.

- [x] **Step 1: Recreate the stack**

Run: `docker compose up -d --force-recreate netbox`
Expected: netbox container (re)created; db/redis reused.

- [x] **Step 2: Confirm the script is mounted and runs**

Run: `docker compose exec netbox ls -l /custom-cont-init.d` and `docker compose logs netbox | grep plugin-install`
Expected: script listed with exec bit; log line `[plugin-install] Installing netbox-topology-views...` on a fresh venv (or `already installed, skipping.` on a warm one).

- [x] **Step 3: Confirm plugin migrations and collectstatic ran**

Run: `docker compose logs netbox | grep -E "netbox_topology_views|collectstatic"` and `docker compose exec -T netbox-db psql -U netbox -d netbox -t -c "SELECT count(*) FROM django_migrations WHERE app='netbox_topology_views';"`
Expected: migrate output applying `netbox_topology_views` migrations; plugin migration count `> 0`; no import errors.

- [x] **Step 4: Confirm the app is healthy**

Run: `curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/`
Expected: `200` or `302` (login redirect), not `500`/`502`.

- [x] **Step 5: Restart resilience check**

Run: `docker compose restart netbox`, then repeat Steps 2 and 4.
Expected: `[plugin-install] ... already installed, skipping.` (no re-download), app healthy again. This proves "always up with the plugin" across restarts.
