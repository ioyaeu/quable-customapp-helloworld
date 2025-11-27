#!/bin/bash
set -euo pipefail

# This script complements the initial qa-ftp bootstrap (FTP/MariaDB/Nginx)
# by deploying the Quable CustomApp HelloWorld Node service.

usage() {
  cat <<'USAGE'
Usage: install-qa-ftp.sh --app-host-url URL --instance-name NAME --quable-api-token TOKEN --quable-app-secret SECRET [options]

Required arguments:
  --app-host-url        Public URL exposed to Quable PIM (e.g., https://qa-ftp.quable.io/automation/quableapp)
  --instance-name       Quable instance name stored in the database
  --quable-api-token    Full access API token for the instance
  --quable-app-secret   HMAC secret provided by Quable for this app

Optional arguments:
  --app-port PORT       Port for the Node service (default: 4000)
  --install-dir PATH    Target directory for the app (default: /var/www/qa-ftp/quable-customapp-helloworld)
  --service-user USER   System user to run the service (default: quableapp)
  --service-name NAME   Systemd service name (default: quable-customapp)
  --node-major VERSION  Node.js major version to install if missing/too old (default: 20)
  --database-url URL    Override Prisma DATABASE_URL (default: file:{install-dir}/database/dev.db)
  --configure-nginx     Update Nginx to proxy the app_host_url to the Node service and reload (default: enabled)
  --no-configure-nginx  Skip Nginx configuration (useful if handled externally)
  --help                Show this help
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (or with sudo)." >&2
    exit 1
  fi
}

assert_ubuntu_compatibility() {
  if [[ ! -f /etc/os-release ]]; then
    echo "/etc/os-release not found; cannot verify OS compatibility." >&2
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "Unsupported distribution: ${ID:-unknown}. This installer targets Ubuntu 22.04.5 LTS." >&2
    exit 1
  fi

  local version
  version="${VERSION_ID:-0}"

  if dpkg --compare-versions "$version" lt "22.04" || dpkg --compare-versions "$version" ge "23.00"; then
    echo "Unsupported Ubuntu version ${version}. This installer is intended for Ubuntu 22.04.5 LTS (Jammy)." >&2
    exit 1
  fi

  echo "Detected Ubuntu ${version}; proceeding with Ubuntu 22.04.5-compatible steps."
}

ensure_dependencies() {
  apt-get update -y
  apt-get install -y ca-certificates curl git rsync sqlite3
}

install_node() {
  local required_major="$1"
  local current_major=""

  if command -v node >/dev/null 2>&1; then
    current_major=$(node -v | sed 's/^v//' | cut -d. -f1)
  fi

  if [[ -z "$current_major" || "$current_major" -lt "$required_major" ]]; then
    echo "Installing Node.js ${required_major}.x via NodeSource..."
    curl -fsSL "https://deb.nodesource.com/setup_${required_major}.x" | bash -
    apt-get install -y nodejs
  else
    echo "Node.js $(node -v) already satisfies version >= ${required_major}."
  fi
}

create_service_user() {
  local user="$1"
  local home_dir="$2"

  if id "$user" >/dev/null 2>&1; then
    echo "Service user '$user' already exists."
  else
    echo "Creating service user '$user' with home $home_dir..."
    useradd --system --create-home --home-dir "$home_dir" --shell /usr/sbin/nologin "$user"
  fi
}

sync_sources() {
  local source_dir="$1"
  local target_dir="$2"

  mkdir -p "$target_dir"
  rsync -a --delete \
    --exclude '.git' \
    --exclude 'node_modules' \
    "$source_dir"/ "$target_dir"/
}

write_env_file() {
  local env_path="$1"
  local database_url="$2"
  local app_port="$3"
  local app_host_url="$4"

  cat >"$env_path" <<EOF_ENV
DATABASE_URL=${database_url}
QUABLE_APP_PORT=${app_port}
QUABLE_APP_HOST_URL=${app_host_url}
NODE_ENV=production
EOF_ENV
}

install_dependencies_and_build() {
  local workdir="$1"

  pushd "$workdir" >/dev/null
  npm install
  npx prisma migrate deploy
  npx prisma generate
  npm run build
  popd >/dev/null
}

seed_instance() {
  local workdir="$1"
  local instance_name="$2"
  local api_token="$3"
  local app_secret="$4"

  pushd "$workdir" >/dev/null
  Q_INSTANCE_NAME="$instance_name" \
  Q_API_TOKEN="$api_token" \
  Q_APP_SECRET="$app_secret" \
  node <<'EOF_NODE'
const { PrismaClient } = require('@prisma/client');

const prisma = new PrismaClient();
const name = process.env.Q_INSTANCE_NAME;
const authToken = process.env.Q_API_TOKEN;
const quableAppSecret = process.env.Q_APP_SECRET;

async function seed() {
  await prisma.$executeRaw`DELETE FROM "quable_instance" WHERE name = ${name}`;
  await prisma.quableInstance.create({
    data: { name, authToken, quableAppSecret },
  });
}

seed()
  .catch((error) => {
    console.error('Seeding failed:', error);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
EOF_NODE
  popd >/dev/null
}

create_systemd_service() {
  local service_name="$1"
  local service_user="$2"
  local workdir="$3"
  local env_file="$4"

  local node_bin
  node_bin=$(command -v node)

  cat >/etc/systemd/system/${service_name}.service <<EOF_SERVICE
[Unit]
Description=Quable CustomApp HelloWorld
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${service_user}
Group=${service_user}
WorkingDirectory=${workdir}
EnvironmentFile=${env_file}
ExecStart=${node_bin} -r module-alias/register ${workdir}/dist --env=production
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable --now ${service_name}.service
  systemctl status ${service_name}.service --no-pager
}

normalize_path() {
  local path="$1"

  # Remove trailing slash except for root
  if [[ "$path" != "/" ]]; then
    path="${path%/}"
  fi

  echo "${path:-/}"
}

check_nginx_route_conflicts() {
  local site_conf="$1"
  local requested_path
  requested_path=$(normalize_path "$2")

  local conflict_found="false"

  while read -r _ token1 token2 _; do
    # Skip empty lines (grep may return nothing on some configs)
    [[ -z "$token1" ]] && continue

    local type pattern
    case "$token1" in
      "=")
        type="exact"
        pattern=$(normalize_path "$token2")
        ;;
      "~"|"~*")
        type="regex"
        pattern="$token2"
        ;;
      "^~")
        type="prefix"
        pattern=$(normalize_path "$token2")
        ;;
      *)
        type="prefix"
        pattern=$(normalize_path "$token1")
        ;;
    esac

    case "$type" in
      "exact")
        if [[ "$requested_path" == "$pattern" ]]; then
          echo "Nginx already defines an exact location for ${requested_path} in ${site_conf}; choose another exposure path." >&2
          conflict_found="true"
        fi
        ;;
      "prefix")
        # Prefix conflict when one path is contained in the other
        if [[ "$requested_path" == "$pattern" ]]; then
          echo "Nginx already defines a prefix location '${pattern}' in ${site_conf} that overlaps with ${requested_path}; review before deploying Node behind Nginx." >&2
          conflict_found="true"
        elif [[ "$pattern" != "/" && "${requested_path#${pattern}/}" != "$requested_path" ]]; then
          echo "Nginx defines a broader prefix '${pattern}' that would catch ${requested_path} before the Node proxy; adjust the exposure path or Nginx config." >&2
          conflict_found="true"
        elif [[ "$requested_path" != "/" && "${pattern#${requested_path}/}" != "$pattern" ]]; then
          echo "Requested path ${requested_path} is broader than existing prefix '${pattern}', which may shadow some Node routes; adjust the exposure path or Nginx config." >&2
          conflict_found="true"
        fi
        ;;
      "regex")
        # Evaluate regex match safely via Python to avoid Bash regex pitfalls
        set +e
        python3 - "$pattern" "$requested_path" <<'PY'
