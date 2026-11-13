# NetBox (docker compose) + netbox-topology-views

NetBox runs via the [LinuxServer.io image](https://docs.linuxserver.io/images/docker-netbox/) with the
[netbox-topology-views](https://github.com/netbox-community/netbox-topology-views) plugin always installed and enabled.

## Setup from this repo

```bash
cp .env.example .env                # then edit .env: set your passwords
cp netbox-config/configuration.py.example netbox-config/configuration.py
# edit netbox-config/configuration.py: set DB_PASSWORD, REDIS_PASSWORD (match .env) and SECRET_KEY
docker compose up -d
```

Secrets live in `.env` and the live `configuration.py` — both are gitignored and never committed.


## How the plugin is kept active

- `netbox-config/custom-cont-init.d/20-install-plugins.sh` runs inside the container on every boot (as root, before NetBox starts).
  It pip-installs `netbox-topology-views` into the image's Python environment only when missing, then applies DB migrations
  and creates the `admin` superuser if configured and missing.
- The plugin is enabled in `netbox-config/configuration.py` (`PLUGINS = ["netbox_topology_views"]`).
- `compose.yaml` binds the script directory to `/custom-cont-init.d` (LinuxServer's customization hook).

## Boot behavior

| Scenario | What happens |
| --- | --- |
| Normal boot | Plugin already present → `already installed, skipping.` → migrations no-op → NetBox up. **No internet needed.** |
| After `docker compose pull && up -d` (image update) | Fresh Python environment → plugin reinstalls from PyPI (~1 min, internet needed) → migrations apply. The web service may restart once while the install finishes; `restart: unless-stopped` self-heals. Expect ~2 extra minutes. |
| Plugin/NetBox version mismatch (rare; only right after a NetBox major release) | NetBox stays down. The script automatically attempts `pip install --upgrade` and retries; it converges on a later boot once a compatible version is published. To force re-resolution manually: `docker compose up -d --force-recreate netbox` (a plain `restart` is **not** enough — the old plugin stays in the container layer). |

## Manual plugin upgrade

```bash
docker compose exec -u root netbox pip install -U netbox-topology-views
docker compose restart netbox
```

## Plugin options

Defaults are fine to start. To let users save device positions in the topology view, add to `netbox-config/configuration.py`:

```python
PLUGINS_CONFIG = {
    "netbox_topology_views": {
        "allow_coordinates_saving": True,
    }
}
```

See the [plugin README](https://github.com/netbox-community/netbox-topology-views#configure) for all options.

## Security note

`/custom-cont-init.d` scripts run as root inside the container. The image logs a warning because the host directory is
owned by uid 1000 (`PUID`); on a single-user host this matches the standard LinuxServer customization pattern. To silence
the warning, make the script root-owned on the host: `sudo chown root:root netbox-config/custom-cont-init.d/20-install-plugins.sh`.
