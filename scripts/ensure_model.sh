#!/usr/bin/env bash
# 若本地无模型：用 HF_TOKEN 拉取 HF_REPO_ID → HF_LOCAL_DIR，再转 GGUF / 量化到 MODEL_PATH。
set -euo pipefail

log() { echo "[gto-llamacpp] $*"; }

HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
HF_REPO_ID="${HF_REPO_ID:-}"
HF_LOCAL_DIR="${HF_LOCAL_DIR:-/models/hf/Qwen3.5-9B}"
MODEL_PATH="${MODEL_PATH:-/models/gguf/Qwen3.5-9B-Q4_K_M.gguf}"
MODEL_URL="${MODEL_URL:-}"
AUTO_CONVERT="${AUTO_CONVERT:-1}"
CONVERT_OUTTYPE="${CONVERT_OUTTYPE:-q8_0}"
QUANTIZE_TYPE="${QUANTIZE_TYPE:-Q4_K_M}"
KEEP_CONVERT_TMP="${KEEP_CONVERT_TMP:-0}"
CONVERT_SCRIPT="${CONVERT_SCRIPT:-/app/convert_hf_to_gguf.py}"
LLAMA_QUANTIZE_BIN="${LLAMA_QUANTIZE_BIN:-/app/llama-quantize}"
HF_DOWNLOAD_REVISION="${HF_DOWNLOAD_REVISION:-}"
CACHE_ROOT="${CACHE_ROOT:-/models/cache}"

# torch/transformers 在 RunPod 上常因 /tmp、HOME 不可写在 import 阶段崩；统一落到 Volume
prepare_runtime_dirs() {
  mkdir -p \
    "$CACHE_ROOT/home" \
    "$CACHE_ROOT/tmp" \
    "$CACHE_ROOT/torch/inductor" \
    "$CACHE_ROOT/torch/hub" \
    "$CACHE_ROOT/hf" \
    "$CACHE_ROOT/xdg" \
    /tmp
  export HOME="${HOME:-$CACHE_ROOT/home}"
  export TMPDIR="$CACHE_ROOT/tmp"
  export TEMP="$TMPDIR"
  export TMP="$TMPDIR"
  export TORCHINDUCTOR_CACHE_DIR="$CACHE_ROOT/torch/inductor"
  export TORCH_HOME="$CACHE_ROOT/torch"
  export HF_HOME="${HF_HOME:-$CACHE_ROOT/hf}"
  export XDG_CACHE_HOME="$CACHE_ROOT/xdg"
  export TORCHDYNAMO_DISABLE=1
  export TORCH_COMPILE_DISABLE=1
  # 转换用 CPU 即可，避免无谓的 CUDA 初始化干扰
  export CUDA_VISIBLE_DEVICES="${CONVERT_CUDA_VISIBLE_DEVICES:-}"
}

need_hf_download() {
  [[ -n "$HF_REPO_ID" ]] || return 1
  [[ -f "${HF_LOCAL_DIR}/config.json" ]] && return 1
  [[ -f "${HF_LOCAL_DIR}/.hf_download_ok" ]] && return 1
  return 0
}

download_hf() {
  if [[ -z "$HF_TOKEN" ]]; then
    log "ERROR: HF_REPO_ID set but HF_TOKEN empty"
    exit 1
  fi
  prepare_runtime_dirs
  mkdir -p "$HF_LOCAL_DIR"
  log "HF download: $HF_REPO_ID -> $HF_LOCAL_DIR"
  export HF_TOKEN
  export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
  export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"

  local rev_args=()
  if [[ -n "$HF_DOWNLOAD_REVISION" ]]; then
    rev_args=(--revision "$HF_DOWNLOAD_REVISION")
  fi

  if command -v hf >/dev/null 2>&1; then
    hf download "$HF_REPO_ID" \
      --local-dir "$HF_LOCAL_DIR" \
      --token "$HF_TOKEN" \
      "${rev_args[@]}"
  elif command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$HF_REPO_ID" \
      --local-dir "$HF_LOCAL_DIR" \
      --token "$HF_TOKEN" \
      "${rev_args[@]}"
  else
    export HF_REPO_ID HF_LOCAL_DIR HF_TOKEN HF_DOWNLOAD_REVISION
    python3 - <<'PY'
import os
from huggingface_hub import snapshot_download

rev = os.environ.get("HF_DOWNLOAD_REVISION") or None
snapshot_download(
    repo_id=os.environ["HF_REPO_ID"],
    local_dir=os.environ["HF_LOCAL_DIR"],
    token=os.environ["HF_TOKEN"],
    revision=rev,
)
PY
  fi
  touch "${HF_LOCAL_DIR}/.hf_download_ok"
  log "HF download done"
}

