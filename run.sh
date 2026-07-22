#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/local.settings.json"

usage() {
  cat <<'USAGE'
Usage: ./run.sh <command|option> [profile]
       ./run.sh <command|option> --profile <profile>

Commands:
  help              Show this help.
  start             Alias for up.
  up                Start DNS, database, middleware, patch, plugin, then server.
  server            Recreate/start only horizon-server.
  server-restart    Recreate only horizon-server without rebuilding.
  database          Recreate/start only horizon-database.
  middleware        Recreate/start only horizon-middleware.
  stop              Stop all related containers: Horizon compose stack and horizon-dns.
  down              Alias for stop.
  restart           Stop, then run the full start sequence.
  status            Show Docker container status.
  logs              Follow horizon-server logs.
  middleware-logs   Follow middleware logs.
  db-logs           Follow SQL Server logs.
  sync-world        Sync profile world locations/channels into the active database.
  delete-db         Delete the active profile database volume.
  reset-db          Delete the active profile database volume.
  dns               Show DNAS IP and sampled DNS hostname mappings.
  dns-start         Start existing horizon-dns container, or run it if missing.
  dns-stop          Stop horizon-dns.
  dns-build         Build horizon-dns image.
  dns-restart       Build and restart horizon-dns container.
  rebuild-patch     Run build.sh in profile patch repos.
  build-patch       Alias for rebuild-patch.
  rebuild-plugin    Run build.sh in profile plugin repos.
  build-plugin      Alias for rebuild-plugin.
  rebuild-all       Rebuild patch repos, then plugin repos from the active profile.

Options:
  -h, --help              Show this help.
  --profile <profile>     Override active-profile detection/defaultProfile for this command.
  --no-plugin             Disable plugin mounts/builds for this command.
  --no-patch              Disable patch mounts/builds for this command.
  --no-dns                Disable horizon-dns actions for this command.
  -a, --all, --up         Start DNS, database, middleware, patch, plugin, then server.
  -s, --server            Recreate/start only horizon-server.
  -d, --database          Recreate/start only horizon-database.
  -m, --middleware        Recreate/start only horizon-middleware.
  -x, --stop              Stop all related containers.
  -r, --restart           Stop, then run the full start sequence.
  -t, --status            Show Docker container status.
  --middleware-logs       Follow middleware logs.
  --db-logs               Follow SQL Server logs.
  --dns                   Show DNAS IP and sampled DNS hostname mappings.
  -b, --dns-build         Build horizon-dns image.
  -n, --dns-restart       Build and restart horizon-dns container.
  -p, --patch             Rebuild patch repos.
  -l, --plugin            Rebuild plugin repos.
  -e, --everything        Rebuild patch repos, then plugin repos.

Examples:
  ./run.sh start
  ./run.sh -a
  ./run.sh -s
  ./run.sh -d
  ./run.sh -m
  ./run.sh dns
  ./run.sh stop
  ./run.sh delete-db
  ./run.sh reset-db
  ./run.sh -p dl
  ./run.sh --profile uya -l
  ./run.sh server --no-plugin
  ./run.sh restart --no-patch
  ./run.sh start --no-dns
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

json_get() {
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
cur = data
for part in expr.split('.'):
    if not part:
        continue
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print('')
        raise SystemExit(0)
if isinstance(cur, bool):
    print('true' if cur else 'false')
elif isinstance(cur, (list, dict)):
    print(json.dumps(cur))
elif cur is None:
    print('')
else:
    print(cur)
PY
}

abs_path() {
  python3 - "$1" "$SCRIPT_DIR" <<'PY'
import os, sys
path, base = sys.argv[1], sys.argv[2]
if not os.path.isabs(path):
    path = os.path.join(base, path)
print(os.path.abspath(path))
PY
}

normalize_command() {
  case "$1" in
    -a|--all|--up) echo "up" ;;
    -s|--server) echo "server" ;;
    -d|--database) echo "database" ;;
    -m|--middleware) echo "middleware" ;;
    -x|--stop) echo "stop" ;;
    -r|--restart) echo "restart" ;;
    -t|--status) echo "status" ;;
    --middleware-logs) echo "middleware-logs" ;;
    --db-logs) echo "db-logs" ;;
    --dns) echo "dns" ;;
    -b|--dns-build) echo "dns-build" ;;
    -n|--dns-restart) echo "dns-restart" ;;
    -p|--patch) echo "rebuild-patch" ;;
    -l|--plugin) echo "rebuild-plugin" ;;
    -e|--everything) echo "rebuild-all" ;;
    *) echo "$1" ;;
  esac
}

is_profile() {
  [ -n "$1" ] && [ -f "$SCRIPT_DIR/profiles/$1.json" ]
}

server_running() {
  docker ps --format '{{.Names}}' | grep -qx horizon-server
}

detect_active_profile() {
  [ -n "${STATE_FILE:-}" ] || return 0
  server_running || return 0
  [ -f "$STATE_FILE" ] || return 0

  python3 - "$STATE_FILE" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding='utf-8'))
except Exception:
    raise SystemExit(0)
profile = str(data.get('profile') or '').strip()
if profile:
    print(profile)
PY
}

write_active_profile_state() {
  local profile_name profile_file
  profile_name="$1"
  profile_file="$2"
  mkdir -p "$(dirname "$STATE_FILE")"
  python3 - "$STATE_FILE" "$profile_name" "$profile_file" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
path = Path(sys.argv[1])
data = {
    'profile': sys.argv[2],
    'profileFile': sys.argv[3],
    'startedAt': datetime.now(timezone.utc).isoformat(),
}
path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
PY
}

clear_active_profile_state() {
  [ -n "${STATE_FILE:-}" ] || return 0
  rm -f "$STATE_FILE"
}

