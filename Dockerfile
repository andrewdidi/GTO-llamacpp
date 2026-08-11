# GTO-llamacpp: 基于官方预编译 CUDA 镜像，避免自编译链接失败 / CI 过慢
# 镜像: ghcr.io/ggml-org/llama.cpp:full-cuda
# 本地: docker build -t gto-llamacpp:cuda .

ARG LLAMA_BASE=ghcr.io/ggml-org/llama.cpp:full-cuda
FROM ${LLAMA_BASE}

USER root
ENV DEBIAN_FRONTEND=noninteractive

# full-cuda 已含 python3 + convert 依赖；补 HF 高速下载与 CLI
RUN pip install --break-system-packages --no-cache-dir \
      "huggingface_hub[cli,hf_transfer]" \
      "hf_transfer" \
 || pip3 install --break-system-packages --no-cache-dir \
      "huggingface_hub[cli,hf_transfer]" \
      "hf_transfer"

WORKDIR /gto
COPY start.sh /gto/start.sh
COPY scripts /gto/scripts
COPY config/config.env.example /gto/config/config.env.example
RUN chmod +x /gto/start.sh /gto/scripts/*.sh \
 && mkdir -p /gto/config /models/hf /models/gguf
# 不在镜像内写入 config.env（避免 sk-gto-REPLACE_ME 覆盖 RunPod 环境变量）
# 生产请用 Environment Variables：API_KEY / HF_TOKEN

# 官方 full 镜像：二进制与 .so、convert 脚本均在 /app
ENV HOST=0.0.0.0 \
    PORT=8000 \
    VOLUME_ROOT=/models \
    HF_GGUF_REPO=unsloth/Qwen3.5-9B-GGUF \
    HF_GGUF_FILE=Qwen3.5-9B-Q4_K_M.gguf \
    MODEL_PATH=/models/gguf/Qwen3.5-9B-Q4_K_M.gguf \
    MODEL_ALIAS=Qwen3.5-9B \
    AUTO_CONVERT=0 \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    LLAMA_SERVER_BIN=/app/llama-server \
    LLAMA_QUANTIZE_BIN=/app/llama-quantize \
    CONVERT_SCRIPT=/app/convert_hf_to_gguf.py \
    LD_LIBRARY_PATH=/app

EXPOSE 8000
ENTRYPOINT ["/gto/start.sh"]
