#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/local.settings.json"
SECRETS_FILE=""
PROFILE=""
CLONE_PROTOCOL=""
INSTALL_ROOT=""
GENERATED_ROOT=""
DATA_ROOT=""
SERVER_IP=""
START_AFTER_SETUP=""
INCLUDE_PLUGIN=""
INCLUDE_PATCH=""
INCLUDE_DNS=""
SKIP_CLONE=0
SKIP_START=0
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE=""

if [ -z "${HORIZON_SETUP_LOG_ACTIVE:-}" ]; then
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
  export HORIZON_SETUP_LOG_ACTIVE=1
  export HORIZON_SETUP_LOG_FILE="$LOG_FILE"
  bash "$0" "$@" 2>&1 | tee -a "$LOG_FILE"
  exit "${PIPESTATUS[0]}"
else
  LOG_FILE="${HORIZON_SETUP_LOG_FILE:-}"
fi

usage() {
  cat <<USAGE
Usage: ./setup.sh <profile> [options]

Options:
  --ssh                 Clone using SSH URLs.
  --https               Clone using HTTPS URLs.
  --install-root PATH   Where Horizon repos should be cloned. Default comes from local.settings.json.
  --generated-root PATH Where generated compose/config files are written. Default comes from local.settings.json.
  --data-root PATH      Where persistent runtime data is stored. Default comes from local.settings.json.
  --secrets-file PATH   Where generated passwords are stored. Default comes from local.settings.json.
  --ip ADDRESS          Host LAN IP for DNS and server public IP config. Default: auto-detect.
  --skip-clone          Do not clone/pull repos, only configure existing checkout.
  --skip-start          Configure everything but do not start Docker services.
  --no-plugin           Do not clone/configure plugin repos or plugin mounts.
  --no-patch            Do not clone/configure patch repos or patch mounts.
  --no-dns              Do not clone/configure/build/start horizon-dns.
  -h, --help            Show this help.

Examples:
  ./setup.sh uya
  ./setup.sh dl --ssh
  ./setup.sh <profile> --ip 192.168.1.190
USAGE
}

log() {
  printf '\n[%s] %s\n' "horizon-setup" "$*"
}

print_log_location() {
  if [ -n "${LOG_FILE:-}" ]; then
    echo "Log file: $LOG_FILE"
  fi
}

fail() {
  echo "error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
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

copy_settings_if_needed() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    cp "$SCRIPT_DIR/local.settings.example.json" "$SETTINGS_FILE"
    log "Created local.settings.json from the example."
  fi
}

detect_ip() {
  local os ip iface
  os="$(uname -s 2>/dev/null || echo unknown)"

  case "$os" in
    Darwin)
      iface="$(route get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
      if [ -n "${iface:-}" ]; then
        ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
        if [ -n "${ip:-}" ]; then echo "$ip"; return 0; fi
      fi
      ;;
    Linux)
      ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
      if [ -n "${ip:-}" ]; then echo "$ip"; return 0; fi
      ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
      if [ -n "${ip:-}" ]; then echo "$ip"; return 0; fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if command -v powershell.exe >/dev/null 2>&1; then
        ip="$(powershell.exe -NoProfile -Command "Get-NetIPConfiguration | Where-Object { \$_.IPv4DefaultGateway -and \$_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1 -ExpandProperty IPv4Address | Select-Object -ExpandProperty IPAddress" 2>/dev/null | tr -d '\r' | head -n 1)"
        if [ -n "${ip:-}" ]; then echo "$ip"; return 0; fi
      fi
      ;;
  esac

  return 1
}

validate_ip() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

clone_or_pull_repo() {
  local name="$1"
  local url="$2"
  local branch="${3:-}"
  local target="$INSTALL_ROOT/$name"

  if [ -d "$target/.git" ]; then
    log "Updating $name"
    git -C "$target" remote set-url origin "$url"
    checkout_repo_branch "$target" "$branch"
    git -C "$target" pull --ff-only
  elif [ -d "$target" ]; then
    log "$name exists but is not a git checkout; leaving it alone."
  else
    log "Cloning $name"
    if [ -n "$branch" ]; then
      (cd "$SCRIPT_DIR" && git clone --branch "$branch" "$url" "$target")
    else
      (cd "$SCRIPT_DIR" && git clone "$url" "$target")
    fi
  fi
}