[ $# -gt 0 ] || { usage; exit 1; }
COMMAND=""
PROFILE_OVERRIDE=""
INCLUDE_PLUGIN_OVERRIDE=""
INCLUDE_PATCH_OVERRIDE=""
INCLUDE_DNS_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help)
      usage
      exit 0
      ;;
    --profile)
      shift
      [ $# -gt 0 ] || fail "--profile requires a profile name"
      is_profile "$1" || fail "Unknown profile: $1"
      [ -z "$PROFILE_OVERRIDE" ] || fail "Profile was provided more than once"
      PROFILE_OVERRIDE="$1"
      ;;
    --no-plugin)
      INCLUDE_PLUGIN_OVERRIDE="false"
      ;;
    --no-patch)
      INCLUDE_PATCH_OVERRIDE="false"
      ;;
    --no-dns)
      INCLUDE_DNS_OVERRIDE="false"
      ;;
    *)
      if is_profile "$1"; then
        [ -z "$PROFILE_OVERRIDE" ] || fail "Profile was provided more than once"
        PROFILE_OVERRIDE="$1"
      elif [ -z "$COMMAND" ]; then
        COMMAND="$(normalize_command "$1")"
      else
        fail "Unexpected extra argument: $1"
      fi
      ;;
  esac
  shift
done
[ -n "$COMMAND" ] || fail "Command is required. Run ./run.sh help."

[ -f "$SETTINGS_FILE" ] || fail "local.settings.json is missing. Run ./setup.sh <profile> first."
command -v python3 >/dev/null 2>&1 || fail "Missing python3"
command -v docker >/dev/null 2>&1 || fail "Missing docker"

INSTALL_ROOT_SETTING="$(json_get "$SETTINGS_FILE" installRoot)"
[ -n "$INSTALL_ROOT_SETTING" ] || INSTALL_ROOT_SETTING="./repos"
INSTALL_ROOT="$(abs_path "$INSTALL_ROOT_SETTING")"
GENERATED_ROOT_SETTING="$(json_get "$SETTINGS_FILE" generatedRoot)"
[ -n "$GENERATED_ROOT_SETTING" ] || GENERATED_ROOT_SETTING="./data/generated"
GENERATED_ROOT="$(abs_path "$GENERATED_ROOT_SETTING")"
DATA_ROOT_SETTING="$(json_get "$SETTINGS_FILE" dataRoot)"
[ -n "$DATA_ROOT_SETTING" ] || DATA_ROOT_SETTING="./data"
DATA_ROOT="$(abs_path "$DATA_ROOT_SETTING")"
LOG_ROOT="$SCRIPT_DIR/logs"
STATE_FILE="$DATA_ROOT/runtime/active-profile.json"
DEFAULT_PROFILE="$(json_get "$SETTINGS_FILE" defaultProfile)"
ACTIVE_PROFILE=""
PROFILE_SOURCE="defaultProfile"
if [ -n "$PROFILE_OVERRIDE" ]; then
  PROFILE="$PROFILE_OVERRIDE"
  PROFILE_SOURCE="--profile"
else
  ACTIVE_PROFILE="$(detect_active_profile)"
  if [ -n "$ACTIVE_PROFILE" ]; then
    PROFILE="$ACTIVE_PROFILE"
    PROFILE_SOURCE="active-profile cache"
  else
    PROFILE="$DEFAULT_PROFILE"
  fi
fi
INCLUDE_PLUGIN="$(json_get "$SETTINGS_FILE" includePlugin)"
[ -n "$INCLUDE_PLUGIN" ] || INCLUDE_PLUGIN="true"
[ -z "$INCLUDE_PLUGIN_OVERRIDE" ] || INCLUDE_PLUGIN="$INCLUDE_PLUGIN_OVERRIDE"
INCLUDE_PATCH="$(json_get "$SETTINGS_FILE" includePatch)"
[ -n "$INCLUDE_PATCH" ] || INCLUDE_PATCH="true"
[ -z "$INCLUDE_PATCH_OVERRIDE" ] || INCLUDE_PATCH="$INCLUDE_PATCH_OVERRIDE"
INCLUDE_DNS="$(json_get "$SETTINGS_FILE" includeDns)"
[ -n "$INCLUDE_DNS" ] || INCLUDE_DNS="true"
[ -z "$INCLUDE_DNS_OVERRIDE" ] || INCLUDE_DNS="$INCLUDE_DNS_OVERRIDE"
is_profile "$PROFILE" || fail "Unknown profile: $PROFILE"
case "$INCLUDE_PLUGIN" in true|false) ;; *) fail "includePlugin must be true or false" ;; esac
case "$INCLUDE_PATCH" in true|false) ;; *) fail "includePatch must be true or false" ;; esac
case "$INCLUDE_DNS" in true|false) ;; *) fail "includeDns must be true or false" ;; esac
PROFILE_FILE="$SCRIPT_DIR/profiles/$PROFILE.json"
[ -d "$INSTALL_ROOT" ] || fail "Repos root does not exist: $INSTALL_ROOT"
mkdir -p "$GENERATED_ROOT" "$DATA_ROOT" "$LOG_ROOT" "$(dirname "$STATE_FILE")"
[ -f "$PROFILE_FILE" ] || fail "Profile does not exist: $PROFILE_FILE"

