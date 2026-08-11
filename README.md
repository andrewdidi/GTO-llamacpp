# GTO-llamacpp

在 **RunPod Pod** 上用 [llama.cpp](https://github.com/ggerganov/llama.cpp) 的 `llama-server` 提供 **OpenAI 兼容** HTTP API（默认 **8000** 端口），带 **API Key** 鉴权。

## 一键部署镜像（推荐）

`main` 分支推送后，GitHub Actions 自动构建并推送到 GHCR：

```text
ghcr.io/andrewdidi/gto-llamacpp:latest
```

- Actions：仓库 → **Actions** → **Build and push Docker image**（也可手动 **Run workflow**）
- 首次构建约需较长时间（编译 CUDA `llama-server`）
- 若 RunPod 拉镜像 401：到 GitHub → **Packages** → `gto-llamacpp` → Package settings → **Change visibility → Public**

### RunPod Pod 填这些即可

1. **Pods → Deploy**（不要用 Serverless）
2. Container Image：`ghcr.io/andrewdidi/gto-llamacpp:latest`
3. HTTP Port：`8000`
4. Volume 挂载：`/models`（磁盘建议 ≥ 80GB）
5. 环境变量：

```text
API_KEY=你的调用密钥
HF_TOKEN=你的HF令牌
HF_REPO_ID=Qwen/Qwen3.5-9B
HF_LOCAL_DIR=/models/hf/Qwen3.5-9B
MODEL_PATH=/models/gguf/Qwen3.5-9B-Q4_K_M.gguf
MODEL_ALIAS=Qwen3.5-9B
```

6. 访问：`https://<POD_ID>-8000.proxy.runpod.net/v1/chat/completions`

## 快速能力

| 项 | 值 |
|---|---|
| 协议 | `POST /v1/chat/completions`、`GET /v1/models` |
| 端口 | `8000`（RunPod HTTP 代理：`https://<id>-8000.proxy.runpod.net`） |
| 鉴权 | `Authorization: Bearer <API_KEY>` |
| 镜像 | `ghcr.io/andrewdidi/gto-llamacpp:latest` |
| 配置 | 环境变量或 `config/config.env`（本地，勿提交密钥） |

## 目录

```
GTO-llamacpp/
├── Dockerfile              # CUDA 构建 llama-server
├── start.sh                # 读配置 → 启服务
├── config/
│   ├── config.env.example  # 模板（可提交）
│   └── config.env          # 含 API_KEY（勿提交）
├── scripts/
│   ├── smoke_test.sh       # 探测 /v1
│   └── download_model.sh   # 拉 GGUF
└── models/                 # 本地模型目录（gitignore）
```

## 配置

复制并编辑：

```bash
cp config/config.env.example config/config.env
# 修改 API_KEY、MODEL_PATH / MODEL_URL
```

重要变量：

- `API_KEY` — 客户端 Bearer Token（必填，勿用示例占位）
- `HF_TOKEN` — Hugging Face Token（启动下载官方权重）
- `HF_REPO_ID` — 默认 `Qwen/Qwen3.5-9B`
- `HF_LOCAL_DIR` — 默认 `/models/hf/Qwen3.5-9B`（建议挂 Network Volume）
- `MODEL_PATH` — 转换后的 GGUF，默认 `/models/gguf/Qwen3.5-9B-Q4_K_M.gguf`
- `AUTO_CONVERT` — `1` 时：HF 目录 → GGUF（`CONVERT_OUTTYPE`）→ 量化（`QUANTIZE_TYPE`）
- `HOST` / `PORT` — 默认 `0.0.0.0` / `8000`
- `MODEL_ALIAS` — `/v1/models` 与请求里的 `model` 名
- `N_GPU_LAYERS` / `CTX_SIZE` — GPU 层数与上下文

官方仓是 **Safetensors**，`llama-server` 需要 **GGUF**。首次启动流程：

1. `hf download` → `HF_LOCAL_DIR`
2. `convert_hf_to_gguf.py` → 临时 GGUF
3. `llama-quantize` → `MODEL_PATH`
4. 再监听 8000

Volume 请预留空间（HF 权重约十几 GB + GGUF）。再次启动若文件已在，会跳过下载/转换。

## 本地 / 镜像构建

```bash
cd Backend/GTO-llamacpp
docker build -t gto-llamacpp:cuda .
# CPU（无 GPU 机器试跑）:
# docker build --build-arg GGML_CUDA=OFF -t gto-llamacpp:cpu .
```

运行（挂载模型）：

```bash
docker run --gpus all -p 8000:8000 \
  -v "$PWD/models:/models" \
  -v "$PWD/config/config.env:/app/config/config.env:ro" \
  -e MODEL_PATH=/models/your-model.gguf \
  gto-llamacpp:cuda
```

## RunPod 部署（用预构建镜像）

见上文「一键部署镜像」。不要走 Serverless「Import Git Repository」。

### 环境变量参考

| Env | 说明 |
|-----|------|
| `API_KEY` | 与客户端一致 |
| `HF_TOKEN` | Hugging Face Token |
| `HF_REPO_ID` | 默认 `Qwen/Qwen3.5-9B` |
| `HF_LOCAL_DIR` | 默认 `/models/hf/Qwen3.5-9B` |
| `MODEL_PATH` | 默认 `/models/gguf/Qwen3.5-9B-Q4_K_M.gguf` |
| `MODEL_ALIAS` | 请求用的 model 名 |
| `N_GPU_LAYERS` | 默认 `999` |
| `CTX_SIZE` | 默认 `8192` |

启动后探测：

```bash
./scripts/smoke_test.sh "https://<POD_ID>-8000.proxy.runpod.net" "sk-gto-..."
```

### 调用示例

```bash
curl -sS "https://<POD_ID>-8000.proxy.runpod.net/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local-gguf",
    "messages": [{"role": "user", "content": "1+1=?"}],
    "max_tokens": 64,
    "temperature": 0
  }'
```

桌面 / `fastapi-GTO-dev` 侧把 OpenAI Base URL 指到该代理的 `/v1`，Header 带同一 `API_KEY` 即可。

### 常见问题

- **502 Waiting for service**：容器未监听 8000，或模型仍在下载/加载。看 Pod logs 中 `[gto-llamacpp]`。
- **401**：API Key 不一致。
- **404 空响应**：代理开了但进程没起来（检查 ENTRYPOINT / 模型路径）。
- **首启很慢**：Dockerfile 会编译 `llama-server`；建议构建一次推到自己的镜像仓库，Pod 用预构建镜像更快。

## 与 Serverless Endpoint 的区别

本项目面向 **Dedicated Pod + HTTP 8000**，不是 RunPod Serverless worker。Serverless 请继续用 `fastapi-GTO-dev` 的 Endpoint 配置。

## 安全

- `config/config.env` 已在 `.gitignore`，勿把真实 Key 提交到公开 Git。
- 公网代理务必使用强 `API_KEY`；泄露后立即轮换。