checkout_repo_branch() {
  local target="$1"
  local branch="${2:-}"

  git -C "$target" fetch origin
  git -C "$target" remote set-head origin -a >/dev/null 2>&1 || true

  if [ -z "$branch" ]; then
    branch="$(git -C "$target" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    branch="${branch#origin/}"
  fi
  if [ -z "$branch" ]; then
    if git -C "$target" show-ref --verify --quiet refs/remotes/origin/main; then
      branch="main"
    elif git -C "$target" show-ref --verify --quiet refs/remotes/origin/master; then
      branch="master"
    else
      fail "Could not determine default branch for $target. Add a branch field to the profile repo entry."
    fi
  fi

  if git -C "$target" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$target" switch "$branch"
  elif git -C "$target" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$target" switch -c "$branch" --track "origin/$branch"
  else
    fail "Branch $branch was not found on origin for $target"
  fi
}

clone_profile_repos() {
  local profile="$1"
  mkdir -p "$INSTALL_ROOT"
  python3 - "$profile" "$CLONE_PROTOCOL" "$INCLUDE_PLUGIN" "$INCLUDE_PATCH" "$INCLUDE_DNS" <<'PY' | while IFS=$'	' read -r name url branch; do
import json, sys
profile_path, protocol, include_plugin, include_patch, include_dns = sys.argv[1:6]
with open(profile_path, 'r', encoding='utf-8') as f:
    profile = json.load(f)
for repo in profile['repos']:
    kind = repo.get('kind', '')
    if kind in ('plugin', 'middleware-plugin') and include_plugin != 'true':
        continue
    if kind == 'patch' and include_patch != 'true':
        continue
    if kind == 'dns' and include_dns != 'true':
        continue
    print(f"{repo['name']}	{repo[protocol]}	{repo.get('branch', '')}")
PY
    clone_or_pull_repo "$name" "$url" "$branch"
  done
}


configure_checkout() {
  local profile="$1"
  log "Configuring Horizon files for $SERVER_IP"
  python3 - "$INSTALL_ROOT" "$GENERATED_ROOT" "$DATA_ROOT" "$LOG_DIR" "$profile" "$SERVER_IP" "$INCLUDE_PLUGIN" "$INCLUDE_PATCH" "$INCLUDE_DNS" "$SECRETS_FILE" <<'PY'
import json, os, re, secrets, shutil, sqlite3, string, sys, time
from pathlib import Path

root = Path(sys.argv[1])
generated = Path(sys.argv[2])
data_root = Path(sys.argv[3])
log_root = Path(sys.argv[4])
profile_path = Path(sys.argv[5])
server_ip = sys.argv[6]
include_plugin = sys.argv[7] == 'true'
include_patch = sys.argv[8] == 'true'
include_dns = sys.argv[9] == 'true'
secrets_path = Path(sys.argv[10])
profile = json.loads(profile_path.read_text(encoding='utf-8'))

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
app_ids = profile.get('appIds', [])
app_id_csv = ','.join(str(x) for x in app_ids)

def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'))

def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')

def password():
    alphabet = string.ascii_letters + string.digits
    return 'Horizon1!' + ''.join(secrets.choice(alphabet) for _ in range(18))

def load_env(path):
    values = {}
    lines = []
    if path.exists():
        lines = path.read_text(encoding='utf-8').splitlines()
        for line in lines:
            if not line.strip() or line.lstrip().startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            values[k.strip()] = v.strip()
    return lines, values

def set_env(lines, values, remove_keys=None):
    remove_keys = set(remove_keys or [])
    seen = set()
    out = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith('#') or '=' not in line:
            out.append(line)
            continue
        key = line.split('=', 1)[0].strip()
        if key in values:
            out.append(f'{key}={values[key]}')
            seen.add(key)
        elif key not in remove_keys:
            out.append(line)
    for key, value in values.items():
        if key not in seen:
            out.append(f'{key}={value}')
    return out

horizon_docker_src = root / 'horizon-docker'
horizon_docker = generated
horizon_dns = root / 'horizon-dns'
required_checkouts = [horizon_docker_src]
if include_dns:
    required_checkouts.append(horizon_dns)
for required in required_checkouts:
    if not required.exists():
        raise SystemExit(f'Missing required checkout: {required}')

generated.mkdir(parents=True, exist_ok=True)
data_root.mkdir(parents=True, exist_ok=True)
log_root.mkdir(parents=True, exist_ok=True)
(data_root / 'database-backup').mkdir(parents=True, exist_ok=True)
for filename in ['docker-compose.yml', 'db.config.json', 'dme.json', 'medius.json', 'muis.json', 'appsettings.json']:
    src = horizon_docker_src / filename
    if src.exists():
        shutil.copy2(src, horizon_docker / filename)

env_path = horizon_docker / '.env'
lines, existing = load_env(env_path)
lines = [line for line in lines if not line.startswith('HORIZON_DB_PASSWORD=')]
existing.pop('HORIZON_DB_PASSWORD', None)

profile_id = profile['id']
database = profile.get('database', {})
db_name = database.get('name') or f'Horizon_{profile_id.upper()}'
db_user = database.get('user') or 'sa'
if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', db_name):
    raise SystemExit(f'Invalid database.name {db_name!r}; use letters, numbers, and underscores, starting with a letter')

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

if secrets_path.exists():
    secrets_data = read_json(secrets_path)
else:
    secrets_data = {}
profile_secrets = secrets_data.setdefault('profiles', {}).setdefault(profile_id, {})
database_secrets = profile_secrets.setdefault('database', {})
database_secrets.pop('databasePassword', None)

def resolve_secret(container, key, configured='auto', existing_value=''):
    current = container.get(key)
    if current and current != 'auto':
        return current
    if configured and configured != 'auto':
        container[key] = configured
        return configured
    if existing_value:
        container[key] = existing_value
        return existing_value
    generated = password()
    container[key] = generated
    return generated

sql_admin_password = resolve_secret(
    database_secrets,
    'sqlAdminPassword',
    database.get('sqlAdminPassword', 'auto'),
    existing.get('HORIZON_MSSQL_SA_PASSWORD', ''),
)
middleware_password = resolve_secret(
    profile_secrets,
    'middlewarePassword',
    profile.get('middlewarePassword', 'auto'),
    existing.get('HORIZON_MIDDLEWARE_PASSWORD', ''),
)
write_json(secrets_path, secrets_data)

env_values = {
    'HORIZON_MSSQL_SA_PASSWORD': sql_admin_password,
    'HORIZON_DB_USER': db_user,
    'HORIZON_DB_NAME': db_name,
    'HORIZON_DB_SERVER': 'horizon-database,1433',
    'HORIZON_ASPNETCORE_ENVIRONMENT': existing.get('HORIZON_ASPNETCORE_ENVIRONMENT', 'Prod'),
    'HORIZON_MIDDLEWARE_SERVER': 'http://0.0.0.0:10000',
    'HORIZON_MIDDLEWARE_SERVER_IP': 'http://horizon-middleware:10000',
    'HORIZON_MIDDLEWARE_USER': existing.get('HORIZON_MIDDLEWARE_USER', 'admin'),
    'HORIZON_MIDDLEWARE_PASSWORD': middleware_password,
    'HORIZON_APP_ID': app_id_csv,
}
plugin_config = validate_feature_config(profile, 'plugin', ['repo', 'mediusPath', 'dmePath'], include_plugin)
patch_config = validate_feature_config(profile, 'patch', ['repo', 'miscPath', 'binPath'], include_patch)
middleware_plugin_config = validate_feature_config(profile, 'middlewarePlugin', ['repo', 'path'], include_plugin)
if plugin_config:
    plugin = root / plugin_config['repo']
    plugin_database = data_root / 'databases' / profile_id / 'database'
    plugin_database.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(plugin_database / 'database.db') as con:
        con.execute('CREATE TABLE IF NOT EXISTS users (username TEXT, password TEXT, ladderstatswide TEXT)')
    env_values['HORIZON_MEDIUS_PLUGIN_PATH'] = str(plugin / plugin_config.get('mediusPath', 'out/medius')).replace('\\', '/') + '/'
    env_values['HORIZON_DME_PLUGIN_PATH'] = str(plugin / plugin_config.get('dmePath', 'out/dme')).replace('\\', '/') + '/'
    env_values['HORIZON_ROBO_DATABASE_PATH'] = str(plugin_database).replace('\\', '/')
if patch_config:
    patch = root / patch_config['repo']
    env_values['HORIZON_PATCH_MISC_PATH'] = str(patch / patch_config.get('miscPath', 'misc')).replace('\\', '/')
    env_values['HORIZON_PATCH_BIN_PATH'] = str(patch / patch_config.get('binPath', 'bin')).replace('\\', '/')
if middleware_plugin_config:
    middleware_plugin = root / middleware_plugin_config['repo']
    env_values['HORIZON_MIDDLEWARE_PLUGIN_PATH'] = str(middleware_plugin / middleware_plugin_config.get('path', 'out/plugin')).replace('\\', '/')

optional_env_keys = {
    'HORIZON_MEDIUS_PLUGIN_PATH',
    'HORIZON_DME_PLUGIN_PATH',
    'HORIZON_ROBO_DATABASE_PATH',
    'HORIZON_PATCH_MISC_PATH',
    'HORIZON_PATCH_BIN_PATH',
    'HORIZON_MIDDLEWARE_PLUGIN_PATH',
}
env_path.write_text('\n'.join(set_env(lines, env_values, optional_env_keys - set(env_values))) + '\n', encoding='utf-8')

# Server config used by horizon-server to authenticate against middleware.
db_config_path = horizon_docker / 'db.config.json'
if db_config_path.exists():
    db_config = read_json(db_config_path)
else:
    db_config = {}
db_config.update({
    'SimulatedMode': False,
    'DatabaseUrl': 'http://horizon-middleware:10000',
    'DatabaseUsername': env_values['HORIZON_MIDDLEWARE_USER'],
    'DatabasePassword': middleware_password,
})
write_json(db_config_path, db_config)

# DNS config: point every known hostname at the host LAN IP.
if include_dns:
    dns_config_path = horizon_dns / 'config.json'
    if dns_config_path.exists():
        dns_config = read_json(dns_config_path)
        for key in list(dns_config.keys()):
            dns_config[key] = server_ip
        write_json(dns_config_path, dns_config)

# Public IP override in server configs.
for config_name in ['medius.json', 'dme.json']:
    path = horizon_docker / config_name
    if not path.exists():
        continue
    text = path.read_text(encoding='utf-8')
    text = text.replace('[YOUR_COMMA_SEPARATED_LIST_OF_APP_IDS]', json.dumps(app_ids))
    text = re.sub(r'"PublicIpOverride"\s*:\s*"([^"]+)"\s*,\s*""', r'"PublicIpOverride": "\1"', text)
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise SystemExit(f'{path} is not valid JSON: {exc}')
    if 'UsePublicIp' in data:
        data['UsePublicIp'] = True
    if 'PublicIpOverride' in data:
        data['PublicIpOverride'] = server_ip
    if 'ApplicationIds' in data and app_ids:
        data['ApplicationIds'] = app_ids
    write_json(path, data)

# Middleware app catalog for the selected profile.
appsettings_path = horizon_docker / 'appsettings.json'
if appsettings_path.exists():
    appsettings = read_json(appsettings_path)
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
    write_json(appsettings_path, appsettings)
# MUIS entrypoints advertised to the game client.
muis_path = horizon_docker / 'muis.json'
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

# Docker Compose fixes for local Docker Desktop/WSL/macOS friendliness.
prepare_middleware_build_context()
compose_path = horizon_docker / 'docker-compose.yml'
compose = compose_path.read_text(encoding='utf-8')
compose = re.sub(r'^version:\s*[^\n]+\n', '', compose, count=1, flags=re.MULTILINE)
compose = compose.replace('mcr.microsoft.com/mssql/server:2019-latest', 'mcr.microsoft.com/mssql/server:2022-latest')
compose = re.sub(
    r'(?m)^(\s*)image:\s*horizonprivateserver/horizon-server\s*$',
    '\\1image: horizon-server-local\\n\\1build:\\n\\1  context: ' + str((root / 'horizon-server').resolve()).replace('\\', '/'),
    compose,
)
middleware_context = str(middleware_build.resolve()).replace('\\', '/')
compose = re.sub(
    r'(?ms)^(\s*horizon-middleware:\n)(?:(?:\s*image:[^\n]*\n)|(?:\s*build:\s*\n\s*context:[^\n]*\n))+',
    lambda m: f'{m.group(1)}    image: horizon-middleware-local\n    build:\n      context: {middleware_context}\n',
    compose,
)
compose = compose.replace('ACCEPT_EULA=True', 'ACCEPT_EULA=Y')
compose = re.sub(r'^\s*network_mode:\s*bridge\s*\n', '', compose, flags=re.MULTILINE)
compose = re.sub(r'^\s*user:\s*root\s*\n', '', compose, flags=re.MULTILINE)
volume_name = 'horizon_database_data_' + re.sub(r'[^A-Za-z0-9_-]+', '_', profile['id']).strip('_')
compose = compose.replace('./logs:/logs', str(log_root.resolve()).replace('\\', '/') + ':/logs')
compose = compose.replace('./database_backup:/backup', str((data_root / 'database-backup').resolve()).replace('\\', '/') + ':/backup')
compose = compose.replace('./database_data:/var/opt/mssql', f'{volume_name}:/var/opt/mssql')
compose = compose.replace('"./database_data:/var/opt/mssql"', f'{volume_name}:/var/opt/mssql')
compose = re.sub(r'horizon_database_data(?:_[A-Za-z0-9_-]+)?(?=:/var/opt/mssql)', volume_name, compose)
compose = re.sub(r'(?ms)^volumes:\s*\n.*\Z', '', compose).rstrip()
compose = compose + f'\nvolumes:\n  {volume_name}:\n    name: {volume_name}\n'
compose_path.write_text(compose, encoding='utf-8')

# Compose override for optional plugin/patch mounts.
server_volume_lines = []
middleware_volume_lines = []
if plugin_config:
    server_volume_lines.extend([
        '      - ${HORIZON_MEDIUS_PLUGIN_PATH}:/medius/plugins/',
        '      - ${HORIZON_DME_PLUGIN_PATH}:/dme/plugins/',
        '      - ${HORIZON_ROBO_DATABASE_PATH}:/database',
    ])
if patch_config:
    server_volume_lines.extend([
        '      - ${HORIZON_PATCH_MISC_PATH}:/medius/plugins/bin/',
        '      - ${HORIZON_PATCH_BIN_PATH}:/medius/plugins/bin/patch/',
    ])
if middleware_plugin_config:
    middleware_volume_lines.append('      - ${HORIZON_MIDDLEWARE_PLUGIN_PATH}:/plugins/')
    appsettings_path = horizon_docker / 'appsettings.json'
    if appsettings_path.exists():
        appsettings = read_json(appsettings_path)
        appsettings['Plugins'] = '/plugins/'
        write_json(appsettings_path, appsettings)
override_path = horizon_docker / 'docker-compose.override.yml'
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

# Patch known brittle horizon-dns Dockerfile apt retry chain when present.
dockerfile = horizon_dns / 'Dockerfile'
if include_dns and dockerfile.exists():
    text = dockerfile.read_text(encoding='utf-8')
    if text.count('\\n') > 10 and text.count('\n') <= 1:
        text = text.replace('\\n', '\n')
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    text = re.sub(r'RUN apt-get update && apt-get install bind9 bind9utils bind9-doc dnsutils -y',
                  'RUN apt-get update && apt-get install -y \\\n  bind9 bind9utils bind9-doc dnsutils python3 \\\n  && apt-get clean && rm -rf /var/lib/apt/lists/*', text)
    text = re.sub(r'\nRUN apt install -y vim software-properties-common\nRUN apt-get update\s*\nRUN apt install -y python3\n', '\n', text)
    text = re.sub(r'\nRUN apt install -y -f software-properties-common.*?\nRUN apt install -y python3\n', '\n', text, flags=re.DOTALL)
    dockerfile.write_text(text, encoding='utf-8')

print(f'Configured {profile["id"]} for host IP {server_ip}')
print(f'App IDs: {app_id_csv}')
print(f'Database: {db_name} ({db_user})')
print(f'Secrets: {secrets_path}')
PY
}

build_dns() {
  if [ "$INCLUDE_DNS" != "true" ]; then
    log "Skipping horizon-dns build"
  elif [ -d "$INSTALL_ROOT/horizon-dns" ]; then
    log "Building horizon-dns Docker image"
    (cd "$INSTALL_ROOT/horizon-dns" && docker build . -t horizon-dns)
  fi
}

start_services() {
  local args=("--profile" "$PROFILE" "start")
  [ "$INCLUDE_PLUGIN" = "true" ] || args+=("--no-plugin")
  [ "$INCLUDE_PATCH" = "true" ] || args+=("--no-patch")
  [ "$INCLUDE_DNS" = "true" ] || args+=("--no-dns")

  log "Starting Horizon services for $PROFILE"
  (cd "$SCRIPT_DIR" && bash run.sh "${args[@]}")
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage; exit 0 ;;
    --ssh)
      CLONE_PROTOCOL="ssh" ;;
    --https)
      CLONE_PROTOCOL="https" ;;
    --install-root)
      shift; [ $# -gt 0 ] || fail "--install-root requires a path"; INSTALL_ROOT="$1" ;;
    --generated-root)
      shift; [ $# -gt 0 ] || fail "--generated-root requires a path"; GENERATED_ROOT="$1" ;;
    --data-root)
      shift; [ $# -gt 0 ] || fail "--data-root requires a path"; DATA_ROOT="$1" ;;
    --secrets-file)
      shift; [ $# -gt 0 ] || fail "--secrets-file requires a path"; SECRETS_FILE="$1" ;;
    --ip)
      shift; [ $# -gt 0 ] || fail "--ip requires an address"; SERVER_IP="$1" ;;
    --skip-clone)
      SKIP_CLONE=1 ;;
    --skip-start)
      SKIP_START=1 ;;
    --no-plugin)
      INCLUDE_PLUGIN="false" ;;
    --no-patch)
      INCLUDE_PATCH="false" ;;
    --no-dns)
      INCLUDE_DNS="false" ;;
    *)
      if [ -z "$PROFILE" ] && [ -f "$SCRIPT_DIR/profiles/$1.json" ]; then
        PROFILE="$1"
      else
        fail "Unknown argument: $1"
      fi ;;
  esac
  shift