refresh_compose_mount_paths() {
  python3 - "$INSTALL_ROOT" "$GENERATED_ROOT" "$DATA_ROOT" "$LOG_ROOT" "$PROFILE_FILE" "$INCLUDE_PLUGIN" "$INCLUDE_PATCH" <<'PY'
import json, os, re, shutil, sqlite3, sys, time
from pathlib import Path

root = Path(sys.argv[1]).resolve()
generated = Path(sys.argv[2]).resolve()
data_root = Path(sys.argv[3]).resolve()
log_root = Path(sys.argv[4]).resolve()
profile_path = Path(sys.argv[5])
include_plugin = sys.argv[6] == 'true'
include_patch = sys.argv[7] == 'true'
generated.mkdir(parents=True, exist_ok=True)
data_root.mkdir(parents=True, exist_ok=True)
log_root.mkdir(parents=True, exist_ok=True)
profile = json.loads(profile_path.read_text(encoding='utf-8'))
updates = {}
profile_id = profile.get('id') or 'default'
database = profile.get('database', {})
db_name = database.get('name') or f'Horizon_{profile_id.upper()}'
if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', db_name):
    raise SystemExit(f'Invalid database.name {db_name!r}; use letters, numbers, and underscores, starting with a letter')
app_ids = profile.get('appIds', [])
app_id_csv = ','.join(str(app_id) for app_id in app_ids)
updates['HORIZON_DB_NAME'] = db_name
updates['HORIZON_APP_ID'] = app_id_csv

middleware_src = root / 'horizon-server-database-middleware'
middleware_build = generated / 'build' / 'horizon-server-database-middleware'
def remove_tree(path):
    for attempt in range(8):
        if not path.exists():
            return
        try:
            shutil.rmtree(path)
            return
        except OSError:
            if attempt == 7:
                raise
            time.sleep(0.5)

def prepare_middleware_build_context():
    if not middleware_src.exists():
        raise SystemExit(f'Missing required checkout: {middleware_src}')
    tmp = middleware_build.with_name(f'{middleware_build.name}.tmp.{os.getpid()}')
    remove_tree(tmp)
    shutil.copytree(middleware_src, tmp, ignore=shutil.ignore_patterns('.git', 'bin', 'obj'))
    for required in ['Dockerfile', 'entrypoint.sh', 'Horizon.Database.sln', 'Horizon.Database']:
        if not (tmp / required).exists():
            raise SystemExit(f'Middleware build context is missing required file: {tmp / required}')
    for script_name in ['CREATE_DATABASE.sql', 'CREATE_TABLES.sql']:
        script = tmp / 'Horizon.Database' / 'scripts' / script_name
        if script.exists():
            script.write_text(script.read_text(encoding='utf-8').replace('Medius_Database', db_name), encoding='utf-8')
    remove_tree(middleware_build)
    tmp.rename(middleware_build)

def validate_feature_config(profile, feature, required_keys, enabled):
    config = profile.get(feature)
    if not enabled:
        return None
    if config is None:
        return None
    if not isinstance(config, dict):
        raise SystemExit(f'profile {profile.get("id", "unknown")} {feature} must be an object')
    missing = [key for key in required_keys if not str(config.get(key, '')).strip()]
    if missing:
        fields = ', '.join(f'{feature}.{key}' for key in missing)
        raise SystemExit(f'profile {profile.get("id", "unknown")} missing required {fields} when include{feature.capitalize()} is true')
    return config
def profile_dns_hostnames(profile):
    hostnames = []
    dns_config = profile.get('dns') if isinstance(profile.get('dns'), dict) else {}
    raw_dns_hostnames = dns_config.get('hostnames', [])
    if isinstance(raw_dns_hostnames, list):
        hostnames.extend(str(host).strip() for host in raw_dns_hostnames)
    muis_config = profile.get('muis') if isinstance(profile.get('muis'), dict) else {}
    raw_entrypoints = muis_config.get('entrypoints', [])
    if isinstance(raw_entrypoints, list):
        for entry in raw_entrypoints:
            if isinstance(entry, dict):
                hostnames.append(str(entry.get('endpoint', '')).strip())
    elif isinstance(muis_config.get('endpoint'), str):
        hostnames.append(muis_config['endpoint'].strip())
    seen = set()
    unique = []
    for hostname in hostnames:
        if not hostname or hostname.replace('.', '').replace('-', '').isdigit():
            continue
        key = hostname.lower()
        if key in seen:
            continue
        seen.add(key)
        unique.append(hostname)
    return unique

plugin_config = validate_feature_config(profile, 'plugin', ['repo', 'mediusPath', 'dmePath'], include_plugin)
patch_config = validate_feature_config(profile, 'patch', ['repo', 'miscPath', 'binPath'], include_patch)
middleware_plugin_config = validate_feature_config(profile, 'middlewarePlugin', ['repo', 'path'], include_plugin)
env_path = generated / '.env'
server_volume_lines = []
middleware_volume_lines = []
if plugin_config:
    plugin = root / plugin_config['repo']
    plugin_database = data_root / 'databases' / profile_id / 'database'
    plugin_database.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(plugin_database / 'database.db') as con:
        con.execute('CREATE TABLE IF NOT EXISTS users (username TEXT, password TEXT, ladderstatswide TEXT)')
    updates['HORIZON_MEDIUS_PLUGIN_PATH'] = str(plugin / plugin_config.get('mediusPath', 'out/medius')) + '/'
    updates['HORIZON_DME_PLUGIN_PATH'] = str(plugin / plugin_config.get('dmePath', 'out/dme')) + '/'
    updates['HORIZON_ROBO_DATABASE_PATH'] = str(plugin_database)
    server_volume_lines.extend([
        '      - ${HORIZON_MEDIUS_PLUGIN_PATH}:/medius/plugins/',
        '      - ${HORIZON_DME_PLUGIN_PATH}:/dme/plugins/',
        '      - ${HORIZON_ROBO_DATABASE_PATH}:/database',
    ])
if patch_config:
    patch = root / patch_config['repo']
    updates['HORIZON_PATCH_MISC_PATH'] = str(patch / patch_config.get('miscPath', 'misc'))
    updates['HORIZON_PATCH_BIN_PATH'] = str(patch / patch_config.get('binPath', 'bin'))
    server_volume_lines.extend([
        '      - ${HORIZON_PATCH_MISC_PATH}:/medius/plugins/bin/',
        '      - ${HORIZON_PATCH_BIN_PATH}:/medius/plugins/bin/patch/',
    ])
if middleware_plugin_config:
    middleware_plugin = root / middleware_plugin_config['repo']
    updates['HORIZON_MIDDLEWARE_PLUGIN_PATH'] = str(middleware_plugin / middleware_plugin_config.get('path', 'out/plugin'))
    middleware_volume_lines.append('      - ${HORIZON_MIDDLEWARE_PLUGIN_PATH}:/plugins/')
    appsettings_path = generated / 'appsettings.json'
    if appsettings_path.exists():
        appsettings = json.loads(appsettings_path.read_text(encoding='utf-8'))
        connection_strings = appsettings.setdefault('ConnectionStrings', {})
        connection_strings['DbConnection'] = 'Data Source={_SERVER};Initial Catalog={_DBNAME};Persist Security Info=True;TrustServerCertificate=true;User ID={_USERNAME};Password={_PASSWORD};'
        appsettings['Plugins'] = '/plugins/'
        appsettings_path.write_text(json.dumps(appsettings, indent=2) + '\n', encoding='utf-8')

medius_path = generated / 'medius.json'
server_ip = ''
if medius_path.exists():
    try:
        medius = json.loads(medius_path.read_text(encoding='utf-8'))
        server_ip = medius.get('PublicIpOverride') or ''
    except json.JSONDecodeError:
        server_ip = ''
if server_ip:
    dns_config_path = root / 'horizon-dns' / 'config.json'
    if dns_config_path.exists():
        dns_config = json.loads(dns_config_path.read_text(encoding='utf-8'))
        for key in list(dns_config.keys()):
            dns_config[key] = server_ip
        for hostname in profile_dns_hostnames(profile):
            dns_config[hostname] = server_ip
        dns_config_path.write_text(json.dumps(dns_config, indent=2) + '\n', encoding='utf-8')
appsettings_path = generated / 'appsettings.json'
if appsettings_path.exists():
    appsettings = json.loads(appsettings_path.read_text(encoding='utf-8'))
    connection_strings = appsettings.setdefault('ConnectionStrings', {})
    connection_strings['DbConnection'] = 'Data Source={_SERVER};Initial Catalog={_DBNAME};Persist Security Info=True;TrustServerCertificate=true;User ID={_USERNAME};Password={_PASSWORD};'
    group_name = (profile.get('id') or 'default').upper()
    default_settings = {
        'EnableEncryption': 'False',
        'CreateAccountOnNotFound': 'True',
        'ClientLongTimeoutSeconds': 50,
        'ClientTimeoutSeconds': 50,
        'DmeTimeoutSeconds': 50,
        'KeepAliveGracePeriodSeconds': 50,
        'GameTimeoutSeconds': 50,
        'TextFilterAccountName': r'[^\x20-\x80]+|.{{15,}}',
    }
    world = profile.get('world') or {}
    locations = [
        {
            'Id': int(world.get('locationId', 40)),
            'Name': str(world.get('locationName') or profile.get('name') or group_name),
        }
    ]
    channel_id = int(world.get('channelId', 1))
    channel_name = str(world.get('channelName') or 'CY00000000-00')
    appsettings['AppGroups'] = [{'Name': group_name}]
    appsettings['Apps'] = [
        {
            'GroupName': group_name,
            'Name': profile.get('name', f'App {app_id}') if index == 0 else f'{profile.get("name", "App")} ({app_id})',
            'Id': app_id,
            'Announcements': [{'Title': 'Welcome to Horizon!', 'Body': 'https://discord.gg/horizonps'}],
            'ServerSettings': dict(default_settings),
        }
        for index, app_id in enumerate(app_ids)
    ]
    appsettings['Locations'] = [
        {'Id': location['Id'], 'AppId': app_id, 'Name': location['Name']}
        for app_id in app_ids
        for location in locations
    ]
    appsettings['Channels'] = [
        {
            'Id': channel_id,
            'AppId': app_id,
            'Name': channel_name,
            'MaxPlayers': 256,
            'GenericField1': 0,
            'GenericField2': 0,
            'GenericField3': 0,
            'GenericField4': 0,
            'GenericFieldFilter': 32,
        }
        for app_id in app_ids
    ]
    if middleware_plugin_config:
        appsettings['Plugins'] = '/plugins/'
    else:
        appsettings.pop('Plugins', None)
    appsettings_path.write_text(json.dumps(appsettings, indent=2) + '\n', encoding='utf-8')
# MUIS entrypoints advertised to the game client.
muis_path = generated / 'muis.json'
if muis_path.exists():
    muis = json.loads(muis_path.read_text(encoding='utf-8'))
    muis_config = profile.get('muis') if isinstance(profile.get('muis'), dict) else {}
    muis_port = int(muis_config.get('port', 10075))
    muis_universe_id = int(muis_config.get('universeId', 1))
    muis['EncryptMessages'] = bool(muis_config.get('encryptMessages', muis.get('EncryptMessages', True)))

    raw_entrypoints = muis_config.get('entrypoints')
    if isinstance(raw_entrypoints, list) and raw_entrypoints:
        entrypoint_configs = [entry for entry in raw_entrypoints if isinstance(entry, dict)]
    else:
        entrypoint_configs = [muis_config]

    universe_entries = []
    for entry_config in entrypoint_configs:
        universe_entries.append({
            'Enabled': bool(entry_config.get('enabled', muis_config.get('enabled', True))),
            'Name': str(entry_config.get('name') or muis_config.get('name') or profile.get('name') or profile.get('id') or 'Horizon'),
            'Description': entry_config.get('description', muis_config.get('description')),
            'Endpoint': str(entry_config.get('endpoint') or muis_config.get('endpoint') or server_ip),
            'SvoURL': entry_config.get('svoUrl', muis_config.get('svoUrl')),
            'ExtendedInfo': entry_config.get('extendedInfo', muis_config.get('extendedInfo')),
            'Port': muis_port,
            'UniverseId': muis_universe_id,
        })

    muis['Universes'] = {'0': [dict(entry) for entry in universe_entries]}
    for app_id in app_ids:
        muis['Universes'][str(app_id)] = [dict(entry) for entry in universe_entries]
    logging = muis.setdefault('Logging', {})
    logging['LogToConsole'] = True
    logging['LogPath'] = '/logs/muis.log'
    muis_path.write_text(json.dumps(muis, indent=2) + '\n', encoding='utf-8')

updates = {k: v.replace('\\', '/') for k, v in updates.items()}
optional_env_keys = {
    'HORIZON_MEDIUS_PLUGIN_PATH',
    'HORIZON_DME_PLUGIN_PATH',
    'HORIZON_ROBO_DATABASE_PATH',
    'HORIZON_PATCH_MISC_PATH',
    'HORIZON_PATCH_BIN_PATH',
    'HORIZON_MIDDLEWARE_PLUGIN_PATH',
}
remove_keys = optional_env_keys - set(updates)
lines = env_path.read_text(encoding='utf-8').splitlines() if env_path.exists() else []
seen = set()
out = []
for line in lines:
    if not line.strip() or line.lstrip().startswith('#') or '=' not in line:
        out.append(line)
        continue
    key = line.split('=', 1)[0].strip()
    if key in updates:
        out.append(f'{key}={updates[key]}')
        seen.add(key)
    elif key not in remove_keys:
        out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f'{key}={value}')
