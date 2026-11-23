#!/bin/sh
# CloudRun 容器入口（瘦身版）：模型不打入镜像，运行时后台预热下载到 HF_HOME=/models。
# 服务立即监听端口（上游 server.py 无启动钩子、模型惰性加载，import 不会触发下载），
# 预热完成前发音评估接口可能失败，gTTS/phonemes 等不依赖模型的功能不受影响。
# 单个下载挂起用 timeout 兜底并自动重试（与构建期同样的保护）。
set -u
PORT="${PORT:-8000}"

log() { echo "[start] $* $(date -u +%H:%M:%S)"; }

warmup_step() {   # $1=名称 $2=单次超时秒 $3=python 加载语句
  name="$1"; tmo="$2"; expr="$3"
  for i in 1 2 3; do
    if timeout "$tmo" python -c "$expr"; then
      log "$name ready"
      return 0
    fi
    log "$name retry $i"
  done
  log "$name FAILED (server keeps running; requests will retry the download)"
  return 1
}

log "models warmup start"
(
  warmup_step "speech models" 900 "from openpronounce.speech import _load_models; _load_models()" || exit 1
  warmup_step "phones model" 240 "from openpronounce.phones import _load_model; _load_model()" || exit 1
  warmup_step "piper voice" 240 "from openpronounce.tts import _piper_voice_files; _piper_voice_files('en_US-lessac-medium')" || exit 1
  log "models warmup done"
) &

log "uvicorn starting on port $PORT"
exec uvicorn server:app --host 0.0.0.0 --port "$PORT"