done

print_log_location
need_cmd python3
need_cmd git
need_cmd docker
copy_settings_if_needed

if [ -z "$PROFILE" ]; then
  PROFILE="$(json_get "$SETTINGS_FILE" defaultProfile)"
fi
[ -n "$PROFILE" ] || fail "Profile is required. Use one of the JSON files in profiles/."
PROFILE_FILE="$SCRIPT_DIR/profiles/$PROFILE.json"
[ -f "$PROFILE_FILE" ] || fail "Unknown profile: $PROFILE"
python3 - "$SETTINGS_FILE" "$PROFILE" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
profile = sys.argv[2]
data = json.loads(path.read_text(encoding='utf-8'))
data['defaultProfile'] = profile
path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
PY

if [ -z "$CLONE_PROTOCOL" ]; then
  CLONE_PROTOCOL="$(json_get "$SETTINGS_FILE" cloneProtocol)"
fi
[ "$CLONE_PROTOCOL" = "https" ] || [ "$CLONE_PROTOCOL" = "ssh" ] || fail "cloneProtocol must be https or ssh"

if [ -z "$INSTALL_ROOT" ]; then
  INSTALL_ROOT="$(json_get "$SETTINGS_FILE" installRoot)"
fi
[ -n "$INSTALL_ROOT" ] || INSTALL_ROOT="./repos"
if [ -z "$GENERATED_ROOT" ]; then
  GENERATED_ROOT="$(json_get "$SETTINGS_FILE" generatedRoot)"
