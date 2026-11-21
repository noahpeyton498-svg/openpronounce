# 微信云托管 Git 平台部署文件

本目录用于云托管控制台的「新建 Git 平台部署」。它把上游 OpenPronounce、两个 Wav2Vec2 模型和离线 Piper 英语 voice 一起构建进镜像，并在构建期清理用户录音的转换临时文件。

## 1. 为什么不能直接填上游仓库

截图中的 `https://github.com/Halleck45/OpenPronounce` 没有本项目需要的 `Dockerfile`。上游自带的 Dockerfile 不会安装 Piper，也不会清理转换后的用户音频，而且不能向公开上游仓库提交定制文件。

必须二选一：

1. **推荐：新建一个只放部署文件的仓库**，把本目录三个文件放到仓库根目录。
2. **Fork 上游**，把本目录三个文件放到 fork 根目录。

不要把整个小程序私有仓库公开来托管这三个文件。部署仓库不需要包含上游源码，Dockerfile 会在构建时按 `OPENPRONOUNCE_REF` 克隆。

## 2. 上传哪些文件

部署仓库根目录应包含：

```text
Dockerfile
cloudrun_patch_server.py
.dockerignore
```

`.dockerignore` 会把构建上下文限制为这三个文件，因此不需要复制整份 OpenPronounce 源码。

## 3. 控制台填写

| 控制台字段 | 填写值 |
| --- | --- |
| Git 仓库 | 你自己的部署仓库，或 Fork 后的仓库 |
| 分支 | `main`（或你实际使用的分支） |
| 服务名称 | `openpronounce` 或 `pronounce` |
| 访问端口 | `80` |
| 服务端口 | `8000` |
| 目标目录 | 留空（Dockerfile 在仓库根目录时） |
| Dockerfile | 选择「有」 |
| Dockerfile 路径 | `Dockerfile` |

服务端口必须是 `8000`，与容器内 Uvicorn 一致。平台会把访问端口映射到 8000。

## 4. 环境变量

镜像已经内置以下默认值：

```text
PORT=8000
HF_HOME=/models
HF_HUB_OFFLINE=1
OPENPRONOUNCE_DEVICE=cpu
OPENPRONOUNCE_TTS=piper
OPENPRONOUNCE_TTS_VOICE=en_US-lessac-medium
OPENPRONOUNCE_CACHE_DIR=/tmp/openpronounce-cache
```

控制台不要再覆盖成 `OPENPRONOUNCE_TTS=gtts`。`HF_HUB_OFFLINE=1` 只禁止 Hugging Face 联网，不会禁止 gTTS；本镜像通过 PIPER 保证参考语音离线。

如控制台强制要求填写环境变量，按上方逐项填写即可。完整变量说明见上级目录的 `env.example`。

## 5. 固定版本

默认：

```dockerfile
ARG OPENPRONOUNCE_REF=main
```

首次验证通过后，把 `main` 改成上游的完整 commit SHA，再提交构建。否则上游变化可能导致补丁匹配失败或评分结果不可复现。

构建日志应出现：

```text
audio cleanup patch applied to /app/server.py
```

如果出现：

```text
cannot apply audio cleanup patch
```

说明上游 `/pronunciation` 路由已变化。补丁会同时打印包含 `wav_file` 或 `compare_audio_with_text` 的行号，便于定位。不要删除补丁绕过，应先按新路由更新 `cloudrun_patch_server.py`。当前脚本兼容单行和多行 `return`，并可用 `# cloudrun: remove converted user audio` 判断补丁是否已经存在。

## 6. 构建注意事项

首次构建需要下载：

- CPU 版 PyTorch；
- 两个约 1.2GB 的 Wav2Vec2 checkpoint；
- Piper `en_US-lessac-medium` voice（约 60MB）。

下载总量约 3GB，成镜后体积约 4GB。在云托管「Git 平台部署」的在线构建里，日志停在 `create_build_image : creating` 十分钟后报「创建失败」，基本就是构建超时（构建器对长时间无输出/超时长的任务直接终止，日志里不会出现报错行），而不是 Dockerfile 写错。这类大镜像不适合在线构建，应改为预构建镜像后走「镜像部署」。

Dockerfile 已把下载源全部指向国内镜像，可用 `--build-arg` 覆盖：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `DEBIAN_MIRROR` | `mirrors.cloud.tencent.com` | apt 源 |
| `PIP_INDEX` / `PIP_TRUSTED` | 腾讯云 PyPI | Python 包 |
| `TORCH_INDEX` | `download.pytorch.org/whl/cpu` | 必须用 CPU 轮子，PyPI 镜像上是数 GB 的 CUDA 版 |
| `HF_ENDPOINT_URL` | `hf-mirror.com` | 模型下载 |
| `OPENPRONOUNCE_REPO` | GitHub 上游 | 网络不通时换成代理或 Gitee 镜像地址 |

Git 平台的每次构建不复用 Docker 层缓存，模型会被重新下载。生产上更稳的做法是预构建固定 tag 镜像。

## 7. 上线前检查

1. 实例规格至少 2 vCPU / 4GiB，先保持单进程。
2. 最小实例建议 1，避免首句冷启动；会产生常驻费用。
3. 健康检查路径填 `/health`；它不代表模型已完成首次业务 warmup。
4. 发布后先用一句短录音调用一次 `/pronunciation`，再做正式压测。
5. 默认不开启公网；通过云函数代理或受控内网访问。
6. 用 `verify.ps1` 做健康检查和完整测评冒烟。
7. 确认请求后容器内没有 `/tmp/openpronounce-upload-*` 残留。
8. 上线前评估 AGPL-3.0 和模型、voice 许可，详见上级 README 第 10 节。

## 8. 用 GitHub Actions 构建并推送（无需本地 Docker）

本目录已包含 `.github/workflows/build-push.yml`：在 GitHub 的 Runner 上构建 `linux/amd64` 镜像并推送到腾讯云 TCR，240 分钟超时，足够下完 3GB 依赖与模型。

1. 新建一个仓库（私有即可），把本目录的 `Dockerfile`、`cloudrun_patch_server.py`、`.dockerignore`、`.github/` 一起提交到仓库根目录。
2. 仓库 Settings → Secrets and variables → Actions：
   - Secrets：`TCR_USERNAME`（腾讯云账号 ID）、`TCR_PASSWORD`（TCR 个人版登录密码）
   - Variables：`TCR_REGISTRY`=`ccr.ccs.tencentyun.com`、`TCR_NAMESPACE`=你的命名空间、`TCR_REPO`=`openpronounce`
3. Actions → Build and push CloudRun image → Run workflow。
4. 完成后镜像标签为 `<TCR_REGISTRY>/<命名空间>/<仓库>:latest`（同时推一个 `<commit-sha>` 标签），云托管用「镜像拉取 + 无需登录」部署，服务端口填 8000。

注意：Runner 在境外，工作流里已把 `DEBIAN_MIRROR`、`PIP_INDEX`、`HF_ENDPOINT_URL` 覆盖回官方源，不要改回国内镜像，否则下载会绕地球。镜像约 4GB，跨国推送 TCR 通常 20～40 分钟。

## 9. 本地自测

安装 Docker 的机器上，在本目录执行：

```powershell
docker build -t openpronounce:cloudrun .
docker run --rm -d --name openpronounce-cloudrun -p 8000:8000 openpronounce:cloudrun
docker logs -f openpronounce-cloudrun
```

另开终端：

```powershell
Invoke-WebRequest -UseBasicParsing http://localhost:8000/health
```

停止容器：

```powershell
docker rm -f openpronounce-cloudrun
```