env_path.write_text('\n'.join(out) + '\n', encoding='utf-8')

compose_path = generated / 'docker-compose.yml'
def docker_path(path):
    return str(path.resolve()).replace('\\', '/')
prepare_middleware_build_context()
if compose_path.exists():
    compose = compose_path.read_text(encoding='utf-8')
    compose = re.sub(r'^version:\s*[^\n]+\n', '', compose, count=1, flags=re.MULTILINE)
    compose = compose.replace('mcr.microsoft.com/mssql/server:2019-latest', 'mcr.microsoft.com/mssql/server:2022-latest')
    compose = re.sub(
        r'(?m)^(\s*)image:\s*horizonprivateserver/horizon-server\s*$',
        lambda m: f'{m.group(1)}image: horizon-server-local\n{m.group(1)}build:\n{m.group(1)}  context: {docker_path(root / "horizon-server")}',
        compose,
    )
    compose = re.sub(
        r'(?m)^(\s*context:\s*)(?:\.\./horizon-server|[^\n]*horizon-server)\s*$',
        lambda m: f'{m.group(1)}{docker_path(root / "horizon-server")}',
        compose,
        count=1,
    )
    middleware_context = docker_path(middleware_build)
    compose = re.sub(
        r'(?ms)^(\s*horizon-middleware:\n)(?:(?:\s*image:[^\n]*\n)|(?:\s*build:\s*\n\s*context:[^\n]*\n))+',
        lambda m: f'{m.group(1)}    image: horizon-middleware-local\n    build:\n      context: {middleware_context}\n',
        compose,
    )
    compose = compose.replace('ACCEPT_EULA=True', 'ACCEPT_EULA=Y')
    compose = re.sub(r'^\s*network_mode:\s*bridge\s*\n', '', compose, flags=re.MULTILINE)
    compose = re.sub(r'^\s*user:\s*root\s*\n', '', compose, flags=re.MULTILINE)
    volume_name = 'horizon_database_data_' + re.sub(r'[^A-Za-z0-9_-]+', '_', profile.get('id') or 'default').strip('_')
    compose = compose.replace('./logs:/logs', docker_path(log_root) + ':/logs')
    compose = compose.replace('./database_backup:/backup', docker_path(data_root / 'database-backup') + ':/backup')
    compose = compose.replace('./database_data:/var/opt/mssql', f'{volume_name}:/var/opt/mssql')
    compose = compose.replace('"./database_data:/var/opt/mssql"', f'{volume_name}:/var/opt/mssql')
    compose = re.sub(r'horizon_database_data(?:_[A-Za-z0-9_-]+)?(?=:/var/opt/mssql)', volume_name, compose)
    compose = re.sub(r'(?ms)^volumes:\s*\n.*\Z', '', compose).rstrip()
    compose = compose + f'\nvolumes:\n  {volume_name}:\n    name: {volume_name}\n'
    compose_path.write_text(compose, encoding='utf-8')

