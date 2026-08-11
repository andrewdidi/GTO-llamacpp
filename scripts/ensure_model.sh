#!/usr/bin/env bash
# 准备 MODEL_PATH（优先挂载盘上的现成 GGUF，避免整模转换撑爆磁盘）
# 顺序：已有文件 → MODEL_URL → HF_GGUF_REPO 单文件 →（可选）HF 全量转换
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "[gto-llamacpp] $*"; }

HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
HF_REPO_ID="${HF_REPO_ID:-}"
MODEL_URL="${MODEL_URL:-}"
# 默认直接拉 GGUF；全量 convert 很吃盘（HF≈18G + Q8 临时≈10G+）
HF_GGUF_REPO="${HF_GGUF_REPO:-unsloth/Qwen3.5-9B-GGUF}"
HF_GGUF_FILE="${HF_GGUF_FILE:-Qwen3.5-9B-Q4_K_M.gguf}"
AUTO_CONVERT="${AUTO_CONVERT:-0}"
CONVERT_OUTTYPE="${CONVERT_OUTTYPE:-q8_0}"
QUANTIZE_TYPE="${QUANTIZE_TYPE:-Q4_K_M}"
KEEP_CONVERT_TMP="${KEEP_CONVERT_TMP:-0}"
CONVERT_SCRIPT="${CONVERT_SCRIPT:-/app/convert_hf_to_gguf.py}"
LLAMA_QUANTIZE_BIN="${LLAMA_QUANTIZE_BIN:-/app/llama-quantize}"
HF_DOWNLOAD_REVISION="${HF_DOWNLOAD_REVISION:-}"
VOLUME_ROOT="${VOLUME_ROOT:-/models}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/volume_layout.sh"
prepare_volume_layout || exit 1

export CUDA_VISIBLE_DEVICES="${CONVERT_CUDA_VISIBLE_DEVICES:-}"
export HF_TOKEN
export HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-$HF_TOKEN}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"

hf_auth_args() {
  if [[ -n "$HF_TOKEN" ]]; then
    echo --token "$HF_TOKEN"
  fi
}

download_gguf_from_hf() {
  if [[ -z "$HF_GGUF_REPO" || -z "$HF_GGUF_FILE" ]]; then
    return 1
  fi
  if [[ -z "$HF_TOKEN" ]]; then
    log "WARN: HF_GGUF_REPO set but HF_TOKEN empty（公开仓或许仍可下）"
  fi
  mkdir -p "$(dirname "$MODEL_PATH")"
  local dest_dir
  dest_dir="$(dirname "$MODEL_PATH")"
  log "GGUF download: $HF_GGUF_REPO / $HF_GGUF_FILE -> $MODEL_PATH"

  # 下到 gguf 目录再落到 MODEL_PATH（避免多文件污染）
  local dl_dir="${VOLUME_ROOT}/gguf/.hf_dl"
  mkdir -p "$dl_dir"
  # shellcheck disable=SC2046
  if command -v hf >/dev/null 2>&1; then
    hf download "$HF_GGUF_REPO" "$HF_GGUF_FILE" \
      --local-dir "$dl_dir" \
      $(hf_auth_args)
  elif command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$HF_GGUF_REPO" "$HF_GGUF_FILE" \
      --local-dir "$dl_dir" \
      $(hf_auth_args)
  else
    export HF_GGUF_REPO HF_GGUF_FILE
    export DL_DIR="$dl_dir"
    python3 - <<'PY'
import os
from huggingface_hub import hf_hub_download
path = hf_hub_download(
    repo_id=os.environ["HF_GGUF_REPO"],
    filename=os.environ["HF_GGUF_FILE"],
    local_dir=os.environ["DL_DIR"],
    token=os.environ.get("HF_TOKEN") or None,
)
print(path)
PY
  fi

  local found=""
  if [[ -f "${dl_dir}/${HF_GGUF_FILE}" ]]; then
    found="${dl_dir}/${HF_GGUF_FILE}"
  else
    found="$(find "$dl_dir" -type f -name "$(basename "$HF_GGUF_FILE")" 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$found" || ! -f "$found" ]]; then
    log "ERROR: GGUF file not found after download: $HF_GGUF_FILE"
    return 1
  fi
  if [[ "$found" != "$MODEL_PATH" ]]; then
    mv -f "$found" "$MODEL_PATH"
  fi
  # 清理临时下载目录中的残留
  rm -rf "$dl_dir"
  log "GGUF ready: $MODEL_PATH ($(du -h "$MODEL_PATH" | awk '{print $1}'))"
  return 0
}

