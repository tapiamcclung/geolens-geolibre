#!/usr/bin/env bash
set -Eeuo pipefail

GEOLIBRE_DIR="${GEOLIBRE_DIR:-$HOME/GeoLibre}"
GEOLENS_DIR="${GEOLENS_DIR:-$HOME/geolens}"

failures=0

check() {
    local label="$1"
    shift

    echo
    echo "=== $label ==="
    if "$@"; then
        echo "PASS: $label"
    else
        echo "FAIL: $label"
        failures=$((failures + 1))
    fi
}

check "Setup script Bash syntax" bash -n "$HOME/setup.sh"

check "GeoLibre Compose configuration" \
    docker compose \
    --project-directory "$GEOLIBRE_DIR" \
    -f "$GEOLIBRE_DIR/docker-compose.yml" \
    -f "$GEOLIBRE_DIR/docker-compose.override.yml" \
    config --quiet

# Validate GeoLens with its discovered base and override files.
if [[ -f "$GEOLENS_DIR/docker-compose.yml" &&
      -f "$GEOLENS_DIR/docker-compose.override.yml" ]]; then
    check "GeoLens Compose configuration" \
        docker compose \
        --project-directory "$GEOLENS_DIR" \
        -f "$GEOLENS_DIR/docker-compose.prod.yml" \
        -f "$GEOLENS_DIR/docker-compose.override.yml" \
        config --quiet
else
    echo
    echo "SKIP: GeoLens base/override Compose files not found."
fi

# nginx -t reads the active configuration; it does not reload it.
check "Nginx configuration" sudo nginx -t

echo
if (( failures > 0 )); then
    echo "Validation finished with $failures failure(s)."
    exit 1
fi

echo "All available validation checks passed."