override_path = generated / 'docker-compose.override.yml'
sections = []
if server_volume_lines:
    sections.append('  horizon-server:\n    volumes:\n' + '\n'.join(server_volume_lines))
if middleware_volume_lines:
    sections.append('  horizon-middleware:\n    volumes:\n' + '\n'.join(middleware_volume_lines))
if sections:
    override = 'services:\n' + '\n'.join(sections) + '\n'
    override_path.write_text(override, encoding='utf-8')
elif override_path.exists():
    override_path.unlink()
PY
}

compose() {
  refresh_compose_mount_paths
  (cd "$GENERATED_ROOT" && docker compose "$@")
}

compose_recreate() {
  compose up -d --build --force-recreate "$@"
}

env_value() {
  python3 - "$GENERATED_ROOT/.env" "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
if not path.exists():
    raise SystemExit(0)
for line in path.read_text(encoding='utf-8').splitlines():
    if not line or line.lstrip().startswith('#') or '=' not in line:
        continue
    name, value = line.split('=', 1)
    if name == key:
        print(value)
        break
PY
}

wait_for_database() {
  local password i
  password="$(env_value HORIZON_MSSQL_SA_PASSWORD)"
  [ -n "$password" ] || fail "Missing HORIZON_MSSQL_SA_PASSWORD in $GENERATED_ROOT/.env"

  for i in $(seq 1 60); do
    if docker exec horizon-database /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$password" -Q "SELECT 1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail "Timed out waiting for horizon-database to accept SQL connections"
}

