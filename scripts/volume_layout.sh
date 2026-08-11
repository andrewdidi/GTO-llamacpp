#!/usr/bin/env bash
# 所有可写运行时数据尽量落在挂载盘 VOLUME_ROOT（默认 /models）
# 由 start.sh / ensure_model.sh source，不要单独执行。

VOLUME_ROOT="${VOLUME_ROOT:-/models}"

# 未显式指定时，从 VOLUME_ROOT 推导路径
: "${HF_LOCAL_DIR:=${VOLUME_ROOT}/hf/Qwen3.5-9B}"
: "${MODEL_PATH:=${VOLUME_ROOT}/gguf/Qwen3.5-9B-Q4_K_M.gguf}"
: "${CACHE_ROOT:=${VOLUME_ROOT}/cache}"
: "${LOG_DIR:=${VOLUME_ROOT}/logs}"

prepare_volume_layout() {
  mkdir -p \
    "${VOLUME_ROOT}/hf" \
    "${VOLUME_ROOT}/gguf" \
    "${CACHE_ROOT}/home" \
    "${CACHE_ROOT}/tmp" \
    "${CACHE_ROOT}/torch/inductor" \
    "${CACHE_ROOT}/torch/hub" \
    "${CACHE_ROOT}/hf/hub" \
    "${CACHE_ROOT}/hf/transformers" \
    "${CACHE_ROOT}/hf/datasets" \
    "${CACHE_ROOT}/xdg" \
    "${CACHE_ROOT}/pip" \
    "${CACHE_ROOT}/pycache" \
    "${LOG_DIR}"

  if ! touch "${VOLUME_ROOT}/.gto_write_ok" 2>/dev/null; then
    echo "[gto-llamacpp] ERROR: VOLUME_ROOT 不可写: ${VOLUME_ROOT}" >&2
    echo "[gto-llamacpp]   RunPod 请把 Network Volume 挂载到 ${VOLUME_ROOT}" >&2
    return 1
  fi
  rm -f "${VOLUME_ROOT}/.gto_write_ok"

  # 用户态与临时文件
  export HOME="${HOME:-${CACHE_ROOT}/home}"
  export TMPDIR="${CACHE_ROOT}/tmp"
  export TEMP="${TMPDIR}"
  export TMP="${TMPDIR}"

  # torch / HF / pip / python 缓存全部进挂载盘
  export TORCHINDUCTOR_CACHE_DIR="${CACHE_ROOT}/torch/inductor"
  export TORCH_HOME="${CACHE_ROOT}/torch"
  export HF_HOME="${HF_HOME:-${CACHE_ROOT}/hf}"
  export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${CACHE_ROOT}/hf/hub}"
  export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-${CACHE_ROOT}/hf/transformers}"
  export HF_DATASETS_CACHE="${HF_DATASETS_CACHE:-${CACHE_ROOT}/hf/datasets}"
  export XDG_CACHE_HOME="${CACHE_ROOT}/xdg"
  export PIP_CACHE_DIR="${CACHE_ROOT}/pip"
  export PYTHONPYCACHEPREFIX="${CACHE_ROOT}/pycache"
  export TORCHDYNAMO_DISABLE=1
  export TORCH_COMPILE_DISABLE=1

  export VOLUME_ROOT CACHE_ROOT LOG_DIR HF_LOCAL_DIR MODEL_PATH

  echo "[gto-llamacpp] volume root=${VOLUME_ROOT}"
  echo "[gto-llamacpp]   hf=${HF_LOCAL_DIR}"
  echo "[gto-llamacpp]   gguf=${MODEL_PATH}"
  echo "[gto-llamacpp]   cache=${CACHE_ROOT}  logs=${LOG_DIR}"
}