need_hf_weights() {
  [[ "$AUTO_CONVERT" == "1" ]] || return 1
  [[ -n "$HF_REPO_ID" ]] || return 1
  [[ -f "${HF_LOCAL_DIR}/config.json" ]] && return 1
  [[ -f "${HF_LOCAL_DIR}/.hf_download_ok" ]] && return 1
  return 0
}

download_hf_weights() {
  if [[ -z "$HF_TOKEN" ]]; then
    log "ERROR: AUTO_CONVERT 需要 HF_TOKEN 下载 $HF_REPO_ID"
    exit 1
  fi
  mkdir -p "$HF_LOCAL_DIR"
  log "HF weights download: $HF_REPO_ID -> $HF_LOCAL_DIR"
  local rev_args=()
  if [[ -n "$HF_DOWNLOAD_REVISION" ]]; then
    rev_args=(--revision "$HF_DOWNLOAD_REVISION")
  fi
  # shellcheck disable=SC2046
  if command -v hf >/dev/null 2>&1; then
    hf download "$HF_REPO_ID" --local-dir "$HF_LOCAL_DIR" $(hf_auth_args) "${rev_args[@]}"
  elif command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$HF_REPO_ID" --local-dir "$HF_LOCAL_DIR" $(hf_auth_args) "${rev_args[@]}"
  else
    export HF_REPO_ID HF_LOCAL_DIR HF_DOWNLOAD_REVISION
    python3 - <<'PY'
import os
from huggingface_hub import snapshot_download
rev = os.environ.get("HF_DOWNLOAD_REVISION") or None
snapshot_download(
    repo_id=os.environ["HF_REPO_ID"],
    local_dir=os.environ["HF_LOCAL_DIR"],
    token=os.environ.get("HF_TOKEN") or None,
    revision=rev,
)
PY
  fi
  touch "${HF_LOCAL_DIR}/.hf_download_ok"
  log "HF weights download done"
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

  local free_kb
  free_kb="$(df -Pk "$VOLUME_ROOT" | awk 'NR==2{print $4}')"
  # Q8 转换 + 量化通常需要额外十几 GB；不足则直接失败并提示改拉 GGUF
  if [[ -n "$free_kb" && "$free_kb" -lt 25000000 ]]; then
    log "ERROR: 挂载盘剩余约 $((free_kb/1024/1024))GB，全量转换风险高（建议≥25GB 空闲）"
    log "  请改用现成 GGUF：HF_GGUF_REPO=unsloth/Qwen3.5-9B-GGUF HF_GGUF_FILE=Qwen3.5-9B-Q4_K_M.gguf AUTO_CONVERT=0"
    exit 1
  fi

  mkdir -p "$(dirname "$MODEL_PATH")"
  local tmp_gguf
  tmp_gguf="$(dirname "$MODEL_PATH")/Qwen3.5-9B.${CONVERT_OUTTYPE}.gguf"

  if [[ ! -f "$tmp_gguf" ]]; then
    log "Converting HF -> GGUF ($CONVERT_OUTTYPE): $tmp_gguf"
    log "  TMPDIR=$TMPDIR (on volume)"
    local convert_dir
    convert_dir="$(dirname "$CONVERT_SCRIPT")"
    (
      cd "$convert_dir"
      python3 "$(basename "$CONVERT_SCRIPT")" "$HF_LOCAL_DIR" \
        --outfile "$tmp_gguf" \
        --outtype "$CONVERT_OUTTYPE" \
        --use-temp-file
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
if [[ -f "$MODEL_PATH" ]]; then
  log "Model present: $MODEL_PATH"
  exit 0
fi

if [[ -n "$MODEL_URL" ]]; then
  download_direct_url
fi

if [[ ! -f "$MODEL_PATH" && -n "$HF_GGUF_REPO" ]]; then
  download_gguf_from_hf || log "WARN: GGUF download failed, will try convert if enabled"
fi

if [[ ! -f "$MODEL_PATH" && "$AUTO_CONVERT" == "1" ]]; then
  if need_hf_weights; then
    download_hf_weights
  elif [[ -n "$HF_REPO_ID" ]]; then
    log "HF weights cache hit: $HF_LOCAL_DIR"
  fi
  if [[ -n "$HF_REPO_ID" ]]; then
    convert_and_quantize
  fi
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  log "ERROR: model missing: $MODEL_PATH"
  log "  推荐: HF_TOKEN + HF_GGUF_REPO=unsloth/Qwen3.5-9B-GGUF HF_GGUF_FILE=Qwen3.5-9B-Q4_K_M.gguf"
  log "  或设 MODEL_URL=直链；仅在有充足磁盘时 AUTO_CONVERT=1"
  exit 1
fi