sync_world_catalog() {
  local password db_name sql_file container_sql
  [ -f "$GENERATED_ROOT/appsettings.json" ] || fail "Missing generated appsettings.json. Run ./setup.sh $PROFILE first."
  docker ps --format '{{.Names}}' | grep -qx horizon-database || fail "horizon-database is not running. Start the database before syncing world catalog."
  wait_for_database

  password="$(env_value HORIZON_MSSQL_SA_PASSWORD)"
  db_name="$(env_value HORIZON_DB_NAME)"
  [ -n "$db_name" ] || fail "Missing HORIZON_DB_NAME in $GENERATED_ROOT/.env"
  mkdir -p "$DATA_ROOT/runtime"
  sql_file="$DATA_ROOT/runtime/sync-world-$PROFILE.sql"
  container_sql="/tmp/sync-world-$PROFILE.sql"

  python3 - "$PROFILE_FILE" "$GENERATED_ROOT/appsettings.json" "$sql_file" <<'PY'
import json, sys
from pathlib import Path
profile_path, appsettings_path, out_path = [Path(x) for x in sys.argv[1:4]]
profile = json.loads(profile_path.read_text(encoding='utf-8'))
appsettings = json.loads(appsettings_path.read_text(encoding='utf-8'))
app_ids = [int(app_id) for app_id in profile.get('appIds', [])]
if not app_ids:
    raise SystemExit('Profile has no appIds; cannot sync world catalog')

def sql_string(value):
    return "N'" + str(value).replace("'", "''") + "'"

def setting_pairs(settings):
    for key, value in (settings or {}).items():
        yield key, str(value)

app_id_list = ', '.join(str(app_id) for app_id in app_ids)
group_names = [str(group['Name']) for group in appsettings.get('AppGroups') or [] if isinstance(group, dict) and group.get('Name')]
owned_setting_names = sorted({name for app in appsettings.get('Apps') or [] for name, _ in setting_pairs(app.get('ServerSettings'))})
lines = [
    'SET XACT_ABORT ON;',
    'BEGIN TRANSACTION;',
    f'DELETE FROM [WORLD].[channels];',
    f'DELETE FROM [WORLD].[locations];',
    f'DELETE FROM [KEYS].[dim_announcements] WHERE [app_id] NOT IN ({app_id_list});',
    f'DELETE FROM [KEYS].[server_settings] WHERE [app_id] NOT IN ({app_id_list});',
    f'DELETE FROM [KEYS].[dim_app_ids] WHERE [app_id] NOT IN ({app_id_list});',
]
if group_names:
    group_list = ', '.join(sql_string(name) for name in group_names)
    lines.append(f'DELETE FROM [KEYS].[dim_app_groups] WHERE [group_name] NOT IN ({group_list}) AND [group_id] NOT IN (SELECT DISTINCT [group_id] FROM [KEYS].[dim_app_ids] WHERE [group_id] IS NOT NULL);')
for group_name in group_names:
    group_sql = sql_string(group_name)
    lines.append(f"IF NOT EXISTS (SELECT 1 FROM [KEYS].[dim_app_groups] WHERE [group_name] = {group_sql}) INSERT INTO [KEYS].[dim_app_groups] ([group_name]) VALUES ({group_sql});")
for app in appsettings.get('Apps') or []:
    app_id = int(app['Id'])
    if app_id not in app_ids:
        continue
    group_name = sql_string(app['GroupName'])
    app_name = sql_string(app['Name'])
    lines.append(f"DECLARE @group_id_{app_id} int;")
    lines.append(f"SELECT @group_id_{app_id} = [group_id] FROM [KEYS].[dim_app_groups] WHERE [group_name] = {group_name};")
    lines.append(f"IF EXISTS (SELECT 1 FROM [KEYS].[dim_app_ids] WHERE [app_id] = {app_id}) UPDATE [KEYS].[dim_app_ids] SET [app_name] = {app_name}, [group_id] = @group_id_{app_id} WHERE [app_id] = {app_id}; ELSE INSERT INTO [KEYS].[dim_app_ids] ([app_id], [app_name], [group_id]) VALUES ({app_id}, {app_name}, @group_id_{app_id});")
    lines.append(f"DELETE FROM [KEYS].[dim_announcements] WHERE [app_id] = {app_id};")
    for announcement in app.get('Announcements') or []:
        lines.append('INSERT INTO [KEYS].[dim_announcements] ([announcement_title], [announcement_body], [create_dt], [modified_dt], [from_dt], [app_id]) '
                     f"VALUES ({sql_string(announcement.get('Title', ''))}, {sql_string(announcement.get('Body', ''))}, getdate(), getdate(), getdate(), {app_id});")
    if owned_setting_names:
        setting_list = ', '.join(sql_string(name) for name in owned_setting_names)
        lines.append(f"DELETE FROM [KEYS].[server_settings] WHERE [app_id] = {app_id} AND [name] IN ({setting_list});")
    for key, value in setting_pairs(app.get('ServerSettings')):
        lines.append(f"INSERT INTO [KEYS].[server_settings] ([app_id], [name], [value]) VALUES ({app_id}, {sql_string(key)}, {sql_string(value)});")
for location in appsettings.get('Locations') or []:
    app_id = int(location['AppId'])
    if app_id not in app_ids:
        continue
    lines.append('INSERT INTO [WORLD].[locations] ([id], [app_id], [name]) '
                 f"VALUES ({int(location['Id'])}, {app_id}, {sql_string(location['Name'])});")
for channel in appsettings.get('Channels') or []:
    app_id = int(channel['AppId'])
    if app_id not in app_ids:
        continue
    lines.append('INSERT INTO [WORLD].[channels] ([id], [app_id], [name], [max_players], [generic_field_1], [generic_field_2], [generic_field_3], [generic_field_4], [generic_field_filter]) '
                 f"VALUES ({int(channel['Id'])}, {app_id}, {sql_string(channel['Name'])}, {int(channel['MaxPlayers'])}, {int(channel['GenericField1'])}, {int(channel['GenericField2'])}, {int(channel['GenericField3'])}, {int(channel['GenericField4'])}, {int(channel['GenericFieldFilter'])});")
lines.extend(['COMMIT TRANSACTION;', ''])
out_path.write_text('\n'.join(lines), encoding='utf-8')
PY

  echo "Syncing world catalog for $PROFILE into $db_name..."
  docker cp "$sql_file" "horizon-database:$container_sql"
  docker exec horizon-database /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$password" -d "$db_name" -i "$container_sql"
}

