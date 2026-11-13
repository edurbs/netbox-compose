# NetBox topology-views plugin (docker compose) — short design

Date: 2026-11-13

**Intent:** The NetBox instance (docker compose, LinuxServer.io image `lscr.io/linuxserver/netbox:latest`) always comes up with the `netbox-topology-views` plugin active, across restarts and `latest` image updates.

**Goals**
- Plugin installed and enabled with no manual steps after `docker compose pull && docker compose up -d`.
- Works with the existing `./netbox-config:/config` mount and existing Postgres/Redis services.

**Non-goals**
- Pinning NetBox or plugin versions (both currently track latest; can be pinned later).
- Switching to the official `netbox-community/netbox-docker` image.
- Changing DB/Redis settings or the restart policy.

**Constraints / facts about the image** (verified 2026-11-13)
- NetBox lives at `/app/netbox`, Python venv at `/lsiopy`; container runs init as root, app as `abc`.
- On every boot the image's init runs `manage.py migrate` (all apps, including plugins) and the uwsgi `hook-pre-app` runs `collectstatic --noinput`. **Amendment (2026-11-13, after first live run):** the migrate one-shot races the plugin pip-install on a fresh venv and, once failed, never retries — so the custom install script itself must run `migrate` (+ superuser) after installing. Collectstatic is safe: the uwsgi hook re-runs on every app (re)start and self-heals once the plugin is present.
- LSIO containers execute `/custom-cont-init.d/*` scripts (root, with-contenv) before any service starts.
- No LSIO docker-mod exists for this plugin; it is installed via pip (`netbox-topology-views`, latest v5.0.2, no exotic deps).

**Approaches considered**
1. **Startup script via `/custom-cont-init.d`** (CHOSEN): a small script pip-installs the plugin into `/lsiopy` only when missing, on every boot. Self-heals after image updates; no build step. Trade-off: needs internet at boot when (re)installing.
2. Custom Dockerfile `FROM lscr.io/linuxserver/netbox` + `RUN pip install`: plugin baked in, no boot-time network, but every image update needs a manual `docker compose build --pull` or the plugin goes stale/missing — poor fit with a `latest` workflow. Rejected.
3. Official `netbox-docker` image (has native `plugin_requirements.txt` support): would require redoing the entire working compose (different env vars, superuser handling). Rejected.

**The design**
- `netbox-config/custom-cont-init.d/20-install-plugins.sh` (executable): `pip show netbox-topology-views || pip install --no-cache-dir netbox-topology-views`.
- `compose.yaml`: netbox service gains volume `./netbox-config/custom-cont-init.d:/custom-cont-init.d`.
- `netbox-config/configuration.py`: `PLUGINS = []` → `PLUGINS = ["netbox_topology_views"]` (package hyphen, Django app underscore). Plugin options stay at defaults for now.

**Known limitation:** Both NetBox and the plugin track latest. In the rare window right after a NetBox major release where the plugin hasn't published a compatible version yet, NetBox stays down until a compatible plugin version appears. **Plain restarts do not recover from this** — the incompatible plugin stays in the container's writable layer, so `pip show` keeps finding it and is never re-resolved. Two things do recover: the install script itself (when its post-install migrate keeps failing, it runs `pip install --upgrade` for the plugins and retries migrate, converging within the same boot once a compatible version is on PyPI), and an operator recreate — `docker compose up -d --force-recreate netbox` — which discards the layer and reinstalls latest from scratch.

**Verification:** recreate the netbox container; logs must show the plugin install (first boot), successful migrate/collectstatic, and the app must answer on `:8000`.