fi
[ -n "$GENERATED_ROOT" ] || GENERATED_ROOT="./data/generated"
if [ -z "$DATA_ROOT" ]; then
  DATA_ROOT="$(json_get "$SETTINGS_FILE" dataRoot)"
fi
[ -n "$DATA_ROOT" ] || DATA_ROOT="./data"
INSTALL_ROOT="$(abs_path "$INSTALL_ROOT")"
GENERATED_ROOT="$(abs_path "$GENERATED_ROOT")"
DATA_ROOT="$(abs_path "$DATA_ROOT")"

if [ -z "$SECRETS_FILE" ]; then
  SECRETS_FILE="$(json_get "$SETTINGS_FILE" secretsFile)"
fi
[ -n "$SECRETS_FILE" ] || SECRETS_FILE="./local.secrets.json"
SECRETS_FILE="$(abs_path "$SECRETS_FILE")"

if [ -z "$SERVER_IP" ]; then
  configured_ip="$(json_get "$SETTINGS_FILE" serverIp)"
  if [ "$configured_ip" != "auto" ] && [ -n "$configured_ip" ]; then
    SERVER_IP="$configured_ip"
  else
    SERVER_IP="$(detect_ip || true)"
  fi
fi
[ -n "$SERVER_IP" ] || fail "Could not auto-detect LAN IP. Re-run with --ip 192.168.x.x"
validate_ip "$SERVER_IP" || fail "Invalid IPv4 address: $SERVER_IP"

