#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <path-to-App.app>"
    echo "Requires APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, APPLE_API_KEY_PATH in the environment."
    exit 1
fi

APP_PATH="$1"

: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"
: "${APPLE_API_KEY_PATH:?APPLE_API_KEY_PATH is required}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: app bundle not found: $APP_PATH"
    exit 1
fi

WORK_DIR="$(mktemp -d)"
ZIP_PATH="$WORK_DIR/$(basename "${APP_PATH%.app}")-notarize.zip"
SUBMISSION_OUTPUT="$WORK_DIR/submission.json"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Zipping $APP_PATH for notarization submission..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Submitting to Apple notary service (this can take a few minutes)..."
if ! xcrun notarytool submit "$ZIP_PATH" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait \
    --output-format json | tee "$SUBMISSION_OUTPUT"; then
    echo "Notarization submission failed." >&2
    submission_id=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SUBMISSION_OUTPUT" | head -1)
    if [[ -n "$submission_id" ]]; then
        echo "Fetching notary log for submission $submission_id..." >&2
        xcrun notarytool log "$submission_id" \
            --key "$APPLE_API_KEY_PATH" \
            --key-id "$APPLE_API_KEY_ID" \
            --issuer "$APPLE_API_ISSUER_ID" || true
    fi
    exit 1
fi

echo "Stapling notarization ticket to $APP_PATH..."
xcrun stapler staple "$APP_PATH"

echo "Validating stapled ticket..."
xcrun stapler validate "$APP_PATH"

echo "Assessing Gatekeeper acceptance..."
spctl --assess --type execute --verbose "$APP_PATH"

echo "Notarization complete."
