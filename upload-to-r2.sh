#!/usr/bin/env bash
# upload-to-r2.sh — push a GGUF weight file into the Cloudflare R2
# bucket that backs the Aether model catalog. Uses `rclone copy`
# under the hood because wrangler r2 object put caps at 300 MiB and
# every realistic GGUF is multi-gigabyte. rclone speaks R2's
# S3-compatible API via the `[r2]` remote defined in
# ~/.config/rclone/rclone.conf — see HOSTING.md §6.
#
# Prerequisites:
#   - rclone installed (`brew install rclone`)
#   - ~/.config/rclone/rclone.conf has an [r2] remote (HOSTING.md §6)
#
# Usage:
#   ./upload-to-r2.sh --file PATH --id MODEL-ID --engine ENGINE \
#                     [--display "Display Name"] [--license "License"] \
#                     [--ram-min GIB] [--context-default TOKENS]
#
# Example:
#   ./upload-to-r2.sh \
#     --file ./Qwopus3.5-4B-Coder-MTP-Q4_K_M.gguf \
#     --id qwopus-3.5-4b-coder-mtp-q4_k_m \
#     --engine llamacpp \
#     --display "Qwopus 3.5 4B Coder (MTP)" \
#     --ram-min 16 \
#     --context-default 32768

set -euo pipefail

# ── Args ────────────────────────────────────────────────────────────
FILE=""
ID=""
ENGINE="llamacpp"
DISPLAY=""
LICENSE=""
RAM_MIN=""
CONTEXT_DEFAULT="32768"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)             FILE="$2"; shift 2 ;;
    --id)               ID="$2"; shift 2 ;;
    --engine)           ENGINE="$2"; shift 2 ;;
    --display)          DISPLAY="$2"; shift 2 ;;
    --license)          LICENSE="$2"; shift 2 ;;
    --ram-min)          RAM_MIN="$2"; shift 2 ;;
    --context-default)  CONTEXT_DEFAULT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0"; exit 0 ;;
    *)
      echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$FILE"   ]] && { echo "--file is required"   >&2; exit 1; }
[[ -z "$ID"     ]] && { echo "--id is required"     >&2; exit 1; }
[[ -f "$FILE"   ]] || { echo "file not found: $FILE" >&2; exit 1; }

# ── Config ──────────────────────────────────────────────────────────
: "${R2_BUCKET:=ufrik-aether-models}"
: "${R2_PUBLIC_BASE:=https://aether-models.ufrik.com}"
: "${R2_REMOTE:=r2}"  # rclone remote name from rclone.conf

# Probe rclone is set up.
if ! command -v rclone >/dev/null 2>&1; then
  echo "rclone not installed (try: brew install rclone)" >&2
  exit 1
fi
if ! rclone listremotes 2>/dev/null | grep -q "^${R2_REMOTE}:$"; then
  echo "rclone has no '${R2_REMOTE}:' remote. See HOSTING.md §6." >&2
  exit 1
fi

# ── Compute SHA-256 + size ──────────────────────────────────────────
echo "→ computing sha256 of $FILE…"
SHA=$(shasum -a 256 "$FILE" | awk '{print $1}')
SIZE=$(stat -f '%z' "$FILE")
SIZE_HUMAN=$(du -h "$FILE" | awk '{print $1}')
echo "  sha256: $SHA"
echo "  size:   $SIZE bytes ($SIZE_HUMAN)"

# ── Upload via rclone (multipart) ───────────────────────────────────
KEY="$ENGINE/$ID/model.gguf"
URL="$R2_PUBLIC_BASE/$KEY"
echo "→ uploading to ${R2_REMOTE}:${R2_BUCKET}/$KEY (multipart)…"

# rclone copy uses the source filename; copy then rename to model.gguf.
SRC_NAME=$(basename "$FILE")
DEST_DIR="${R2_REMOTE}:${R2_BUCKET}/${ENGINE}/${ID}"

rclone copy --progress \
            --transfers 1 \
            --s3-chunk-size 100M \
            --s3-upload-concurrency 4 \
            --header-upload "Content-Type: application/octet-stream" \
            "$FILE" \
            "$DEST_DIR/"

# Rename the just-uploaded object to the canonical model.gguf.
if [[ "$SRC_NAME" != "model.gguf" ]]; then
  rclone moveto "$DEST_DIR/$SRC_NAME" "$DEST_DIR/model.gguf"
fi

echo "✓ uploaded → $URL"

# ── Emit manifest JSON ──────────────────────────────────────────────
MANIFEST_DIR="$(cd "$(dirname "$0")" && pwd)/manifests"
mkdir -p "$MANIFEST_DIR"
MANIFEST="$MANIFEST_DIR/$ID.json"

cat > "$MANIFEST" <<EOF
{
  "id": "$ID",
  "engine": "$ENGINE",
  "display_name": "${DISPLAY:-$ID}",
  "license": "${LICENSE:-unspecified}",
  "download": {
    "url": "$URL",
    "size_bytes": $SIZE,
    "sha256": "$SHA"
  },
  "ram_min_gib": ${RAM_MIN:-null},
  "context_default": $CONTEXT_DEFAULT
}
EOF
echo "✓ wrote manifest → $MANIFEST"

# ── Emit catalog snippet ────────────────────────────────────────────
cat <<EOF

╭──────────────────────────────────────────────────────────────────
│ Paste this into catalog.xml under <catalog>:
╰──────────────────────────────────────────────────────────────────

    <model id="$ID">
        <display-name>${DISPLAY:-$ID}</display-name>
        <vendor>(set me)</vendor>
        <engine>$ENGINE</engine>
        <license>${LICENSE:-unspecified}</license>
        <license-acknowledgement-required>false</license-acknowledgement-required>
        <download>
            <url>$URL</url>
            <size-bytes>$SIZE</size-bytes>
            <sha256>$SHA</sha256>
        </download>
        <context-default>$CONTEXT_DEFAULT</context-default>
        $( [[ -n "$RAM_MIN" ]] && echo "<ram-min-gib>$RAM_MIN</ram-min-gib>" )
        <mtp available="false"/>
    </model>

EOF