if [ -z "$START_AFTER_SETUP" ]; then
  START_AFTER_SETUP="$(json_get "$SETTINGS_FILE" startAfterSetup)"
fi
[ -n "$START_AFTER_SETUP" ] || START_AFTER_SETUP="true"

if [ -z "$INCLUDE_PLUGIN" ]; then
  INCLUDE_PLUGIN="$(json_get "$SETTINGS_FILE" includePlugin)"
fi
[ -n "$INCLUDE_PLUGIN" ] || INCLUDE_PLUGIN="true"

if [ -z "$INCLUDE_PATCH" ]; then
  INCLUDE_PATCH="$(json_get "$SETTINGS_FILE" includePatch)"
fi
[ -n "$INCLUDE_PATCH" ] || INCLUDE_PATCH="true"

if [ -z "$INCLUDE_DNS" ]; then
  INCLUDE_DNS="$(json_get "$SETTINGS_FILE" includeDns)"
fi
[ -n "$INCLUDE_DNS" ] || INCLUDE_DNS="true"

case "$INCLUDE_PLUGIN" in true|false) ;; *) fail "includePlugin must be true or false" ;; esac
case "$INCLUDE_PATCH" in true|false) ;; *) fail "includePatch must be true or false" ;; esac
case "$INCLUDE_DNS" in true|false) ;; *) fail "includeDns must be true or false" ;; esac

