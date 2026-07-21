# Horizon Server Setup

Private Metroynome setup helper for local Horizon server installs.

This repo is intentionally only orchestration. It clones the Horizon/private repos into ignored `repos/`, writes generated config under `data/generated/`, keeps runtime data under `data/`, and starts Docker services.

## Supported Hosts

- Linux
- macOS
- Windows through Git Bash or WSL

The scripts are portable Bash and use `python3` for JSON editing.

## Requirements

- `bash`
- `git`
- `python3`
- Docker Desktop or Docker Engine with `docker compose`

Windows users can run from Git Bash/WSL, or use the PowerShell wrappers `setup.ps1` and `run.ps1`.

## First Run

Run from an existing terminal window. Do not double-click `setup.sh` on Windows, because Git Bash may open a separate window and close before you can read the output.

Git Bash / WSL / Linux / macOS:

```bash
./setup.sh uya
```

Windows PowerShell:

```powershell
.\setup.ps1 uya
```

Pick any profile in `profiles/`; for Deadlocked instead of UYA:

```bash
./setup.sh dl
```

Use SSH clone URLs if you have GitHub SSH access set up:

```bash
./setup.sh uya --ssh
./setup.sh dl --ssh
```

If IP detection picks the wrong network adapter, pass the host LAN IP explicitly:

```bash
./setup.sh uya --ip 192.168.1.190
```

After setup, set the DNAS IP to the IP printed by the script. You can print it again later with `./run.sh dns`. If DNS is disabled for a dedicated server, handle DNS/routing outside this setup repo.

For a server profile that should not use game-specific plugin, patch, or local DNS repos, disable them for one setup run:

```bash
./setup.sh <profile> --no-plugin
./setup.sh <profile> --no-patch
./setup.sh <profile> --no-dns
./setup.sh <profile> --no-plugin --no-patch --no-dns
```

Each setup run writes a transcript under `logs/`, for example `logs/setup-20260720-193000.log`.

## Local Settings

On first run, `local.settings.json` is created from `local.settings.example.json`.

Example:

```json
{
  "defaultProfile": "uya",
  "installRoot": "./repos",
  "generatedRoot": "./data/generated",
  "dataRoot": "./data",
  "secretsFile": "./local.secrets.json",

  "includePlugin": true,
  "includePatch": true,
  "includeDns": true,

  "cloneProtocol": "https",
  "serverIp": "auto",
  "startAfterSetup": true
}
```

`local.settings.json`, `local.secrets.json`, generated compose files, cloned repos, runtime data, and logs are ignored by git.

Set `includePlugin`, `includePatch`, or `includeDns` to `false` when a profile should run without game-specific plugins, patch downloads/mounts, or the local DNS helper. This is useful for Horizon server profiles that are not Ratchet & Clank games, or for dedicated servers where DNS is handled externally. You can also override those settings for one `run.sh` command with `--no-plugin`, `--no-patch`, or `--no-dns`.

Default local layout:

```text
horizon-server-setup/
  repos/                 # cloned Horizon repos, including horizon-docker as a source template
  data/
    generated/           # generated docker-compose.yml, .env, and Horizon JSON configs
    databases/           # per-profile local SQLite database data
    database-backup/     # SQL backup mount
    runtime/             # active profile cache and other local runtime state
  logs/                  # setup and server logs
  local.settings.json
  local.secrets.json
```

## Profiles

Each file in `profiles/` is a runnable server profile. UYA and DL are examples, but the scripts accept any `profiles/<name>.json` file.

Core profile fields:

```json
{
  "id": "mygame",
  "name": "My Game",
  "appIds": [12345],
  "database": {
    "name": "Horizon_MYGAME",
    "user": "sa",
    "sqlAdminPassword": "auto"
  },
  "world": {
    "locationName": "Main Lobby",
    "locationId": 40,
    "channelName": "CY00000000-00",
    "channelId": 1
  },
  "muis": {
    "encryptMessages": true,
    "entrypoints": [
      {
        "name": "My Game",
        "endpoint": "mygame-prod.pdonline.scea.com"
      }
    ]
  },
  "repos": []
}
```

Optional `plugin`, `patch`, and `middlewarePlugin` sections only need to exist for profiles that use them. Keep `muis` explicit for profiles that need MUIS routing, because the upstream default is only a template. `muis.entrypoints` may contain multiple regional login routes; `port` and `universeId` default to `10075` and `1` for all entries. Repos marked with `kind: "plugin"`, `kind: "patch"`, `kind: "middleware-plugin"`, or `kind: "dns"` are skipped when the matching feature is disabled.