import re
import sys

pattern, path = sys.argv[1], sys.argv[2]
try:
    regex = re.compile(pattern)
except re.error:
    sys.exit(2)

sys.exit(0 if regex.search(path) else 1)
PY
        local match_status=$?
        set -e

        if [[ $match_status -eq 0 ]]; then
          echo "Requested path ${requested_path} matches existing regex location '${token1} ${pattern}' in ${site_conf}; adjust the exposure path to avoid conflicts." >&2
          conflict_found="true"
        elif [[ $match_status -eq 2 ]]; then
          echo "Warning: Unable to evaluate regex '${pattern}' from ${site_conf}; please verify manually for possible conflicts with ${requested_path}." >&2
        fi
        ;;
    esac
  done < <(grep -E "^\s*location\s" "$site_conf" | sed 's/{.*//')

  if [[ "$conflict_found" == "true" ]]; then
    return 1
  fi

  return 0
}

configure_nginx_proxy() {
  local app_host_url="$1"
  local app_port="$2"

  if [[ ! "$app_host_url" =~ ^https?://([^/]+)(/.*)$ ]]; then
    echo "Unable to parse --app-host-url '$app_host_url'; expected https://host/path" >&2
    return 1
  fi

  local domain="${BASH_REMATCH[1]}"
  local path="${BASH_REMATCH[2]}"
  path="${path%/}"
  [[ -z "$path" ]] && path="/"

  local site_conf="/etc/nginx/sites-available/${domain}"

  if [[ ! -f "$site_conf" ]]; then
    echo "Nginx site config '$site_conf' not found; please add a reverse proxy for ${app_host_url} manually." >&2
    return 1
  fi

  if ! check_nginx_route_conflicts "$site_conf" "$path"; then
    echo "Aborting Nginx modification due to conflicting pre-existing locations." >&2
    return 1
  fi

  if grep -q "location ${path} " "$site_conf"; then
    echo "Nginx already defines location ${path}; skipping proxy injection."
    return 0
  fi

  echo "Injecting reverse proxy for ${path} -> http://127.0.0.1:${app_port} into ${site_conf}..."

  perl -0777 -i -pe "s|(server\\s*\\{[^}]*listen\\s+443[^}]*?)\\n\\}|$1\n    location ${path} {\n      proxy_pass http://127.0.0.1:${app_port};\n      proxy_http_version 1.1;\n      proxy_set_header Upgrade \\$http_upgrade;\n      proxy_set_header Connection 'upgrade';\n      proxy_set_header Host \\$host;\n      proxy_set_header X-Real-IP \\$remote_addr;\n      proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for;\n      proxy_set_header X-Forwarded-Proto \\$scheme;\n    }\n}|s" "$site_conf"

  echo "Validating Nginx configuration..."
  nginx -t
  echo "Reloading Nginx..."
  systemctl reload nginx
}

main() {
  require_root
  assert_ubuntu_compatibility

  local app_port="4000"
  local install_dir="/var/www/qa-ftp/quable-customapp-helloworld"
  local service_user="quableapp"
  local service_name="quable-customapp"
  local node_major="20"
  local app_host_url=""
  local instance_name=""
  local api_token=""
  local app_secret=""
  local database_url=""
  local configure_nginx="true"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app-host-url)
        app_host_url="$2"; shift 2 ;;
      --app-host-url=*)
        app_host_url="${1#*=}"; shift 1 ;;
      --instance-name)
        instance_name="$2"; shift 2 ;;
      --instance-name=*)
        instance_name="${1#*=}"; shift 1 ;;
      --quable-api-token)
        api_token="$2"; shift 2 ;;
      --quable-api-token=*)
        api_token="${1#*=}"; shift 1 ;;
      --quable-app-secret)
        app_secret="$2"; shift 2 ;;
      --quable-app-secret=*)
        app_secret="${1#*=}"; shift 1 ;;
      --app-port)
        app_port="$2"; shift 2 ;;
      --app-port=*)
        app_port="${1#*=}"; shift 1 ;;
      --install-dir)
        install_dir="$2"; shift 2 ;;
      --install-dir=*)
        install_dir="${1#*=}"; shift 1 ;;
      --service-user)
        service_user="$2"; shift 2 ;;
      --service-user=*)
        service_user="${1#*=}"; shift 1 ;;
      --service-name)
        service_name="$2"; shift 2 ;;
      --service-name=*)
        service_name="${1#*=}"; shift 1 ;;
      --node-major)
        node_major="$2"; shift 2 ;;
      --node-major=*)
        node_major="${1#*=}"; shift 1 ;;
      --database-url)
        database_url="$2"; shift 2 ;;
      --database-url=*)
        database_url="${1#*=}"; shift 1 ;;
      --configure-nginx)
        configure_nginx="true"; shift 1 ;;
      --no-configure-nginx|--skip-nginx)
        configure_nginx="false"; shift 1 ;;
      --help)
        usage; exit 0 ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1 ;;
    esac
  done

  if [[ -z "$app_host_url" || -z "$instance_name" || -z "$api_token" || -z "$app_secret" ]]; then
    echo "Missing required arguments." >&2
    usage
    exit 1
  fi

  if [[ "$app_host_url" =~ /automation/quableapp/?$ ]]; then
    echo "The path '/automation/quableapp' is already served by Nginx/PHP on qa-ftp; choose a distinct URL for the Node app (e.g., https://qa-ftp.quable.io/automation/quableapp-node)." >&2
    exit 1
  fi

  if [[ -z "$database_url" ]]; then
    database_url="file:${install_dir}/database/dev.db"
  fi

  ensure_dependencies
  install_node "$node_major"
  create_service_user "$service_user" "$install_dir"

  local repo_root
  repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

  sync_sources "$repo_root" "$install_dir"
  chown -R "$service_user":"$service_user" "$install_dir"

  write_env_file "$install_dir/.env" "$database_url" "$app_port" "$app_host_url"
  chown "$service_user":"$service_user" "$install_dir/.env"

  export DATABASE_URL="$database_url"
  install_dependencies_and_build "$install_dir"
  seed_instance "$install_dir" "$instance_name" "$api_token" "$app_secret"

  create_systemd_service "$service_name" "$service_user" "$install_dir" "$install_dir/.env"

  if [[ "$configure_nginx" == "true" ]]; then
    configure_nginx_proxy "$app_host_url" "$app_port" || echo "⚠️  Nginx configuration step failed; please configure the reverse proxy manually." >&2
  else
    echo "Skipping Nginx configuration as requested."
  fi

  echo "Deployment completed. Service '${service_name}' is running on port ${app_port}."
}

main "$@"
