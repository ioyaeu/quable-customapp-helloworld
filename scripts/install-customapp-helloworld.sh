#!/bin/bash
set -euo pipefail

# This script complements the initial qa-ftp bootstrap (FTP/MariaDB/Nginx)
# by deploying the Quable CustomApp HelloWorld Node service.

usage() {
  cat <<'USAGE'
Usage: install-customapp-helloworld.sh --app-host-url URL --instance-name NAME --quable-api-token TOKEN --quable-app-secret SECRET [options]

Required arguments:
  --app-host-url        Public URL exposed to Quable PIM (default: https://qa-ftp.quable.io/quableapps/helloworld)
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
  --source-dir PATH     Source directory to copy (default: /var/www/source-quable-customapp-helloworld)
  --base-path PATH      Base path exposed behind Nginx (default: /quableapps/helloworld)
  --reset-sqlite-db     Remove existing SQLite database files before running migrations (default: enabled)
  --keep-sqlite-db      Preserve an existing SQLite file (may fail if schema already exists)
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
  echo "Refreshing apt cache (accepting label changes on existing repositories)..."
  if ! apt-get update -y -o Acquire::AllowReleaseinfoChange::Label=true; then
    echo "apt-get update failed; retrying without label override..." >&2
    apt-get update -y
  fi

  apt-get install -y ca-certificates curl git rsync sqlite3 unzip
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

prepare_default_source_dir() {
  local source_dir="$1"
  local default_zip="$2"

  if [[ -f "${source_dir}/package.json" ]]; then
    return 0
  fi

  if [[ -f "$default_zip" ]]; then
    echo "Source directory '${source_dir}' is missing package.json; attempting to unzip ${default_zip}..."
    mkdir -p "$source_dir"
    unzip -oq "$default_zip" -d "$source_dir"

    local discovered
    discovered=$(find "$source_dir" -maxdepth 2 -type f -name package.json | head -n1 || true)
    if [[ -n "$discovered" ]]; then
      local extracted_root
      extracted_root=$(dirname "$discovered")
      if [[ "$extracted_root" != "$source_dir" ]]; then
        echo "Normalizing extracted content from ${extracted_root} into ${source_dir}..."
        rsync -a --delete "${extracted_root}/" "${source_dir}/"
      fi
    fi
  fi
}

validate_source_dir() {
  local source_dir="$1"

  if [[ ! -f "${source_dir}/package.json" ]]; then
    if [[ -f "${source_dir}/package-lock.json" ]]; then
      echo "Source directory '${source_dir}' only has package-lock.json; copy the full repository (including package.json) or set --source-dir to the project root." >&2
    else
      echo "Source directory '${source_dir}' does not contain package.json; use --source-dir to point to the repository root." >&2
    fi
    exit 1
  fi
}

sync_sources() {
  local source_dir="$1"
  local target_dir="$2"

  validate_source_dir "$source_dir"

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

normalize_file_url_path() {
  local url="$1"

  # Handle file:/absolute/path and sqlite:/absolute/path forms
  if [[ "$url" =~ ^file:(.*)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$url" =~ ^sqlite:(.*)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

prepare_sqlite_database() {
  local database_url="$1"
  local reset_sqlite_db="$2"

  local db_path
  db_path=$(normalize_file_url_path "$database_url")

  if [[ -z "$db_path" ]]; then
    return 0
  fi

  # Expand tilde or relative paths defensively
  if [[ "$db_path" == ~* ]]; then
    db_path="${db_path/#~/$HOME}"
  elif [[ "$db_path" != /* ]]; then
    db_path="$(pwd)/$db_path"
  fi

  mkdir -p "$(dirname "$db_path")"

  if [[ -f "$db_path" ]]; then
    if [[ "$reset_sqlite_db" == "true" ]]; then
      echo "Removing existing SQLite database at ${db_path} to avoid Prisma baseline conflicts..."
      rm -f "$db_path"
    else
      echo "Keeping existing SQLite database at ${db_path}; Prisma migrations may fail if tables already exist."
    fi
  fi
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

main() {
  require_root
  assert_ubuntu_compatibility

  local app_port="4000"
  local install_dir="/var/www/qa-ftp/quable-customapp-helloworld"
  local service_user="quableapp"
  local service_name="quable-customapp"
  local node_major="20"
  local source_dir="/var/www/source-quable-customapp-helloworld"
  local default_zip="/var/www/quable-customapp-helloworld.zip"
  local base_path="/quableapps/helloworld"
  local app_host_url=""
  local instance_name=""
  local api_token=""
  local app_secret=""
  local database_url=""
  local reset_sqlite_db="true"

  while [[ $# > 0 ]]; do
    case "$1" in
      --app-host-url)
        app_host_url="$2"; shift 2 ;;
      --app-host-url=*)
        app_host_url="${1#*=}"; shift 1 ;;
      --base-path)
        base_path="$2"; shift 2 ;;
      --base-path=*)
        base_path="${1#*=}"; shift 1 ;;
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
      --source-dir)
        source_dir="$2"; shift 2 ;;
      --source-dir=*)
        source_dir="${1#*=}"; shift 1 ;;
      --database-url)
        database_url="$2"; shift 2 ;;
      --database-url=*)
        database_url="${1#*=}"; shift 1 ;;
      --reset-sqlite-db)
        reset_sqlite_db="true"; shift 1 ;;
      --keep-sqlite-db|--no-reset-sqlite-db)
        reset_sqlite_db="false"; shift 1 ;;
      --help)
        usage; exit 0 ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1 ;;
    esac
  done

  # Normalize base path
  if [[ -z "$base_path" ]]; then
    base_path="/"
  fi
  [[ "$base_path" != /* ]] && base_path="/${base_path}"
  base_path="${base_path%/}"
  [[ -z "$base_path" ]] && base_path="/"

  if [[ -z "$app_host_url" ]]; then
    app_host_url="https://qa-ftp.quable.io${base_path}"
  fi

  if [[ -z "$instance_name" || -z "$api_token" || -z "$app_secret" ]]; then
    echo "Missing required arguments." >&2
    usage
    exit 1
  fi

  if [[ "$app_host_url" =~ /automation/quableapp/?$ ]]; then
    echo "The path '/automation/quableapp' is already served by Nginx/PHP on qa-ftp; choose a distinct URL for the Node app (e.g., https://qa-ftp.quable.io/quableapps/helloworld)." >&2
    exit 1
  fi

  if [[ -z "$database_url" ]]; then
    database_url="file:${install_dir}/database/dev.db"
  fi

  ensure_dependencies
  install_node "$node_major"
  create_service_user "$service_user" "$install_dir"

  local repo_root
  if [[ -n "$source_dir" ]]; then
    repo_root=$(cd "$source_dir" && pwd -P)
  else
    repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
  fi

  prepare_default_source_dir "$repo_root" "$default_zip"
  validate_source_dir "$repo_root"
  sync_sources "$repo_root" "$install_dir"
  chown -R "$service_user":"$service_user" "$install_dir"

  write_env_file "$install_dir/.env" "$database_url" "$app_port" "$app_host_url"
  chown "$service_user":"$service_user" "$install_dir/.env"

  export DATABASE_URL="$database_url"
  prepare_sqlite_database "$database_url" "$reset_sqlite_db"
  install_dependencies_and_build "$install_dir"
  seed_instance "$install_dir" "$instance_name" "$api_token" "$app_secret"

  create_systemd_service "$service_name" "$service_user" "$install_dir" "$install_dir/.env"

  echo "Deployment completed. Service '${service_name}' is running on port ${app_port}."
}

main "$@"