`world.locationName` and `world.locationId` define the single visible city/lobby location Horizon currently handles cleanly. Horizon can return multiple locations, but without server-side PickLocation support those selections are not fully meaningful, so profiles intentionally stay to one location for now.

After changing profile app IDs, app names, location name/id, or channel name/id on an existing database, run `./run.sh sync-world` or use a start command that recreates middleware, such as `./run.sh start`.

## Database And Secrets

Each profile has its own database defaults in `profiles/<profile>.json`:

```json
"database": {
  "name": "Horizon_UYA",
  "user": "sa",
  "sqlAdminPassword": "auto"
}
```

`sqlAdminPassword` is the SQL Server administrator password used by the container as `HORIZON_MSSQL_SA_PASSWORD`. The generated middleware image uses this same admin credential for database initialization and access, so the profile database user should stay `sa` unless the middleware build is changed to provision custom SQL users.

When `sqlAdminPassword` is set to `auto`, setup writes the generated value to `local.secrets.json`:

```json
{
  "profiles": {
    "uya": {
      "database": {
        "sqlAdminPassword": "..."
      },
      "middlewarePassword": "..."
    }
  }
}
```

Edit `local.secrets.json` if you want to change generated passwords locally. It is ignored by git. If you change `sqlAdminPassword` after SQL Server has already initialized a Docker volume, remove/recreate that profile's database volume or SQL Server may still expect the old admin password.

Setup makes both the SQL Docker volume and in-SQL database name profile-specific, such as Docker volumes `horizon_database_data_uya` / `horizon_database_data_dl` and SQL databases `Horizon_UYA` / `Horizon_DL`.

To start with a fresh database for the active profile:

```bash
./run.sh delete-db
./run.sh reset-db
```

`delete-db` and `reset-db` remove the active profile DB volume without starting the server afterward. If a container is using that exact volume, the script stops only that container before removing the volume. Both commands show the active profile, volume name, and SQL database name, then require typing `delete <volume name>` before removing anything, such as `delete horizon_database_data_uya`.

## Daily Commands

Git Bash / WSL / Linux / macOS:

```bash
./run.sh help
./run.sh start           # DNS, database, middleware, patch, plugin, then server
./run.sh -a              # same as start
./run.sh stop            # stop Horizon compose services and horizon-dns
./run.sh restart         # stop, then run the full start sequence
./run.sh status          # show Horizon containers
./run.sh dns             # show DNAS IP and sampled hostname mappings
./run.sh logs            # follow horizon-server logs
./run.sh middleware-logs # follow horizon-middleware logs
./run.sh db-logs         # follow horizon-database logs
./run.sh sync-world      # sync profile app/world catalog into the active database
./run.sh delete-db       # delete the active profile DB volume
./run.sh reset-db        # delete the active profile DB volume
```

Target individual services:

```bash
./run.sh -s              # recreate/start horizon-server
./run.sh server-restart  # recreate horizon-server without rebuilding
./run.sh -d              # recreate/start horizon-database
./run.sh -m              # recreate/start horizon-middleware
```

DNS commands:

```bash
./run.sh dns-start       # start existing horizon-dns, or build/create it if missing
./run.sh dns-stop        # stop horizon-dns
./run.sh dns-build       # build horizon-dns image
./run.sh dns-restart     # build and recreate horizon-dns
```

Profile-aware build commands:

```bash
./run.sh -p              # rebuild patch repos for the active profile
./run.sh -l              # rebuild plugin repos for the active profile
./run.sh -e              # rebuild patch repos, then plugin repos
./run.sh -p dl           # rebuild Deadlocked patch once
./run.sh --profile uya -l   # rebuild UYA plugin once
./run.sh --profile dl -e    # rebuild Deadlocked patch repos, then plugin repos once
./run.sh server --no-plugin # recreate server without plugin mounts once
./run.sh restart --no-patch # restart stack without patch mounts once
./run.sh start --no-dns    # start stack without horizon-dns once
```

Windows PowerShell wrappers pass through to the Bash scripts:

```powershell
.\run.ps1 help
.\run.ps1 start
.\run.ps1 -a
.\run.ps1 stop
.\run.ps1 dns
.\run.ps1 logs
.\run.ps1 -p dl
.\run.ps1 --profile uya -l
```