log "Profile: $PROFILE"
log "Repos root: $INSTALL_ROOT"
log "Generated root: $GENERATED_ROOT"
log "Data root: $DATA_ROOT"
log "Secrets file: $SECRETS_FILE"
log "Clone protocol: $CLONE_PROTOCOL"
log "Host IP: $SERVER_IP"
log "Include plugin: $INCLUDE_PLUGIN"
log "Include patch: $INCLUDE_PATCH"
log "Include DNS: $INCLUDE_DNS"

if [ "$SKIP_CLONE" -eq 0 ]; then
  clone_profile_repos "$PROFILE_FILE"
else
  log "Skipping clone/pull step"
fi

configure_checkout "$PROFILE_FILE"
build_dns

if [ "$SKIP_START" -eq 0 ] && [ "$START_AFTER_SETUP" = "true" ]; then
  start_services
else
  log "Skipping Docker startup"
fi

cat <<DONE

Setup complete.
Useful commands:
  ./run.sh status
  ./run.sh logs
  ./run.sh dns-restart
  ./run.sh rebuild-patch
DONE

if [ "$INCLUDE_DNS" = "true" ]; then
  echo ""
  echo "DNAS IP: $SERVER_IP"
else
  echo ""
  echo "horizon-dns disabled; configure DNS/routing outside this setup."
fi
