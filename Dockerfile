# GTO-llamacpp: llama.cpp OpenAI-compatible server for RunPod Pods
# Build (GPU): docker build -t gto-llamacpp:cuda .
# CPU-only fallback: docker build --build-arg GGML_CUDA=OFF -t gto-llamacpp:cpu .

ARG CUDA_IMAGE=nvidia/cuda:12.4.1-devel-ubuntu22.04
ARG CUDA_RUNTIME=nvidia/cuda:12.4.1-runtime-ubuntu22.04
ARG GGML_CUDA=ON

FROM ${CUDA_IMAGE} AS build
ARG GGML_CUDA
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git curl ca-certificates libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/ggerganov/llama.cpp.git .
# CUDA build when GGML_CUDA=ON; otherwise CPU
RUN if [ "$GGML_CUDA" = "ON" ]; then \
      cmake -B build -DGGML_CUDA=ON -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release; \
    else \
      cmake -B build -DGGML_CUDA=OFF -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release; \
    fi \
 && cmake --build build --config Release -j"$(nproc)" --target llama-server llama-quantize

FROM ${CUDA_RUNTIME} AS runtime
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates libgomp1 libcurl4 \
      python3 python3-pip python3-venv git \
    && rm -rf /var/lib/apt/lists/*
# HF download + HF→GGUF convert deps（体积较大，仅运行时需要）
RUN pip3 install --no-cache-dir \
      "huggingface_hub[cli,hf_transfer]" \
      "hf_transfer" \
      "transformers>=4.51.0" \
      "torch" \
      "sentencepiece" \
      "numpy" \
      "protobuf" \
      "gguf" \
      "tqdm" \
      "safetensors"
COPY --from=build /src/build/bin/llama-server /usr/local/bin/llama-server
COPY --from=build /src/build/bin/llama-quantize /usr/local/bin/llama-quantize
COPY --from=build /src/convert_hf_to_gguf.py /opt/llama.cpp/convert_hf_to_gguf.py
WORKDIR /app
COPY start.sh /app/start.sh
COPY scripts /app/scripts
COPY config/config.env.example /app/config/config.env.example
RUN chmod +x /app/start.sh /app/scripts/*.sh \
 && mkdir -p /app/config /models/hf /models/gguf \
 && if [ ! -f /app/config/config.env ]; then cp /app/config/config.env.example /app/config/config.env; fi
ENV HOST=0.0.0.0 \
    PORT=8000 \
    HF_REPO_ID=Qwen/Qwen3.5-9B \
    HF_LOCAL_DIR=/models/hf/Qwen3.5-9B \
    MODEL_PATH=/models/gguf/Qwen3.5-9B-Q4_K_M.gguf \
    MODEL_ALIAS=Qwen3.5-9B \
    AUTO_CONVERT=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    LLAMA_SERVER_BIN=/usr/local/bin/llama-server \
    CONVERT_SCRIPT=/opt/llama.cpp/convert_hf_to_gguf.py \
    LLAMA_QUANTIZE_BIN=/usr/local/bin/llama-quantize
EXPOSE 8000
# RunPod HTTP proxy targets container port 8000
ENTRYPOINT ["/app/start.sh"]
