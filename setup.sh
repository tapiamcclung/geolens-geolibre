#!/usr/bin/env bash

set -Eeuo pipefail

umask 077
SECRETS_FILE="$HOME/secrets.env"
if [[ ! -r "$SECRETS_FILE" ]]; then
    echo "ERROR: Cannot read $SECRETS_FILE" >&2
    exit 1
fi

# The file is sourced as shell code, so it must be private to its owner.
SECRETS_MODE="$(stat -c '%a' "$SECRETS_FILE")"
if (( (8#$SECRETS_MODE & 077) != 0 )); then
    echo "ERROR: $SECRETS_FILE permissions are too broad ($SECRETS_MODE). Run: chmod 600 '$SECRETS_FILE'" >&2
    exit 1
fi
source "$SECRETS_FILE"

for required_var in \
    SMTP_USERNAME SMTP_PASSWORD \
    GEOLENS_POSTGRES_USER GEOLENS_POSTGRES_PASSWORD \
    GEOLENS_JWT_SECRET_KEY GEOLENS_SECRET_ENCRYPTION_KEY \
    GEOLENS_ADMIN_PASSWORD GEOLENS_MINIO_ROOT_USER GEOLENS_MINIO_ROOT_PASSWORD \
    GEOLIBRE_POSTGRES_PASSWORD; do
    [[ -n "${!required_var:-}" ]] || { echo "ERROR: Required variable $required_var is missing in $SECRETS_FILE" >&2; exit 1; }
done

# Resolve image versions before making any server changes. Floating tags require explicit opt-in.
GEOLENS_VERSION="${GEOLENS_VERSION:-latest}"
GEOLIBRE_WEB_IMAGE="${GEOLIBRE_WEB_IMAGE:-ghcr.io/opengeos/geolibre:latest}"
if [[ "$GEOLENS_VERSION" == "latest" && "${ALLOW_FLOATING_GEOLENS_IMAGE:-0}" != "1" ]]; then
    echo "ERROR: Set GEOLENS_VERSION to a tested GeoLens release, or explicitly set ALLOW_FLOATING_GEOLENS_IMAGE=1 to accept floating-tag risk." >&2
    exit 1
fi
if [[ "$GEOLIBRE_WEB_IMAGE" == *":latest" && "${ALLOW_FLOATING_GEOLIBRE_IMAGE:-0}" != "1" ]]; then
    echo "ERROR: Set GEOLIBRE_WEB_IMAGE to a tested version tag or digest, or explicitly set ALLOW_FLOATING_GEOLIBRE_IMAGE=1 to accept floating-tag risk." >&2
    exit 1
fi

###############################################################################
# GeoLens installation / deployment script
#
# Usage:
#
#   GEOLENS_URL=dfu.etu.geoint.mx ./setup.sh
#
# Optional configuration:
#
#   GEOLENS_IP=10.2.102.165 \
#   DB_WAIT_TIMEOUT=600 \
#   DB_WAIT_INTERVAL=5 \
#   ./setup.sh
#
###############################################################################

###############################################################################
# Configuration
###############################################################################

#GEOLENS_IP="${GEOLENS_IP:-10.2.102.165}"
GEOLENS_DIR="${GEOLENS_DIR:-$HOME/geolens}"

# GeoLens upload limit. GeoLens currently accepts values up to 10000 MB.
UPLOAD_MAX_SIZE_MB="${UPLOAD_MAX_SIZE_MB:-10000}"

# How long to wait for PostgreSQL to become healthy.
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-300}"

# Seconds between DB health checks.
DB_WAIT_INTERVAL="${DB_WAIT_INTERVAL:-5}"

###############################################################################
# Colors & Helpers
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { error "$*"; exit 1; }

# Report expected Compose services with no running container, or with unhealthy state.
# Usage: check_compose_services ARRAY_NAME (e.g. check_compose_services GEOLENS_COMPOSE_CMD)
check_compose_services() {
    local array_name="$1" line service state health expected actual found bad=""
    local -n compose_ref="$array_name"
    expected="$("${compose_ref[@]}" config --services)"
    actual="$("${compose_ref[@]}" ps -a --format '{{.Service}}|{{.State}}|{{.Health}}' 2>/dev/null || true)"
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        found=false
        while IFS='|' read -r line state health; do
            [[ "$line" == "$service" ]] || continue
            found=true
            if [[ "$state" != "running" || "$health" == "unhealthy" ]]; then
                bad+="${service}: state=${state:-unknown} health=${health:-none}\n"
            fi
        done <<< "$actual"
        if [[ "$found" == false ]]; then
            bad+="${service}: no container found\n"
        fi
    done <<< "$expected"
    printf '%b' "$bad"
}

trap 'error "Script failed on line $LINENO. Review the preceding output; command text is intentionally omitted because it may contain secrets."' ERR

info "Setting server time zone"
sudo timedatectl set-timezone America/Mexico_City

###############################################################################
# Dynamic IP Detection & Configuration
###############################################################################

# Check required public hostname and set auth/CORS defaults.
: "${GEOLENS_URL:?Error: GEOLENS_URL environment variable is required.}"
# This script uses one base hostname and derives the gis/share/colab subdomains.
if [[ ! "$GEOLENS_URL" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    die "GEOLENS_URL must be a hostname only (no scheme, port, path, whitespace, or trailing dot)."
fi
export GEOLIBRE_CLERK_ISSUER="${GEOLIBRE_CLERK_ISSUER:-https://suitable-lamprey-8117.clerk.accounts.dev}"
export GEOLIBRE_CLERK_ALLOWED_ORIGINS="${GEOLIBRE_CLERK_ALLOWED_ORIGINS:-https://gis.${GEOLENS_URL}}"
export GEOLIBRE_CLERK_SCOPES="${GEOLIBRE_CLERK_SCOPES:-read:projects write:projects share:public}"
export GEOLIBRE_CORS_ORIGINS="${GEOLIBRE_CORS_ORIGINS:-https://${GEOLENS_URL},https://gis.${GEOLENS_URL},https://share.${GEOLENS_URL}}"

GEOLENS_DIR="${GEOLENS_DIR:-$HOME/geolens}"
ENV_FILE="${GEOLENS_DIR}/.env"

# 1. Read GEOLENS_IP from existing .env file if present
SAVED_IP=""
if [[ -f "$ENV_FILE" ]]; then
    SAVED_IP="$(grep -E '^GEOLENS_IP=' "$ENV_FILE" | cut -d= -f2- || true)"
fi

# 2. Query OpenStack Metadata Service for Floating IP
OPENSTACK_IP="$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 || true)"

# 3. Fallback to local default network IP
LOCAL_IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I 2>/dev/null | awk '{print $1}')"

# Selection hierarchy: CLI override > OpenStack Floating IP > Saved .env > Local IP
if [[ -n "${GEOLENS_IP:-}" ]]; then
    FINAL_IP="$GEOLENS_IP"
elif [[ -n "$OPENSTACK_IP" && "$OPENSTACK_IP" != *"404"* ]]; then
    FINAL_IP="$OPENSTACK_IP"
elif [[ -n "$SAVED_IP" ]]; then
    FINAL_IP="$SAVED_IP"
else
    FINAL_IP="$LOCAL_IP"
fi

GEOLENS_IP="$FINAL_IP"
info "Detected Server IP: ${GEOLENS_IP}"

###############################################################################
# Docker Bootstrap & Permissions
###############################################################################

info "Checking Docker installation..."

if ! command -v docker >/dev/null 2>&1; then
    info "Installing Docker..."
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
    fi
    ARCH="$(dpkg --print-architecture)"
    UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
fi

# !override and !reset in the GeoLibre override require Docker Compose v2.24.4+.
COMPOSE_VERSION="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
[[ -n "$COMPOSE_VERSION" ]] || die "Docker Compose v2 plugin is unavailable."
if [[ "$(printf '%s\n%s\n' "2.24.4" "$COMPOSE_VERSION" | sort -V | head -n1)" != "2.24.4" ]]; then
    die "Docker Compose ${COMPOSE_VERSION} is too old; version 2.24.4 or newer is required for !override/!reset."
fi

if ! getent group docker >/dev/null 2>&1; then
    sudo groupadd docker
fi

if ! docker info >/dev/null 2>&1; then
    if [[ "${GEOLENS_DOCKER_GROUP_REFRESHED:-0}" == "1" ]]; then
        die "Docker is still inaccessible after refreshing group membership. Log out and back in, then rerun this script."
    fi
    warn "Adding ${USER} to docker group..."
    sudo usermod -aG docker "$USER"
    export GEOLENS_DOCKER_GROUP_REFRESHED=1
    exec newgrp docker <<EOF
exec "$0" "$@"
EOF
fi

###############################################################################
# Configure Docker Bridge MTU
###############################################################################

info "Checking Docker bridge MTU configuration..."
sudo mkdir -p /etc/docker
if sudo python3 - <<'PYMTU'
import json
from pathlib import Path
import os, tempfile
p = Path("/etc/docker/daemon.json")
try:
    config = json.loads(p.read_text()) if p.exists() else {}
except json.JSONDecodeError as exc:
    raise SystemExit(f"ERROR: {p} contains invalid JSON: {exc}")
if not isinstance(config, dict):
    raise SystemExit(f"ERROR: {p} must contain a JSON object")
if config.get("mtu") == 1442:
    raise SystemExit(10)
config["mtu"] = 1442
fd, tmp = tempfile.mkstemp(prefix="daemon.json.", dir=str(p.parent))
try:
    with os.fdopen(fd, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PYMTU
then
    sudo systemctl restart docker
else
    status=$?
    if [[ "$status" -eq 10 ]]; then
        info "Docker bridge MTU already configured to 1442. Skipping restart."
    else
        die "Could not safely update Docker daemon configuration."
    fi
fi


###############################################################################
# Download GeoLens Installer & Extract Stack
###############################################################################

# 1. First-time install check
if [[ ! -f "${GEOLENS_DIR}/docker-compose.prod.yml" && ! -f "${GEOLENS_DIR}/docker-compose.yml" && ! -f "${GEOLENS_DIR}/compose.yml" ]]; then
    [[ "${ALLOW_REMOTE_GEOLENS_INSTALLER:-0}" == "1" ]] || die "GeoLens Compose files were not found in ${GEOLENS_DIR}. Review the official installer first; to explicitly allow it, rerun with ALLOW_REMOTE_GEOLENS_INSTALLER=1."
    info "Downloading the GeoLens installer to a temporary file for explicit opt-in execution..."
    INSTALLER_TMP="$(mktemp)"
    trap 'rm -f "${INSTALLER_TMP:-}"; error "Script failed on line $LINENO. Review the preceding output; command text is intentionally omitted because it may contain secrets."' ERR
    curl -fsSL https://getgeolens.com/install.sh -o "$INSTALLER_TMP"
    bash -n "$INSTALLER_TMP" || die "Downloaded GeoLens installer failed Bash syntax validation."
    PARENT_DIR="$(dirname "$GEOLENS_DIR")"
    (cd "$PARENT_DIR" && bash "$INSTALLER_TMP")
    rm -f "$INSTALLER_TMP"
    trap 'error "Script failed on line $LINENO. Review the preceding output; command text is intentionally omitted because it may contain secrets."' ERR
fi

# 2. Safely enter target directory (only die if directory STILL doesn't exist after installer)
if [[ ! -d "$GEOLENS_DIR" ]]; then
    die "GeoLens directory ${GEOLENS_DIR} does not exist after installation attempt."
fi

cd "$GEOLENS_DIR" || die "Failed to enter directory ${GEOLENS_DIR}"

###############################################################################
# Environment Configuration & Safe Docker Compose Override
###############################################################################

ENV_FILE="${GEOLENS_DIR}/.env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

set_env_value() {
    local key="$1"
    local value="$2"
    ENV_VALUE="$value" python3 - "$ENV_FILE" "$key" <<'PYENV'
from pathlib import Path
import os, sys
p, key = Path(sys.argv[1]), sys.argv[2]
value = os.environ["ENV_VALUE"]
import re
if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
    raise SystemExit("Invalid environment variable name")
if "\n" in value or "\r" in value or "\x00" in value:
    raise SystemExit(f"Refusing newline/NUL in environment value for {key}")
# Docker Compose supports single-quoted .env values literally; escape embedded single quotes.
value = "'" + value.replace("'", "\\'") + "'"
lines = p.read_text().splitlines() if p.exists() else []
prefix = key + "="
new_lines = []
found = False
for line in lines:
    if line.startswith(prefix):
        if not found:
            new_lines.append(prefix + value)
            found = True
    else:
        new_lines.append(line)
if not found:
    new_lines.append(prefix + value)
import os, tempfile
p.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=p.name + ".", dir=str(p.parent))
try:
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(new_lines) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PYENV
}

# Tell Docker Compose to load both the main file and our override file
set_env_value "UPLOAD_MAX_SIZE_MB" "$UPLOAD_MAX_SIZE_MB"
set_env_value "PUBLIC_APP_URL" "https://${GEOLENS_URL}"
set_env_value "PUBLIC_API_URL" "https://${GEOLENS_URL}/api"

set_env_value "NOTIFICATIONS_ENABLED" "true"
set_env_value "REGISTRATION_ENABLED" "true"
set_env_value "NOTIFY_ON_SIGNUP" "true"
set_env_value "CORS_ALLOWED_ORIGINS" "https://gis.${GEOLENS_URL}"

# Keep generated settings outside the upstream checkout and never overwrite a
# user-maintained docker-compose.override.yml. This managed file is regenerated.
GEOLENS_CUSTOMIZATION_DIR="${GEOLENS_CUSTOMIZATION_DIR:-$HOME/geolens-customizations}"
mkdir -p "$GEOLENS_CUSTOMIZATION_DIR"
chmod 700 "$GEOLENS_CUSTOMIZATION_DIR"
GEOLENS_MANAGED_OVERRIDE="${GEOLENS_CUSTOMIZATION_DIR}/managed-compose.override.yml"
GEOLENS_OVERRIDE_TMP="$(mktemp "${GEOLENS_CUSTOMIZATION_DIR}/managed-compose.override.yml.XXXXXX")"
cat > "$GEOLENS_OVERRIDE_TMP" <<EOF
services:
  worker:
    environment:
      UPLOAD_MAX_SIZE_MB: "${UPLOAD_MAX_SIZE_MB}"
EOF
chmod 600 "$GEOLENS_OVERRIDE_TMP"
if [[ ! -f "$GEOLENS_MANAGED_OVERRIDE" ]] || ! cmp -s "$GEOLENS_OVERRIDE_TMP" "$GEOLENS_MANAGED_OVERRIDE"; then
    mv -f "$GEOLENS_OVERRIDE_TMP" "$GEOLENS_MANAGED_OVERRIDE"
else
    rm -f "$GEOLENS_OVERRIDE_TMP"
fi

# Pick the real main file once and use the same explicit -f arguments for every command.
if [[ -f "${GEOLENS_DIR}/docker-compose.prod.yml" ]]; then
    GEOLENS_MAIN_COMPOSE="${GEOLENS_DIR}/docker-compose.prod.yml"
elif [[ -f "${GEOLENS_DIR}/docker-compose.yml" ]]; then
    GEOLENS_MAIN_COMPOSE="${GEOLENS_DIR}/docker-compose.yml"
elif [[ -f "${GEOLENS_DIR}/compose.yml" ]]; then
    GEOLENS_MAIN_COMPOSE="${GEOLENS_DIR}/compose.yml"
else
    die "No supported GeoLens Compose file found in ${GEOLENS_DIR}."
fi
GEOLENS_COMPOSE_CMD=(docker compose --project-directory "$GEOLENS_DIR" -f "$GEOLENS_MAIN_COMPOSE")
# Preserve and include any existing user/upstream override, then apply our separate managed settings.
if [[ -f "${GEOLENS_DIR}/docker-compose.override.yml" ]]; then
    GEOLENS_COMPOSE_CMD+=( -f "${GEOLENS_DIR}/docker-compose.override.yml" )
fi
GEOLENS_COMPOSE_CMD+=( -f "$GEOLENS_MANAGED_OVERRIDE" )

set_env_value "SMTP_HOST" "c2770541.ferozo.com"
set_env_value "SMTP_PORT" "465"
set_env_value "SMTP_USERNAME" "$SMTP_USERNAME"
set_env_value "SMTP_PASSWORD" "$SMTP_PASSWORD"
set_env_value "SMTP_FROM_ADDRESS" "GeoLens ETU <etu@geoint.mx>"
set_env_value "SMTP_USE_TLS" "false"
set_env_value "SMTP_USE_SSL" "true"

# Populate GeoLens credentials from the protected secrets file.
set_env_value "POSTGRES_USER" "$GEOLENS_POSTGRES_USER"
set_env_value "POSTGRES_PASSWORD" "$GEOLENS_POSTGRES_PASSWORD"
set_env_value "JWT_SECRET_KEY" "$GEOLENS_JWT_SECRET_KEY"
set_env_value "SECRET_ENCRYPTION_KEY" "$GEOLENS_SECRET_ENCRYPTION_KEY"
set_env_value "GEOLENS_ADMIN_PASSWORD" "$GEOLENS_ADMIN_PASSWORD"
set_env_value "MINIO_ROOT_USER" "$GEOLENS_MINIO_ROOT_USER"
set_env_value "MINIO_ROOT_PASSWORD" "$GEOLENS_MINIO_ROOT_PASSWORD"
set_env_value "GEOLENS_VERSION" "$GEOLENS_VERSION"
chmod 600 "$ENV_FILE"
"${GEOLENS_COMPOSE_CMD[@]}" config -q || die "GeoLens Compose configuration is invalid; no GeoLens deployment was attempted."
GEOLENS_CUSTOMIZATION_DIR="${GEOLENS_CUSTOMIZATION_DIR:-$HOME/geolens-customizations}"
mkdir -p "$GEOLENS_CUSTOMIZATION_DIR"
chmod 700 "$GEOLENS_CUSTOMIZATION_DIR"
GEOLENS_CONFIG_HASH="$("${GEOLENS_COMPOSE_CMD[@]}" config | sha256sum | awk '{print $1}')"
GEOLENS_CONFIG_HASH_FILE="${GEOLENS_CUSTOMIZATION_DIR}/.last-compose-config.sha256"
GEOLENS_PREVIOUS_CONFIG_HASH="$(cat "$GEOLENS_CONFIG_HASH_FILE" 2>/dev/null || true)"

# Resolve every image from Compose rather than assuming the stack has one API image.

info "Checking for GeoLens updates..."

# Capture all image IDs used by the resolved Compose configuration before pulling.
GEOLENS_IMAGES="$("${GEOLENS_COMPOSE_CMD[@]}" config --images | awk 'NF && !seen[$0]++')"
[[ -n "$GEOLENS_IMAGES" ]] || die "GeoLens Compose resolved no images; check GEOLENS_VERSION and the Compose files."
declare -A GEOLENS_IMAGE_IDS_BEFORE=()
while IFS= read -r image_name; do
    [[ -n "$image_name" ]] || continue
    image_id="$(docker image inspect --format '{{.Id}}' "$image_name" 2>/dev/null || true)"
    GEOLENS_IMAGE_IDS_BEFORE["$image_name"]="$image_id"
done <<< "$GEOLENS_IMAGES"

info "Pulling all prebuilt GeoLens images defined by Compose..."
"${GEOLENS_COMPOSE_CMD[@]}" pull
NEEDS_RESTART=false
if [[ "$GEOLENS_CONFIG_HASH" != "$GEOLENS_PREVIOUS_CONFIG_HASH" ]]; then
    info "Rendered GeoLens Compose configuration changed; container recreation is required."
    NEEDS_RESTART=true
fi
while IFS= read -r image_name; do
    [[ -n "$image_name" ]] || continue
    image_id_after="$(docker image inspect --format '{{.Id}}' "$image_name" 2>/dev/null || true)"
    image_id_before="${GEOLENS_IMAGE_IDS_BEFORE[$image_name]:-}"
    if [[ -z "$image_id_before" || "$image_id_before" != "$image_id_after" ]]; then
        info "GeoLens image changed or was missing locally: ${image_name} (${image_id_after:7:12})."
        NEEDS_RESTART=true
    fi
done <<< "$GEOLENS_IMAGES"

###############################################################################
# Ensure Database is Running & Wait for Health
###############################################################################

info "Ensuring PostgreSQL database container is running..."
"${GEOLENS_COMPOSE_CMD[@]}" up -d db

DB_CONTAINER="$("${GEOLENS_COMPOSE_CMD[@]}" ps -q db)"
info "Waiting for PostgreSQL ($DB_CONTAINER) to become healthy..."

START_TIME="$(date +%s)"
while true; do
    STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$DB_CONTAINER" 2>/dev/null || echo "missing")"
    
    if [[ "$STATUS" == "healthy" ]]; then
        success "PostgreSQL is healthy."
        break
    elif [[ "$STATUS" == "no-healthcheck" ]]; then
        if docker exec "$DB_CONTAINER" pg_isready >/dev/null 2>&1; then
            success "PostgreSQL is ready."
            break
        fi
    fi

    ELAPSED=$(($(date +%s) - START_TIME))
    if (( ELAPSED >= DB_WAIT_TIMEOUT )); then
        "${GEOLENS_COMPOSE_CMD[@]}" logs --tail=100 db
        die "Database failed to become healthy within ${DB_WAIT_TIMEOUT}s."
    fi
    sleep "$DB_WAIT_INTERVAL"
done

sleep 2

###############################################################################
# Start Full Production Stack
###############################################################################

if [[ "${NEEDS_RESTART:-true}" == "true" ]]; then
    info "Applying new image updates and recreating remaining GeoLens services..."
    "${GEOLENS_COMPOSE_CMD[@]}" up -d --remove-orphans
else
    info "GeoLens images are up to date. Ensuring all remaining services are running..."
    "${GEOLENS_COMPOSE_CMD[@]}" up -d
fi

GEOLENS_FAILED_SERVICES="$(check_compose_services GEOLENS_COMPOSE_CMD)"
if [[ -n "$GEOLENS_FAILED_SERVICES" ]]; then
    error "GeoLens service check found missing, stopped, or unhealthy services:"
    echo "$GEOLENS_FAILED_SERVICES" >&2
    "${GEOLENS_COMPOSE_CMD[@]}" logs --tail=80 >&2 || true
    die "GeoLens deployment did not pass the Compose service check."
fi
printf '%s\n' "$GEOLENS_CONFIG_HASH" > "${GEOLENS_CONFIG_HASH_FILE}.tmp"
chmod 600 "${GEOLENS_CONFIG_HASH_FILE}.tmp"
mv -f "${GEOLENS_CONFIG_HASH_FILE}.tmp" "$GEOLENS_CONFIG_HASH_FILE"
success "GeoLens production stack deployed; every configured service has a running container and none reports unhealthy."

###############################################################################
# Installing GeoLibre
###############################################################################

###############################################################################
# Managing GeoLibre Container
###############################################################################

# IMAGE_NAME="ghcr.io/opengeos/geolibre:latest"
# CONTAINER_NAME="geolibre"

# info "Checking GeoLibre image status..."

# # 1. Get container status & image ID running inside the container
# CONTAINER_STATUS="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not-found")"
# RUNNING_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "none")"

# # 2. Pull silently
# docker pull -q "$IMAGE_NAME" >/dev/null || true

# # 3. Get exact image ID of the local tag
# LATEST_IMAGE_ID="$(docker image inspect "$IMAGE_NAME" --format '{{.Id}}' 2>/dev/null || echo "missing")"

# if [[ "$CONTAINER_STATUS" == "running" && "$RUNNING_IMAGE_ID" == "$LATEST_IMAGE_ID" ]]; then
#     success "GeoLibre is already running on the latest image ID (${LATEST_IMAGE_ID:7:12}). Skipping."
# else
#     info "Updating GeoLibre container..."

#     if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
#         docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
#         docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
#     fi

#     docker run -d \
#       --name "$CONTAINER_NAME" \
#       --restart always \
#       -p 127.0.0.1:8081:80 \
#       -e GEOLIBRE_SHARE_URL=off \
#       -e GEOLIBRE_GEOLENS_URL="https://${GEOLENS_URL}" \
#       "$IMAGE_NAME" >/dev/null

#     # Brief pause to verify the container didn't immediately crash
#     sleep 2
#     NEW_STATUS="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "failed")"

#     if [[ "$NEW_STATUS" == "running" ]]; then
#         success "GeoLibre container updated and running."
#     else
#         warn "GeoLibre started but status is '$NEW_STATUS'. Check logs with: docker logs $CONTAINER_NAME"
#     fi
# fi

###############################################################################
# Managing GeoLibre Stack (Native Compose + Local Override)
###############################################################################

BASE_DIR="${BASE_DIR:-$HOME}"
GEOLIBRE_DIR="${BASE_DIR}/GeoLibre"
# Define your GeoLens container/service port on the local machine
GEOLENS_PORT=${GEOLENS_PORT:-8080}
GEOLIBRE_WEB_PORT=${GEOLIBRE_WEB_PORT:-8081}
GEOLIBRE_SERVER_PORT=${GEOLIBRE_SERVER_PORT:-8000}
GEOLIBRE_COLLAB_PORT=${GEOLIBRE_COLLAB_PORT:-8787}

cd "$HOME"

# Export variable so Docker Compose can interpolate base file syntax
export POSTGRES_PASSWORD="$GEOLIBRE_POSTGRES_PASSWORD"
IMAGE_NAME="$GEOLIBRE_WEB_IMAGE"
if [[ "$IMAGE_NAME" == *":latest" ]]; then
    warn "ALLOW_FLOATING_GEOLIBRE_IMAGE=1 permits a non-reproducible :latest deployment."
fi
if [[ "$GEOLENS_VERSION" == "latest" ]]; then
    warn "ALLOW_FLOATING_GEOLENS_IMAGE=1 permits a non-reproducible GeoLens latest deployment."
fi
NEED_DEPLOY=false

info "Checking GeoLibre stack status in ${GEOLIBRE_DIR}..."

# -----------------------------------------------------------------------------
# 1. Sync source and install the version-pinned customization overlay
# -----------------------------------------------------------------------------
GEOLIBRE_CUSTOMIZATION_DIR="${GEOLIBRE_CUSTOMIZATION_DIR:-$HOME/GeoLibre-customizations}"
GEOLIBRE_CUSTOMIZATION_TEST_DIR="${GEOLIBRE_CUSTOMIZATION_DIR}/tests"
REL_AUTH_FILE="backend/geolibre_server_api/geolibre_server_api/auth.py"
REL_CLERK_FILE="backend/geolibre_server_api/geolibre_server_api/clerk_auth.py"
REL_TEST_OAUTH="backend/geolibre_server_api/tests/test_oauth.py"
REL_TEST_OIDC="backend/geolibre_server_api/tests/test_oidc.py"
REL_TEST_SCIM="backend/geolibre_server_api/tests/test_scim.py"

NEED_BUILD_BACKEND=false
if [[ ! -d "$GEOLIBRE_DIR" ]]; then
    info "Cloning GeoLibre repository into ${GEOLIBRE_DIR}..."
    git clone --depth 1 https://github.com/opengeos/GeoLibre.git "$GEOLIBRE_DIR"
    NEED_DEPLOY=true
    NEED_BUILD_BACKEND=true
fi

# The customization directory is the sole source of truth. This deployment
# script never bootstraps files from the checkout and never patches Python
# source. Create the overlay once with export_geolibre_customizations.sh before
# running this script; after that, edit/maintain only the overlay files.
[[ -d "$GEOLIBRE_CUSTOMIZATION_DIR" ]] || die "Customization directory is missing: $GEOLIBRE_CUSTOMIZATION_DIR. Run the one-time export_geolibre_customizations.sh against your current working checkout before updating GeoLibre."
[[ -f "${GEOLIBRE_CUSTOMIZATION_DIR}/UPSTREAM_VERSION" ]] || die "Missing ${GEOLIBRE_CUSTOMIZATION_DIR}/UPSTREAM_VERSION. Run the one-time export script first."
[[ -d "$GEOLIBRE_CUSTOMIZATION_TEST_DIR" ]] || die "Missing customization tests directory: $GEOLIBRE_CUSTOMIZATION_TEST_DIR"

for file in \
    "${GEOLIBRE_CUSTOMIZATION_DIR}/auth.py" \
    "${GEOLIBRE_CUSTOMIZATION_DIR}/clerk_auth.py" \
    "${GEOLIBRE_CUSTOMIZATION_TEST_DIR}/test_oauth.py" \
    "${GEOLIBRE_CUSTOMIZATION_TEST_DIR}/test_oidc.py" \
    "${GEOLIBRE_CUSTOMIZATION_TEST_DIR}/test_scim.py"; do
    [[ -f "$file" ]] || die "Required customization file is missing: $file"
done

PINNED_HASH="$(tr -d '[:space:]' < "${GEOLIBRE_CUSTOMIZATION_DIR}/UPSTREAM_VERSION")"
LOCAL_HASH="$(git -C "$GEOLIBRE_DIR" rev-parse HEAD)"
[[ "$PINNED_HASH" == "$LOCAL_HASH" ]] || die "Customization overlay was tested against ${PINNED_HASH}, but checkout is ${LOCAL_HASH}. Review compatibility and update ${GEOLIBRE_CUSTOMIZATION_DIR}/UPSTREAM_VERSION only after validating the overlay."

# Do not reset, patch, or copy anything from the checkout into the overlay.
# The maintained overlay is installed below as the source of truth.

info "Checking GeoLibre Git repository for updates..."
git -C "$GEOLIBRE_DIR" fetch -q origin
REMOTE_HASH="$(git -C "$GEOLIBRE_DIR" rev-parse '@{u}' 2>/dev/null || echo "$LOCAL_HASH")"
if [[ "$LOCAL_HASH" != "$REMOTE_HASH" ]]; then
    die "Upstream GeoLibre updates are available, but the customization overlay is pinned to ${PINNED_HASH}. Review/rebase the five maintained files against the new upstream version before updating; no automatic pull was performed."
fi

SRC_AUTH_FILE="${GEOLIBRE_DIR}/${REL_AUTH_FILE}"
SRC_CLERK_FILE="${GEOLIBRE_DIR}/${REL_CLERK_FILE}"
info "Installing maintained authentication and test files from ${GEOLIBRE_CUSTOMIZATION_DIR}..."
for pair in \
    "${GEOLIBRE_CUSTOMIZATION_DIR}/auth.py|${GEOLIBRE_DIR}/${REL_AUTH_FILE}" \
    "${GEOLIBRE_CUSTOMIZATION_DIR}/clerk_auth.py|${GEOLIBRE_DIR}/${REL_CLERK_FILE}" \
    "${GEOLIBRE_CUSTOMIZATION_TEST_DIR}/test_oauth.py|${GEOLIBRE_DIR}/${REL_TEST_OAUTH}" \
    "${GEOLIBRE_CUSTOMIZATION_TEST_DIR}/test_oidc.py|${GEOLIBRE_DIR}/${REL_TEST_OIDC}" \
    "${GEOLIBRE_CUSTOMIZATION_TEST_DIR}/test_scim.py|${GEOLIBRE_DIR}/${REL_TEST_SCIM}"; do
    src="${pair%%|*}"
    dst="${pair#*|}"
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
        NEED_DEPLOY=true
        NEED_BUILD_BACKEND=true
        install -m 0644 "$src" "$dst"
    fi
done

python3 -m py_compile "$SRC_AUTH_FILE" "$SRC_CLERK_FILE"
if command -v uv >/dev/null 2>&1; then
    (cd "${GEOLIBRE_DIR}/backend/geolibre_server_api" && uv run pytest tests/test_oauth.py tests/test_oidc.py tests/test_scim.py)
elif python3 -m pytest --version >/dev/null 2>&1; then
    (cd "${GEOLIBRE_DIR}/backend/geolibre_server_api" && python3 -m pytest tests/test_oauth.py tests/test_oidc.py tests/test_scim.py)
else
    die "pytest is unavailable. Install the GeoLibre backend test dependencies (or uv) and rerun; deployment was not started."
fi

# Write .env atomically and keep it private. Compose reads this file for interpolation.
dotenv_quote() {
    DOTENV_VALUE="$1" python3 -c 'import os; v=os.environ["DOTENV_VALUE"]; print("\x27" + v.replace("\x27", "\\\x27") + "\x27")'
}
GEOLIBRE_POSTGRES_PASSWORD_DOTENV="$(dotenv_quote "$GEOLIBRE_POSTGRES_PASSWORD")"
GEOLIBRE_ENV_FILE="${GEOLIBRE_DIR}/.env"
GEOLIBRE_ENV_BEFORE="$(sha256sum "$GEOLIBRE_ENV_FILE" 2>/dev/null | cut -d' ' -f1 || true)"
GEOLIBRE_ENV_TMP="$(mktemp "${GEOLIBRE_DIR}/.env.XXXXXX")"
cat > "$GEOLIBRE_ENV_TMP" << EOF
POSTGRES_USER=geolibre
POSTGRES_PASSWORD=${GEOLIBRE_POSTGRES_PASSWORD_DOTENV}
POSTGRES_DB=geolibre
GEOLIBRE_WEB_PORT=${GEOLIBRE_WEB_PORT}
GEOLIBRE_SERVER_PORT=${GEOLIBRE_SERVER_PORT}
GEOLIBRE_COLLAB_PORT=${GEOLIBRE_COLLAB_PORT}
GEOLIBRE_SHARE_URL=https://share.${GEOLENS_URL}
GEOLIBRE_COLLAB_URL=wss://colab.${GEOLENS_URL}
GEOLIBRE_VIEWER_URL=https://gis.${GEOLENS_URL}
GEOLIBRE_CLERK_ISSUER=${GEOLIBRE_CLERK_ISSUER}
GEOLIBRE_CLERK_ALLOWED_ORIGINS=${GEOLIBRE_CLERK_ALLOWED_ORIGINS}
GEOLIBRE_CLERK_SCOPES='${GEOLIBRE_CLERK_SCOPES}'
GEOLIBRE_CORS_ORIGINS='${GEOLIBRE_CORS_ORIGINS}'
EOF
# Merge managed values into the existing env file while preserving unrelated keys.
GEOLIBRE_EXISTING_ENV="$GEOLIBRE_ENV_FILE" GEOLIBRE_DESIRED_ENV="$GEOLIBRE_ENV_TMP" python3 - <<'PYMERGE'
import os, re, tempfile
from pathlib import Path
existing = Path(os.environ['GEOLIBRE_EXISTING_ENV'])
desired = Path(os.environ['GEOLIBRE_DESIRED_ENV'])
managed_lines = desired.read_text().splitlines()
managed = {}
for line in managed_lines:
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=', line)
    if m:
        managed[m.group(1)] = line
old_lines = existing.read_text().splitlines() if existing.exists() else []
out = []
seen = set()
for line in old_lines:
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=', line)
    if not m:
        out.append(line)
        continue
    key = m.group(1)
    if key in managed:
        if key not in seen:
            out.append(managed[key])
            seen.add(key)
    else:
        out.append(line)
for key, line in managed.items():
    if key not in seen:
        out.append(line)
fd, temp = tempfile.mkstemp(prefix=existing.name + '.', dir=str(existing.parent))
try:
    with os.fdopen(fd, 'w') as f:
        f.write('\n'.join(out) + '\n')
    os.chmod(temp, 0o600)
    os.replace(temp, existing)
finally:
    if os.path.exists(temp): os.unlink(temp)
desired.unlink()
PYMERGE
GEOLIBRE_ENV_AFTER="$(sha256sum "$GEOLIBRE_ENV_FILE" | cut -d' ' -f1)"
if [[ "$GEOLIBRE_ENV_BEFORE" != "$GEOLIBRE_ENV_AFTER" ]]; then
    NEED_DEPLOY=true
fi

# -----------------------------------------------------------------------------
# 2. Check Web Image Status
# -----------------------------------------------------------------------------
info "Checking latest web image ($IMAGE_NAME)..."
RUNNING_WEB_CONTAINER="$(docker ps -aq --filter 'label=com.docker.compose.service=geolibre-web' | head -n 1 || true)"
RUNNING_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$RUNNING_WEB_CONTAINER" 2>/dev/null || echo "none")"

docker pull "$IMAGE_NAME"
LATEST_IMAGE_ID="$(docker image inspect "$IMAGE_NAME" --format '{{.Id}}')"

if [[ "$RUNNING_IMAGE_ID" != "$LATEST_IMAGE_ID" ]]; then
    info "New/missing GeoLibre web image detected (${LATEST_IMAGE_ID:7:12}); deployment required."
    NEED_DEPLOY=true
fi

# -----------------------------------------------------------------------------
# 3. Create a separate managed Compose override in the customization directory.
# Never overwrite GeoLibre/docker-compose.override.yml (it may be user-maintained).
# -----------------------------------------------------------------------------
OVERRIDE_FILE="${GEOLIBRE_CUSTOMIZATION_DIR}/managed-compose.override.yml"
OVERRIDE_BEFORE="$(sha256sum "$OVERRIDE_FILE" 2>/dev/null | cut -d' ' -f1 || true)"
OVERRIDE_TMP="$(mktemp "${GEOLIBRE_CUSTOMIZATION_DIR}/managed-compose.override.yml.XXXXXX")"
cat << EOF > "$OVERRIDE_TMP"
services:
  geolibre-web:
    build: !reset null
    image: ${IMAGE_NAME}
    ports: !override
      - "127.0.0.1:${GEOLIBRE_WEB_PORT:-8081}:80"
    environment:
      GEOLIBRE_SHARE_URL: "https://share.${GEOLENS_URL}"
      GEOLIBRE_COLLAB_URL: "wss://colab.${GEOLENS_URL}"
      GEOLIBRE_GEOLENS_URL: "https://${GEOLENS_URL}"
#      GEOLIBRE_CLERK_WAITLIST: ""
#      GEOLIBRE_AUTH0_DOMAIN: ""
#      GEOLIBRE_AUTH0_CLIENT_ID: ""

  geolibre-server:
    ports: !override
      - "127.0.0.1:${GEOLIBRE_SERVER_PORT:-8000}:8000"
    environment:
      # POSTGRES_USER: "geolibre"
      # POSTGRES_PASSWORD: "${POSTGRES_PASS}"
      GEOLIBRE_PUBLIC_URL: "https://share.${GEOLENS_URL}"
      GEOLIBRE_VIEWER_URL: "https://gis.${GEOLENS_URL}"
      GEOLIBRE_TRUSTED_PROXIES: "127.0.0.1/32"
      GEOLIBRE_PROXY_AUTH: "false"
      GEOLIBRE_PROXY_USER_HEADER: "Remote-User"
      GEOLIBRE_PROXY_EMAIL_HEADER: "Remote-Email"
      GEOLIBRE_CLERK_ISSUER: "${GEOLIBRE_CLERK_ISSUER:-https://suitable-lamprey-8117.clerk.accounts.dev}"
      GEOLIBRE_CLERK_ALLOWED_ORIGINS: "${GEOLIBRE_CLERK_ALLOWED_ORIGINS:-https://gis.${GEOLENS_URL}}"
      GEOLIBRE_CLERK_SCOPES: "${GEOLIBRE_CLERK_SCOPES:-read:projects write:projects share:public}"

      GEOLIBRE_CORS_ORIGINS: "${GEOLIBRE_CORS_ORIGINS:-https://${GEOLENS_URL},https://gis.${GEOLENS_URL},https://share.${GEOLENS_URL}}"
      GEOLIBRE_OAUTH_CLIENTS: >-
        [{
            "client_id":"geolibre-web",
            "name":"GeoLibre DFU Share",
            "redirect_uris":["https://gis.${GEOLENS_URL}/oauth-callback.html","http://localhost:5173/oauth-callback.html"],
            "scopes":["read:projects","write:projects","share:public"]
        }]

  geolibre-collab:
    ports: !override
      - "127.0.0.1:${GEOLIBRE_COLLAB_PORT:-8787}:8787"
    environment:
      # ALLOWED_ORIGINS: "https://share.${GEOLENS_URL},https://${GEOLENS_URL},https://gis.${GEOLENS_URL},https://colab.${GEOLENS_URL}"
      ALLOWED_ORIGINS: "https://gis.${GEOLENS_URL}"

  # postgres:
    # environment:
      # POSTGRES_USER: "geolibre"
      # POSTGRES_PASSWORD: "${POSTGRES_PASS}"
EOF
chmod 600 "$OVERRIDE_TMP"
if [[ -f "$OVERRIDE_FILE" ]] && cmp -s "$OVERRIDE_TMP" "$OVERRIDE_FILE"; then
    rm -f "$OVERRIDE_TMP"
else
    mv -f "$OVERRIDE_TMP" "$OVERRIDE_FILE"
fi
OVERRIDE_AFTER="$(sha256sum "$OVERRIDE_FILE" | cut -d' ' -f1)"
if [[ "$OVERRIDE_BEFORE" != "$OVERRIDE_AFTER" ]]; then
    NEED_DEPLOY=true
fi

# -----------------------------------------------------------------------------
# 4. Verify Active Services Health
# -----------------------------------------------------------------------------
COMPOSE_CMD=(docker compose --project-directory "$GEOLIBRE_DIR" -f "${GEOLIBRE_DIR}/docker-compose.yml")
if [[ -f "${GEOLIBRE_DIR}/docker-compose.override.yml" ]]; then
    COMPOSE_CMD+=( -f "${GEOLIBRE_DIR}/docker-compose.override.yml" )
fi
COMPOSE_CMD+=( -f "$OVERRIDE_FILE" )
if ! "${COMPOSE_CMD[@]}" config -q; then
    die "GeoLibre Compose configuration is invalid; no deployment was attempted."
fi
GEOLIBRE_CONFIG_HASH="$("${COMPOSE_CMD[@]}" config | sha256sum | awk '{print $1}')"
GEOLIBRE_CONFIG_HASH_FILE="${GEOLIBRE_CUSTOMIZATION_DIR}/.last-compose-config.sha256"
GEOLIBRE_PREVIOUS_CONFIG_HASH="$(cat "$GEOLIBRE_CONFIG_HASH_FILE" 2>/dev/null || true)"
if [[ "$GEOLIBRE_CONFIG_HASH" != "$GEOLIBRE_PREVIOUS_CONFIG_HASH" ]]; then
    info "Rendered GeoLibre Compose configuration changed; deployment is required."
    NEED_DEPLOY=true
fi

NON_RUNNING_SERVICES="$(check_compose_services COMPOSE_CMD)"
if [[ -n "$NON_RUNNING_SERVICES" ]]; then
    info "Stack services missing, stopped, or unhealthy. Deployment required."
    NEED_DEPLOY=true
fi
# If either locally built backend service has never had a container, build its image
# before the first start. Otherwise, image-only/config-only updates do not trigger builds.
for backend_service in geolibre-server geolibre-collab; do
    if [[ -z "$("${COMPOSE_CMD[@]}" ps -aq "$backend_service" 2>/dev/null || true)" ]]; then
        NEED_BUILD_BACKEND=true
    fi
done

# Force Docker BuildKit to use plain text output (prevents non-TTY/console errors)
export BUILDKIT_PROGRESS=plain

# -----------------------------------------------------------------------------
# 5. Execute Deployment
# -----------------------------------------------------------------------------
if [[ "$NEED_DEPLOY" == "false" ]]; then
    success "GeoLibre stack is up to date and healthy. Skipping container recreation."
else
    if [[ "$NEED_BUILD_BACKEND" == "true" ]]; then
        info "Maintained backend source changed; building geolibre-server and geolibre-collab..."
        "${COMPOSE_CMD[@]}" --progress=plain build geolibre-server geolibre-collab
    else
        info "No maintained backend source change detected; skipping backend build."
    fi

    #docker compose --progress=plain \
    #  --project-directory "GeoLibre" \
    #  -f "GeoLibre/docker-compose.yml" \
    #  -f "GeoLibre/docker-compose.override.yml" \
    #  build geolibre-server geolibre-collab >/dev/null 2>&1

    info "Starting GeoLibre stack..."
    "${COMPOSE_CMD[@]}" up -d
#docker compose -f GeoLibre/docker-compose.yml -f GeoLibre/docker-compose.override.yml up -d >/dev/null
    sleep 2

    FAILED_SERVICES="$(check_compose_services COMPOSE_CMD)"

    if [[ -z "$FAILED_SERVICES" ]]; then
        printf '%s\n' "$GEOLIBRE_CONFIG_HASH" > "${GEOLIBRE_CONFIG_HASH_FILE}.tmp"
        chmod 600 "${GEOLIBRE_CONFIG_HASH_FILE}.tmp"
        mv -f "${GEOLIBRE_CONFIG_HASH_FILE}.tmp" "$GEOLIBRE_CONFIG_HASH_FILE"
        success "GeoLibre stack updated; every configured service has a running container and none reports unhealthy."
    else
        error "One or more GeoLibre services failed the post-deployment check:"
        echo "$FAILED_SERVICES" >&2
        "${COMPOSE_CMD[@]}" logs --tail=80 >&2 || true
        die "GeoLibre deployment did not pass the container-state check. Nginx configuration was not changed."
    fi
fi

info "Might need to perform a hard refresh (Ctrl + Shift + R or Cmd + Shift + R)"

###############################################################################
# Configure Nginx Reverse Proxy (HTTP; TLS termination is external)
###############################################################################

info "Setting up Nginx reverse proxy..."

# Install Nginx only if it is not already installed
if ! command -v nginx >/dev/null 2>&1; then
    info "Installing Nginx..."
#    sudo apt-get update -qq < /dev/null
    sudo apt-get install -y -qq nginx < /dev/null
else
    info "Nginx is already installed. Skipping installation."
fi

NGINX_SITE="/etc/nginx/sites-available/geolens"
NGINX_TEMP="$(mktemp)"
NGINX_BACKUP="$(mktemp)"
NGINX_HAD_OLD=false
if sudo test -f "$NGINX_SITE"; then
    sudo cp -a "$NGINX_SITE" "$NGINX_BACKUP"
    NGINX_HAD_OLD=true
fi
cat <<EOF > "$NGINX_TEMP"
# Map for dynamic WebSocket handling
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# GeoLens (${GEOLENS_URL}/)
server {
    listen 80;
    server_name ${GEOLENS_URL};

    client_max_body_size 10000M;

    # ACME Challenge location for upstream SSL validation
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type text/plain;
        try_files \$uri = 404;
    }

    location / {
        proxy_pass http://127.0.0.1:${GEOLENS_PORT};

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        # Instructs GeoLens that the client is connecting over HTTPS upstream
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
#        proxy_read_timeout 600s;
#        proxy_send_timeout 600s;
    }
}

# GeoLibre (gis.${GEOLENS_URL})
server {
    listen 80;
    server_name gis.${GEOLENS_URL};

    client_max_body_size 100M;

    # ACME Challenge location for upstream SSL validation
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type text/plain;
        try_files \$uri = 404;
    }

    location / {
        proxy_pass http://127.0.0.1:${GEOLIBRE_WEB_PORT};

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_http_version 1.1;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}

# GeoLibre Sharing REST API (share.${GEOLENS_URL})
server {
    listen 80;
    server_name share.${GEOLENS_URL};

    # Allows uploading larger project bundles
    client_max_body_size 100M;

    # ACME Challenge location for upstream SSL validation
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type text/plain;
        try_files \$uri = 404;
    }

    # GeoLibre expects GET /api/shares, while the self-hosted backend exposes GET /api/projects.
    # 1. List endpoint: /api/shares -> /api/projects (with key translation)
    ###
    # will likely need to remove this when /api/shares is exposed
    ###
#     location = /api/shares {
#         proxy_pass http://127.0.0.1:8000/api/projects;
#         proxy_set_header Host \$host;
#         proxy_set_header X-Real-IP \$remote_addr;
#         proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
#         proxy_set_header X-Forwarded-Proto https;

#         # Disable backend encoding so Nginx can process the JSON string
#         proxy_set_header Accept-Encoding "";

#         # Rename the root JSON key expected by the Share modal
#         sub_filter_types application/json;
#         # Backend returns:
#         #   {"projects":[...]}
#         #
#         # GeoLibre client expects:
#         #   {"shares":[...]}
#         sub_filter '"projects":' '"shares":';
# #        sub_filter '"viewerUrl":' '"shareUrl":';
#         sub_filter_once off;
#     }

    # # 2. Individual items (GET, DELETE, PUT): /api/shares/:id -> /api/projects/:id
    # location /api/shares/ {
    #     proxy_pass http://127.0.0.1:8000/api/projects/;

    #     proxy_set_header Host \$host;
    #     proxy_set_header X-Real-IP \$remote_addr;
    #     proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    #     proxy_set_header X-Forwarded-Proto https;
    # }

    # Default backend proxying for all non-API routes.
    location / {
       # Do not accept client-supplied reverse-proxy identity headers.
       proxy_set_header Remote-User "";
       proxy_set_header Remote-Email "";
       proxy_set_header Host \$host;
       proxy_pass http://127.0.0.1:${GEOLIBRE_SERVER_PORT};
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto https;
       proxy_set_header X-Forwarded-Host \$host;
   }

    # GeoLibre API
    location /api/ {
        proxy_set_header Remote-User "";
        proxy_set_header Remote-Email "";
        proxy_pass http://127.0.0.1:${GEOLIBRE_SERVER_PORT};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
    }

    location /oauth/ {
        #proxy_pass http://127.0.0.1:8000;
        proxy_pass http://127.0.0.1:${GEOLIBRE_SERVER_PORT};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;

        # Never trust these from the public client.
        proxy_set_header Remote-User "";
        proxy_set_header Remote-Email "";
    }

}

# Live Collaboration WebSocket Server (colab.${GEOLENS_URL})
server {
    listen 80;
    server_name colab.${GEOLENS_URL};

    # ACME Challenge location for upstream SSL validation
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type text/plain;
        try_files \$uri = 404;
    }

    location / {
        #proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:${GEOLIBRE_COLLAB_PORT};
        #proxy_set_header Connection "upgrade";
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header Origin \$http_origin;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        # Tell backend that the edge connection is HTTPS/WSS
        proxy_set_header X-Forwarded-Proto https;

        # Keep WebSocket connection alive (prevents 60s timeout drops)
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
EOF

sudo install -m 0644 "$NGINX_TEMP" "$NGINX_SITE"
sudo ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/geolens
if ! sudo nginx -t; then
    error "New Nginx configuration is invalid; restoring the previous configuration."
    if [[ "$NGINX_HAD_OLD" == "true" ]]; then
        sudo cp -a "$NGINX_BACKUP" "$NGINX_SITE"
    else
        sudo rm -f "$NGINX_SITE" /etc/nginx/sites-enabled/geolens
    fi
    rm -f "$NGINX_TEMP" "$NGINX_BACKUP"
    exit 1
fi
if ! sudo systemctl reload nginx; then
    error "Nginx reload failed; restoring the previous site configuration."
    if [[ "$NGINX_HAD_OLD" == "true" ]]; then
        sudo cp -a "$NGINX_BACKUP" "$NGINX_SITE"
    else
        sudo rm -f "$NGINX_SITE" /etc/nginx/sites-enabled/geolens
    fi
    sudo nginx -t && sudo systemctl reload nginx || true
    rm -f "$NGINX_TEMP" "$NGINX_BACKUP"
    die "Nginx reload failed; previous configuration restored where possible."
fi
rm -f "$NGINX_TEMP" "$NGINX_BACKUP"
success "Nginx proxy active."
warn "This generated Nginx site listens on HTTP port 80 only. Confirm an external TLS terminator/proxy handles HTTPS for ${GEOLENS_URL}, gis.${GEOLENS_URL}, share.${GEOLENS_URL}, and colab.${GEOLENS_URL}."

###############################################################################
# Summary
###############################################################################

echo "======================================================================"
success "Deployment complete!"
echo "GeoLens URL: https://${GEOLENS_URL}"
echo "GeoLibre URL: https://gis.${GEOLENS_URL}"
echo "======================================================================"

info "Modify settings in UI:

General
    - Enable Require Metadata for Publishing
    - Enable Dataset Editing

Auth
    - Disable Require Email Verification
    - Add centrogeo.edu.mx as domain
    
Ensure you add file /var/www/html/.well-known/acme-challenge/<token file>"