## Command Reference

`run.sh` and `run.ps1` support the same commands.

| Command | Short option | What it does |
| --- | --- | --- |
| `start`, `up` | `-a` | Start DNS, database, middleware, build patch/plugin, then start server. |
| `stop`, `down` | `-x` | Stop Horizon compose services and horizon-dns. |
| `restart` | `-r` | Stop, then run the full start sequence. |
| `status` | `-t` | Show Horizon container status. |
| `server` | `-s` | Recreate/start only horizon-server. |
| `server-restart` | | Recreate horizon-server without rebuilding. |
| `database` | `-d` | Recreate/start only horizon-database. |
| `middleware` | `-m` | Recreate/start only horizon-middleware. |
| `logs` | | Follow horizon-server logs. |
| `middleware-logs` | | Follow horizon-middleware logs. |
| `db-logs` | | Follow horizon-database logs. |
| `sync-world` | | Sync profile app/world catalog into the active database. |
| `delete-db` | | Delete the active profile database volume without starting the server. |
| `reset-db` | | Delete the active profile database volume without starting the server. |
| `dns` | | Show DNAS IP and sampled DNS mappings. |
| `dns-build` | `-b` | Build the horizon-dns image. |
| `dns-restart` | `-n` | Build and recreate horizon-dns. |
| `rebuild-patch`, `build-patch` | `-p` | Rebuild patch repos for the active profile. |
| `rebuild-plugin`, `build-plugin` | `-l` | Rebuild plugin repos for the active profile. |
| `rebuild-all` | `-e` | Rebuild patch repos, then plugin repos for the active profile. |

## Active Profile

This setup is designed for one running Horizon server profile at a time. When `--profile` is omitted, `run.sh` chooses the profile in this order:

1. Explicit `--profile <profile>`, or a trailing profile like `./run.sh -p dl`.
2. `data/runtime/active-profile.json`, but only while `horizon-server` is currently running.
3. `defaultProfile` from `local.settings.json` when no server is running.

`start`, `server`, and `server-restart` write the runtime cache. `stop` / `-x` clears it. `server-restart` keeps the active profile information because it is still the same running server profile.

If the computer restarts without running `./run.sh stop`, the cache file may still exist, but it is ignored unless `horizon-server` is running. That means a fresh startup after reboot uses `defaultProfile` unless you pass `--profile`. If Docker is later configured to auto-start containers after reboot, the cached profile will still describe the running server.

Use `--no-plugin`, `--no-patch`, or `--no-dns` to disable those features for one command. For Docker mount changes, use a command that recreates the server container, such as `./run.sh server --no-plugin`, `./run.sh server --no-patch`, or `./run.sh restart --no-plugin --no-patch`.

## What Setup Does

- Clones/pulls the repos from the selected `profiles/<profile>.json`, skipping repos marked `kind: "plugin"`, `kind: "patch"`, `kind: "middleware-plugin"`, or `kind: "dns"` when disabled.
- Detects the host LAN IP.
- Updates `horizon-dns/config.json` so PS2 hostnames resolve to the host, when DNS is enabled.
- Generates `local.secrets.json` and `data/generated/.env` with profile-specific DB credentials and any enabled plugin/patch mount paths.
- Writes generated Horizon config files under `data/generated` and updates `db.config.json` for Docker-internal middleware access.
- Updates generated `medius.json` and `dme.json` public IP overrides.
- Applies local Docker fixes:
  - SQL Server 2022 image.
  - Stable profile-specific Docker named volume for SQL data.
  - Generated middleware build context with profile-specific SQL database init scripts and app/world catalog.
  - no manual `network_mode: bridge`.
  - middleware URL without trailing slash.
- Builds and starts `horizon-dns`, when DNS is enabled.
- Starts the generated Horizon Docker Compose stack from `data/generated`.
- Writes `data/runtime/active-profile.json` for the started profile.

## Notes

Do not set DNAS IP to `127.0.0.1`. Use the host LAN IP printed by setup or `./run.sh dns`. Loopback usually points at the client/emulated network side, not reliably at the Docker host.

On Windows, if Docker complains about volume paths, rerun your desired `run.sh` command from Git Bash. The script refreshes `data/generated/.env` plugin and patch paths before Docker Compose runs.
