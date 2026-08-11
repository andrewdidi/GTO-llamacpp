#!/usr/bin/env bash
# Download a GGUF into models/ (or MODEL_PATH).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="${1:-}"
OUT="${2:-${ROOT}/models/model.gguf}"
if [[ -z "$URL" ]]; then
  echo "Usage: $0 <MODEL_URL> [output_path]"
  exit 1
fi
mkdir -p "$(dirname "$OUT")"
echo "Downloading -> $OUT"
curl -L --fail --retry 3 -o "${OUT}.partial" "$URL"
mv "${OUT}.partial" "$OUT"
ls -lh "$OUT"
