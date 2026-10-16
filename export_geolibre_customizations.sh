#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

GEOLIBRE_DIR="${GEOLIBRE_DIR:-$HOME/GeoLibre}"
CUSTOM_DIR="${GEOLIBRE_CUSTOMIZATION_DIR:-$HOME/GeoLibre-customizations}"
TEST_DIR="$CUSTOM_DIR/tests"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }

[[ -d "$GEOLIBRE_DIR/.git" ]] || die "GeoLibre Git checkout not found at $GEOLIBRE_DIR. Set GEOLIBRE_DIR to your current checkout."

AUTH_REL='backend/geolibre_server_api/geolibre_server_api/auth.py'
CLERK_REL='backend/geolibre_server_api/geolibre_server_api/clerk_auth.py'
OAUTH_REL='backend/geolibre_server_api/tests/test_oauth.py'
OIDC_REL='backend/geolibre_server_api/tests/test_oidc.py'
SCIM_REL='backend/geolibre_server_api/tests/test_scim.py'

for rel in "$AUTH_REL" "$CLERK_REL" "$OAUTH_REL" "$OIDC_REL" "$SCIM_REL"; do
    [[ -f "$GEOLIBRE_DIR/$rel" ]] || die "Required current file is missing: $GEOLIBRE_DIR/$rel"
done

grep -q 'resolve_clerk_session_token' "$GEOLIBRE_DIR/$AUTH_REL" || die "The checkout auth.py does not contain resolve_clerk_session_token. Refusing to export an auth.py without the Clerk integration. No files were copied."

if [[ -e "$CUSTOM_DIR" ]]; then
    [[ -f "$CUSTOM_DIR/UPSTREAM_VERSION" ]] || die "$CUSTOM_DIR already exists but has no UPSTREAM_VERSION. Inspect it manually; refusing to overwrite it."
    die "$CUSTOM_DIR already exists. This exporter never overwrites an existing customization directory. Use the existing files or choose a new GEOLIBRE_CUSTOMIZATION_DIR."
fi

mkdir -p "$TEST_DIR"
install -m 0600 "$GEOLIBRE_DIR/$AUTH_REL" "$CUSTOM_DIR/auth.py"
install -m 0600 "$GEOLIBRE_DIR/$CLERK_REL" "$CUSTOM_DIR/clerk_auth.py"
install -m 0600 "$GEOLIBRE_DIR/$OAUTH_REL" "$TEST_DIR/test_oauth.py"
install -m 0600 "$GEOLIBRE_DIR/$OIDC_REL" "$TEST_DIR/test_oidc.py"
install -m 0600 "$GEOLIBRE_DIR/$SCIM_REL" "$TEST_DIR/test_scim.py"
git -C "$GEOLIBRE_DIR" rev-parse HEAD > "$CUSTOM_DIR/UPSTREAM_VERSION"
chmod 0600 "$CUSTOM_DIR/UPSTREAM_VERSION"

python3 -m py_compile "$CUSTOM_DIR/auth.py" "$CUSTOM_DIR/clerk_auth.py" || die "Exported authentication modules failed Python syntax validation. The customization directory was created; inspect it before use."

info "Exported the five current files to $CUSTOM_DIR"
info "Pinned upstream commit: $(cat "$CUSTOM_DIR/UPSTREAM_VERSION")"
info "No Python source was patched, and existing files were not overwritten."
info "Review and back up this directory before running setup_improved.sh."
