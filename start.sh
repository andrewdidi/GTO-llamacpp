#!/usr/bin/env bash
# Start llama-server on HOST:PORT with API key from config/env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 兼容镜像内 /gto 与本地仓库根目录
CFG="${ROOT}/config/config.env"
if [[ ! -f "$CFG" && -f /gto/config/config.env ]]; then
  CFG=/gto/config/config.env
fi

if [[ -f "$CFG" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CFG"
  set +a
fi

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
MODEL_PATH="${MODEL_PATH:-/models/gguf/Qwen3.5-9B-Q4_K_M.gguf}"
MODEL_URL="${MODEL_URL:-}"
MODEL_ALIAS="${MODEL_ALIAS:-Qwen3.5-9B}"
API_KEY="${API_KEY:-${LLAMA_API_KEY:-}}"
N_GPU_LAYERS="${N_GPU_LAYERS:-999}"
CTX_SIZE="${CTX_SIZE:-8192}"
THREADS="${THREADS:-0}"
FLASH_ATTN="${FLASH_ATTN:-0}"
CONT_BATCHING="${CONT_BATCHING:-1}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-/app/llama-server}"

# HF download / convert (see scripts/ensure_model.sh)
export HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
export HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-$HF_TOKEN}"
export HF_REPO_ID="${HF_REPO_ID:-}"
export HF_LOCAL_DIR="${HF_LOCAL_DIR:-/models/hf/Qwen3.5-9B}"
export MODEL_PATH MODEL_URL
export AUTO_CONVERT="${AUTO_CONVERT:-1}"
export CONVERT_OUTTYPE="${CONVERT_OUTTYPE:-q8_0}"
export QUANTIZE_TYPE="${QUANTIZE_TYPE:-Q4_K_M}"
export KEEP_CONVERT_TMP="${KEEP_CONVERT_TMP:-0}"
export CONVERT_SCRIPT="${CONVERT_SCRIPT:-/app/convert_hf_to_gguf.py}"
export LLAMA_QUANTIZE_BIN="${LLAMA_QUANTIZE_BIN:-/app/llama-quantize}"
export HF_DOWNLOAD_REVISION="${HF_DOWNLOAD_REVISION:-}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
export LD_LIBRARY_PATH="/app${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

log() { echo "[gto-llamacpp] $*"; }

if [[ -z "$API_KEY" || "$API_KEY" == "sk-gto-REPLACE_ME" ]]; then
  log "ERROR: set API_KEY in config/config.env or environment"
  exit 1
fi

if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
  log "ERROR: llama-server not found: $LLAMA_SERVER_BIN"
  exit 1
fi

ENSURE="${ROOT}/scripts/ensure_model.sh"
if [[ -x "$ENSURE" ]]; then
  # shellcheck disable=SC1090
  bash "$ENSURE"
else
  log "ERROR: missing $ENSURE"
  exit 1
fi

ARGS=(
  -m "$MODEL_PATH"
  --host "$HOST"
  --port "$PORT"
  --api-key "$API_KEY"
  -ngl "$N_GPU_LAYERS"
  -c "$CTX_SIZE"
  --alias "$MODEL_ALIAS"
)

if [[ "$THREADS" != "0" && -n "$THREADS" ]]; then
  ARGS+=(-t "$THREADS")
fi
if [[ "$FLASH_ATTN" == "1" || "$FLASH_ATTN" == "true" ]]; then
  ARGS+=(-fa)
fi
if [[ "$CONT_BATCHING" == "1" || "$CONT_BATCHING" == "true" ]]; then
  ARGS+=(-cb)
fi

# shellcheck disable=SC2206
if [[ -n "$EXTRA_ARGS" ]]; then
  EXTRA_ARR=($EXTRA_ARGS)
  ARGS+=("${EXTRA_ARR[@]}")
fi

log "Listening ${HOST}:${PORT} model=$MODEL_PATH alias=$MODEL_ALIAS"
log "OpenAI base: http://<pod-proxy>:${PORT}/v1  (Bearer API_KEY)"
exec "$LLAMA_SERVER_BIN" "${ARGS[@]}"