convert_and_quantize() {
  if [[ ! -f "${HF_LOCAL_DIR}/config.json" ]]; then
    log "ERROR: no HF model at $HF_LOCAL_DIR (missing config.json)"
    exit 1
  fi
  if [[ ! -f "$CONVERT_SCRIPT" ]]; then
    log "ERROR: convert script missing: $CONVERT_SCRIPT"
    exit 1
  fi

  prepare_runtime_dirs
  mkdir -p "$(dirname "$MODEL_PATH")"
  local tmp_gguf
  tmp_gguf="$(dirname "$MODEL_PATH")/Qwen3.5-9B.${CONVERT_OUTTYPE}.gguf"

  if [[ ! -f "$tmp_gguf" ]]; then
    log "Converting HF -> GGUF ($CONVERT_OUTTYPE): $tmp_gguf"
    log "  cache/tmp -> $CACHE_ROOT (TORCHDYNAMO_DISABLE=1)"
    # 官方脚本依赖 /app 下 conversion、gguf-py 相对路径
    local convert_dir
    convert_dir="$(dirname "$CONVERT_SCRIPT")"
    (
      cd "$convert_dir"
      python3 "$(basename "$CONVERT_SCRIPT")" "$HF_LOCAL_DIR" \
        --outfile "$tmp_gguf" \
        --outtype "$CONVERT_OUTTYPE"
    )
  else
    log "Reuse convert output: $tmp_gguf"
  fi

  if [[ "$QUANTIZE_TYPE" == "none" || "$QUANTIZE_TYPE" == "$CONVERT_OUTTYPE" ]]; then
    mv -f "$tmp_gguf" "$MODEL_PATH"
    log "MODEL_PATH ready: $MODEL_PATH"
    return 0
  fi

  if [[ ! -x "$LLAMA_QUANTIZE_BIN" ]]; then
    log "ERROR: llama-quantize missing; set QUANTIZE_TYPE=none to use $tmp_gguf"
    exit 1
  fi

  log "Quantize $CONVERT_OUTTYPE -> $QUANTIZE_TYPE: $MODEL_PATH"
  "$LLAMA_QUANTIZE_BIN" "$tmp_gguf" "$MODEL_PATH" "$QUANTIZE_TYPE"
  if [[ "$KEEP_CONVERT_TMP" != "1" ]]; then
    rm -f "$tmp_gguf"
  fi
  log "MODEL_PATH ready: $MODEL_PATH"
}

download_direct_url() {
  log "Downloading MODEL_URL -> $MODEL_PATH"
  mkdir -p "$(dirname "$MODEL_PATH")"
  local tmp="${MODEL_PATH}.partial"
  curl -L --fail --retry 3 --retry-delay 5 -o "$tmp" "$MODEL_URL"
  mv "$tmp" "$MODEL_PATH"
}

# --- main ---
prepare_runtime_dirs

if [[ -f "$MODEL_PATH" ]]; then
  log "Model present: $MODEL_PATH"
  exit 0
fi

if need_hf_download; then
  download_hf
elif [[ -n "$HF_REPO_ID" ]]; then
  log "HF cache hit: $HF_LOCAL_DIR"
fi

if [[ ! -f "$MODEL_PATH" && "$AUTO_CONVERT" == "1" && -n "$HF_REPO_ID" ]]; then
  convert_and_quantize
fi

if [[ ! -f "$MODEL_PATH" && -n "$MODEL_URL" ]]; then
  download_direct_url
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  log "ERROR: model missing: $MODEL_PATH"
  log "  Set HF_REPO_ID+HF_TOKEN (auto download+convert) or MODEL_URL or mount GGUF"
  exit 1
fi
