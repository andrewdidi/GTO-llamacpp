#!/usr/bin/env bash
# Start llama-server on HOST:PORT with API key from config/env.
# 优先级：容器/RunPod 环境变量 > config/config.env > 默认值
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${ROOT}/config/config.env"
if [[ ! -f "$CFG" && -f /gto/config/config.env ]]; then
  CFG=/gto/config/config.env
fi

# 先保存已有环境变量（RunPod 注入），避免被 config.env 占位符覆盖
_SAVED_API_KEY="${API_KEY-}"
_SAVED_LLAMA_API_KEY="${LLAMA_API_KEY-}"
_SAVED_HF_TOKEN="${HF_TOKEN-}"
_SAVED_HF_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN-}"
_SAVED_HF_REPO_ID="${HF_REPO_ID-}"
_SAVED_HF_LOCAL_DIR="${HF_LOCAL_DIR-}"
_SAVED_MODEL_PATH="${MODEL_PATH-}"
_SAVED_MODEL_URL="${MODEL_URL-}"
_SAVED_MODEL_ALIAS="${MODEL_ALIAS-}"
_SAVED_HOST="${HOST-}"
_SAVED_PORT="${PORT-}"
_SAVED_N_GPU_LAYERS="${N_GPU_LAYERS-}"
_SAVED_CTX_SIZE="${CTX_SIZE-}"

if [[ -f "$CFG" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CFG"
  set +a
fi

# 环境变量覆盖文件
[[ -n "${_SAVED_API_KEY}" ]] && API_KEY="$_SAVED_API_KEY"
[[ -n "${_SAVED_LLAMA_API_KEY}" ]] && LLAMA_API_KEY="$_SAVED_LLAMA_API_KEY"
[[ -n "${_SAVED_HF_TOKEN}" ]] && HF_TOKEN="$_SAVED_HF_TOKEN"
[[ -n "${_SAVED_HF_HUB_TOKEN}" ]] && HUGGING_FACE_HUB_TOKEN="$_SAVED_HF_HUB_TOKEN"
[[ -n "${_SAVED_HF_REPO_ID}" ]] && HF_REPO_ID="$_SAVED_HF_REPO_ID"
[[ -n "${_SAVED_HF_LOCAL_DIR}" ]] && HF_LOCAL_DIR="$_SAVED_HF_LOCAL_DIR"
[[ -n "${_SAVED_MODEL_PATH}" ]] && MODEL_PATH="$_SAVED_MODEL_PATH"
[[ -n "${_SAVED_MODEL_URL}" ]] && MODEL_URL="$_SAVED_MODEL_URL"
[[ -n "${_SAVED_MODEL_ALIAS}" ]] && MODEL_ALIAS="$_SAVED_MODEL_ALIAS"
[[ -n "${_SAVED_HOST}" ]] && HOST="$_SAVED_HOST"
[[ -n "${_SAVED_PORT}" ]] && PORT="$_SAVED_PORT"
[[ -n "${_SAVED_N_GPU_LAYERS}" ]] && N_GPU_LAYERS="$_SAVED_N_GPU_LAYERS"
[[ -n "${_SAVED_CTX_SIZE}" ]] && CTX_SIZE="$_SAVED_CTX_SIZE"

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
export CACHE_ROOT="${CACHE_ROOT:-/models/cache}"
# 提前准备可写目录，避免 torch import 阶段 tempfile/cache 崩掉
mkdir -p "$CACHE_ROOT"/{home,tmp,torch/inductor,torch/hub,hf,xdg} /tmp
export HOME="${HOME:-$CACHE_ROOT/home}"
export TMPDIR="${TMPDIR:-$CACHE_ROOT/tmp}"
export TEMP="$TMPDIR"
export TMP="$TMPDIR"
export TORCHINDUCTOR_CACHE_DIR="${TORCHINDUCTOR_CACHE_DIR:-$CACHE_ROOT/torch/inductor}"
export TORCH_HOME="${TORCH_HOME:-$CACHE_ROOT/torch}"
export HF_HOME="${HF_HOME:-$CACHE_ROOT/hf}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$CACHE_ROOT/xdg}"
export TORCHDYNAMO_DISABLE=1
export TORCH_COMPILE_DISABLE=1

log() { echo "[gto-llamacpp] $*"; }

if [[ -z "$API_KEY" || "$API_KEY" == "sk-gto-REPLACE_ME" ]]; then
  log "ERROR: API_KEY 未设置（或仍是占位符 sk-gto-REPLACE_ME）"
  log "  RunPod: Pod → Edit → Environment Variables 增加："
  log "    API_KEY=你的密钥"
  log "    HF_TOKEN=你的HF令牌"
  log "  然后 Restart Pod（勿用 Serverless）"
  exit 1
fi

if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
  log "ERROR: llama-server not found: $LLAMA_SERVER_BIN"
  exit 1
fi

ENSURE="${ROOT}/scripts/ensure_model.sh"
if [[ -x "$ENSURE" ]]; then
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
