#!/usr/bin/env bash
# Smoke-test OpenAI-compatible llama-server on a Pod proxy URL.
set -euo pipefail

BASE_URL="${1:-${BASE_URL:-}}"
API_KEY="${2:-${API_KEY:-}}"
MODEL="${MODEL_ALIAS:-local-gguf}"

if [[ -z "$BASE_URL" || -z "$API_KEY" ]]; then
  echo "Usage: $0 <https://xxx-8000.proxy.runpod.net> <API_KEY>"
  echo "   or: BASE_URL=... API_KEY=... $0"
  exit 1
fi

BASE_URL="${BASE_URL%/}"

echo "== GET /v1/models =="
curl -sS -o /tmp/gto_models.json -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer ${API_KEY}" \
  "${BASE_URL}/v1/models" || true
head -c 400 /tmp/gto_models.json; echo

echo "== POST /v1/chat/completions =="
curl -sS -o /tmp/gto_chat.json -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":16,\"temperature\":0}" \
  "${BASE_URL}/v1/chat/completions" || true
head -c 800 /tmp/gto_chat.json; echo