dns_enabled() {
  [ "$INCLUDE_DNS" = "true" ]
}

need_dns() {
  dns_enabled || fail "horizon-dns is disabled for this command. Enable includeDns or omit --no-dns."
  [ -d "$INSTALL_ROOT/horizon-dns" ] || fail "Missing horizon-dns checkout: $INSTALL_ROOT/horizon-dns"
}

dns_build() {
  need_dns
  (cd "$INSTALL_ROOT/horizon-dns" && docker build . -t horizon-dns)
}

dns_restart() {
  need_dns
  docker rm -f horizon-dns >/dev/null 2>&1 || true
  docker run -d --rm -p 443:443 -p 53:53/udp -p 53:53/tcp --name horizon-dns horizon-dns
}

dns_start() {
  if ! dns_enabled; then
    echo "horizon-dns is disabled; skipping."
  elif docker ps --format '{{.Names}}' | grep -qx horizon-dns; then
    echo "horizon-dns is already running."
  elif docker start horizon-dns >/dev/null 2>&1; then
    echo "Started existing horizon-dns container."
  else
    echo "No existing horizon-dns container found; building and creating one."
    dns_build
    dns_restart
  fi
}

stop_all() {
  if dns_enabled; then
    echo "Stopping horizon-dns container if present..."
    docker rm -f horizon-dns >/dev/null 2>&1 || true
  else
    echo "horizon-dns is disabled; skipping."
  fi
  echo "Stopping Horizon compose stack..."
  compose down || true
  echo "Stopping named Horizon containers if present..."
  docker rm -f horizon-server horizon-middleware horizon-database >/dev/null 2>&1 || true
  clear_active_profile_state
}

show_dns() {
  refresh_compose_mount_paths
  if ! dns_enabled; then
    echo "horizon-dns is disabled. Enable includeDns or omit --no-dns to use DNS helpers."
    return 0
  fi
  local dns_config="$INSTALL_ROOT/horizon-dns/config.json"
  local medius_config="$GENERATED_ROOT/medius.json"
  local dme_config="$GENERATED_ROOT/dme.json"

  python3 - "$dns_config" "$medius_config" "$dme_config" <<'PY'
import json, sys
from collections import Counter
from pathlib import Path

dns_path, medius_path, dme_path = [Path(x) for x in sys.argv[1:4]]

def read(path):
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding='utf-8'))

dns = read(dns_path) or {}
medius = read(medius_path) or {}
dme = read(dme_path) or {}
values = [str(v) for v in dns.values() if v]
counts = Counter(values)
likely_ip = counts.most_common(1)[0][0] if counts else ''
if not likely_ip:
    likely_ip = medius.get('PublicIpOverride') or dme.get('PublicIpOverride') or ''

print('DNAS IP:')
if likely_ip:
    print(f'  {likely_ip}')
else:
    print('  unknown - run setup first or check horizon-dns/config.json')

print('')
print('Server public IP overrides:')
print(f"  medius.json: {medius.get('PublicIpOverride', 'missing')}")
print(f"  dme.json:    {dme.get('PublicIpOverride', 'missing')}")

if dns:
    print('')
    print(f'DNS mappings loaded: {len(dns)}')
    for host in list(dns.keys())[:8]:
        print(f'  {host} -> {dns[host]}')
    if len(dns) > 8:
        print(f'  ... {len(dns) - 8} more')
PY
}

sanitize_image_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g'
}

normalize_build_dockerfile() {
  local dockerfile="$1"
  [ -f "$dockerfile" ] || return 0
  python3 - "$dockerfile" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
text = re.sub(r'(?m)^(FROM\s+\S+)\s+as\s+(\S+)\s*$', r'\1 AS \2', text)
text = re.sub(r'(?m)^CMD\s+"([^"]+)"\s*$', r'CMD ["\1"]', text)
path.write_text(text, encoding='utf-8')
PY
}

build_plugin_repo() {
  local repo="$1"
  local repo_path="$INSTALL_ROOT/$repo"
  local image cid

  if [ -f "$repo_path/Dockerfile" ]; then
    normalize_build_dockerfile "$repo_path/Dockerfile"
    image="$(sanitize_image_name "horizon-$PROFILE-$repo-build")"
    echo "Building $repo with Dockerfile non-interactively"
    rm -rf "$repo_path/out" "$repo_path/server" "$repo_path/middleware"

    if grep -q '/src/middleware/Horizon.Database' "$repo_path/Dockerfile"; then
      mkdir -p "$repo_path/out/plugin" "$repo_path/middleware"
      if [ -d "$INSTALL_ROOT/horizon-server-database-middleware" ]; then
        cp -R "$INSTALL_ROOT/horizon-server-database-middleware/." "$repo_path/middleware/"
      else
        fail "Missing horizon-server-database-middleware checkout needed to build $repo"
      fi
    else
      mkdir -p "$repo_path/out/medius" "$repo_path/out/dme" "$repo_path/server"
      if [ -d "$INSTALL_ROOT/horizon-server" ]; then
        cp -R "$INSTALL_ROOT/horizon-server" "$repo_path/server/"
      else
        fail "Missing horizon-server checkout needed to build $repo"
      fi
    fi

    (cd "$repo_path" && docker build . -t "$image")
    cid="$(docker create "$image")"
    docker cp "$cid:/out/." "$repo_path/out"
    docker rm "$cid" >/dev/null
    chmod -R a+rw "$repo_path/out" >/dev/null 2>&1 || true
    return 0
  fi

  if [ -f "$repo_path/build.sh" ]; then
    echo "Building $repo"
    (cd "$repo_path" && bash build.sh)
  else
    echo "Skipping $repo: no Dockerfile or build.sh"
  fi
}
build_named_repos() {
  local selector="$1"
  refresh_compose_mount_paths
  echo "Using profile: $PROFILE"
  python3 - "$PROFILE_FILE" "$selector" "$INCLUDE_PLUGIN" "$INCLUDE_PATCH" <<'PY' | while IFS= read -r repo; do
import json, sys
profile_path, selector, include_plugin, include_patch = sys.argv[1:5]
with open(profile_path, 'r', encoding='utf-8') as f:
    profile = json.load(f)
for repo in profile.get('repos', []):
    kind = repo.get('kind', '')
    if kind in ('plugin', 'middleware-plugin') and include_plugin != 'true':
        continue
    if kind == 'patch' and include_patch != 'true':
        continue
    if selector == kind or (selector == 'plugin' and kind == 'middleware-plugin'):
        print(repo['name'])
PY
    if [ "$selector" = "plugin" ]; then
      build_plugin_repo "$repo"
    elif [ -f "$INSTALL_ROOT/$repo/build.sh" ]; then
      echo "Building $repo"
      (cd "$INSTALL_ROOT/$repo" && bash build.sh)
    else
      echo "Skipping $repo: no build.sh"
    fi
  done
}

build_all_repos() {
  build_named_repos patch
  build_named_repos plugin
}

start_all() {
  dns_start
  compose_recreate horizon-database
  sleep 10
  compose_recreate horizon-middleware
  sync_world_catalog
  build_named_repos patch
  build_named_repos plugin
  sleep 5
  compose_recreate horizon-server
  write_active_profile_state "$PROFILE" "$PROFILE_FILE"
}

db_profile_info() {
  python3 - "$PROFILE_FILE" <<'PY'
import json, re, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    profile = json.load(f)
profile_id = profile.get('id') or 'default'
suffix = re.sub(r'[^A-Za-z0-9_-]+', '_', profile_id).strip('_')
database = profile.get('database') or {}
database_name = database.get('name') or f'Horizon_{suffix.upper()}'
print(profile_id)
print(database_name)
print(f'horizon_database_data_{suffix}')
PY
}

confirm_delete_db() {
  local profile_id database_name volume_name expected response
  profile_id="$1"
  database_name="$2"
  volume_name="$3"
  expected="delete $volume_name"

  read -r -p "Are you sure you want to delete the $profile_id database volume $volume_name (SQL database: $database_name)? [y/N] " response
  case "$response" in
    y|Y|yes|YES|Yes) ;;
    *)
      echo "Database delete cancelled."
      return 1
      ;;
  esac

  echo "If you are sure, type \"$expected\" and press enter."
  read -r response
  if [ "$response" != "$expected" ]; then
    echo "Database delete cancelled. Expected: $expected"
    return 1
  fi
}

delete_db_volume() {
  local profile_id database_name base containers container removed info
  info="$(db_profile_info)"
  profile_id="$(printf '%s\n' "$info" | sed -n '1p')"
  database_name="$(printf '%s\n' "$info" | sed -n '2p')"
  base="$(printf '%s\n' "$info" | sed -n '3p')"
  removed=0

  confirm_delete_db "$profile_id" "$database_name" "$base" || return 1

  if ! docker volume inspect "$base" >/dev/null 2>&1; then
    echo "No database volume found for active profile ($base)."
    echo "Use 'docker volume ls' to inspect existing volumes."
    return 0
  fi

  containers="$(docker ps -aq --filter "volume=$base")"
  if [ -n "$containers" ]; then
    echo "Stopping containers using $base..."
    for container in $containers; do
      docker rm -f "$container" >/dev/null
    done
  fi

  echo "Deleting database volume: $base"
  docker volume rm "$base"
  removed=1

  if [ "$removed" -eq 1 ]; then
    echo "Database volume deleted. Run ./run.sh start when you want to initialize a fresh $profile_id database."
  fi
}

reset_db() {
  delete_db_volume
}

case "$COMMAND" in
  start|up)
    start_all ;;
  server)
    compose_recreate horizon-server
    write_active_profile_state "$PROFILE" "$PROFILE_FILE" ;;
  server-restart)
    compose_recreate horizon-server
    write_active_profile_state "$PROFILE" "$PROFILE_FILE" ;;
  database)
    compose_recreate horizon-database ;;
  middleware)
    compose_recreate horizon-middleware
    sync_world_catalog ;;
  stop|down)
    stop_all ;;
  restart)
    stop_all
    start_all ;;
  status)
    echo "Active profile: $PROFILE ($PROFILE_SOURCE)"
    docker ps --filter "name=horizon-" --format "table {{.Names}}	{{.Status}}	{{.Ports}}" ;;
  logs)
    (cd "$GENERATED_ROOT" && docker compose logs -f horizon-server) ;;
  middleware-logs)
    (cd "$GENERATED_ROOT" && docker compose logs -f horizon-middleware) ;;
  db-logs)
    (cd "$GENERATED_ROOT" && docker compose logs -f horizon-database) ;;
  sync-world)
    sync_world_catalog ;;
  delete-db)
    delete_db_volume ;;
  reset-db)
    reset_db ;;
  dns)
    show_dns ;;
  dns-start)
    dns_start ;;
  dns-stop)
    if dns_enabled; then docker rm -f horizon-dns >/dev/null 2>&1 || true; else echo "horizon-dns is disabled; skipping."; fi ;;
  dns-build)
    dns_build ;;
  dns-restart)
    dns_build
    dns_restart ;;
  rebuild-patch|build-patch)
    build_named_repos patch ;;
  rebuild-plugin|build-plugin)
    build_named_repos plugin ;;
  rebuild-all)
    build_all_repos ;;
  *)
    fail "Unknown command: $COMMAND" ;;
esac
