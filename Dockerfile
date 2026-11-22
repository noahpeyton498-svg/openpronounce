# Self-contained image for WeChat CloudRun Git deployment.
# Copy this file, cloudrun_patch_server.py and .dockerignore to the root of a
# deployment repository or a fork. The application source is cloned below, so
# the build context does not need to contain the upstream source tree.
#
# For a reproducible release, replace "main" with the full upstream commit SHA.
ARG OPENPRONOUNCE_REF=main

# Base image can be pointed at a domestic mirror when the local machine cannot
# reach Docker Hub, e.g.
#   --build-arg PYTHON_IMAGE=docker.m.daocloud.io/library/python:3.12-slim
ARG PYTHON_IMAGE=python:3.12-slim

FROM ${PYTHON_IMAGE}

ARG OPENPRONOUNCE_REF

# CloudRun builders run in mainland China. All download sources default to
# domestic mirrors; override any of them with --build-arg when a mirror is
# missing a package. TORCH_INDEX must stay on the CPU wheel index: the PyPI
# mirrors only carry the CUDA build, which is several GB larger.
ARG DEBIAN_MIRROR=mirrors.cloud.tencent.com
ARG PIP_INDEX=https://mirrors.cloud.tencent.com/pypi/simple
ARG PIP_TRUSTED=mirrors.cloud.tencent.com
ARG TORCH_INDEX=https://download.pytorch.org/whl/cpu
ARG HF_ENDPOINT_URL=https://hf-mirror.com
ARG OPENPRONOUNCE_REPO=https://github.com/Halleck45/OpenPronounce.git

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DEFAULT_TIMEOUT=120 \
    PIP_INDEX_URL=${PIP_INDEX} \
    PIP_TRUSTED_HOST=${PIP_TRUSTED} \
    HF_HOME=/models \
    HF_ENDPOINT=${HF_ENDPOINT_URL} \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    HF_HUB_DOWNLOAD_TIMEOUT=120 \
    HF_HUB_DISABLE_XET=1 \
    PORT=8000 \
    OPENPRONOUNCE_DEVICE=cpu \
    OPENPRONOUNCE_TTS=piper \
    OPENPRONOUNCE_TTS_VOICE=en_US-lessac-medium \
    OPENPRONOUNCE_CACHE_DIR=/tmp/openpronounce-cache

# Every long step prints a timestamp so the build log keeps streaming: some
# builders kill a job that produces no output for several minutes.
RUN echo "[build] apt start $(date -u +%H:%M:%S)" \
    && if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g; s|security.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    else \
        sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g; s|security.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        espeak-ng \
        ffmpeg \
        git \
        libsndfile1 \
    && rm -rf /var/lib/apt/lists/* \
    && echo "[build] apt done $(date -u +%H:%M:%S)"

RUN echo "[build] clone start $(date -u +%H:%M:%S)" \
    && git clone "$OPENPRONOUNCE_REPO" /app \
    && git -C /app checkout --detach "$OPENPRONOUNCE_REF" \
    && rm -rf /app/.git \
    && echo "[build] clone done $(date -u +%H:%M:%S)"

WORKDIR /app

RUN echo "[build] torch start $(date -u +%H:%M:%S)" \
    && pip install --upgrade pip --retries 5 --timeout 120 \
    && pip install torch --index-url "$TORCH_INDEX" --retries 5 --timeout 120 \
    && echo "[build] app deps start $(date -u +%H:%M:%S)" \
    && pip install --retries 5 --timeout 120 ".[app,tts-piper]" \
    && pip install --retries 5 --timeout 120 hf_transfer \
    && echo "[build] deps done $(date -u +%H:%M:%S)"

# Remove the converted per-request WAV after analysis. Build fails loudly if
# the upstream route no longer matches, instead of silently keeping user audio.
COPY cloudrun_patch_server.py /tmp/cloudrun_patch_server.py
RUN python /tmp/cloudrun_patch_server.py /app/server.py \
    && rm /tmp/cloudrun_patch_server.py

# Bake both Wav2Vec2 checkpoints and the Piper reference voice into the image.
# Split per model so the build log advances and a single download can be retried.
RUN echo "[build] speech models start $(date -u +%H:%M:%S)" \
    && python -c "from openpronounce.speech import _load_models; _load_models()" \
    && echo "[build] speech models done $(date -u +%H:%M:%S)"

# 下载可能偶发挂起（单个连接无进度），用 timeout 兜底并自动重试，避免卡死到任务超时
RUN echo "[build] phones model start $(date -u +%H:%M:%S)" \
    && ok=0 \
    && for i in 1 2 3; do \
         if timeout 240 python -c "from openpronounce.phones import _load_model; _load_model()"; then ok=1; break; fi; \
         echo "[build] phones model retry $i $(date -u +%H:%M:%S)"; \
       done \
    && if [ "$ok" != "1" ]; then echo "[build] phones model FAILED"; exit 1; fi \
    && echo "[build] phones model done $(date -u +%H:%M:%S)"

RUN echo "[build] piper voice start $(date -u +%H:%M:%S)" \
    && ok=0 \
    && for i in 1 2 3; do \
         if timeout 240 python -c "from openpronounce.tts import _piper_voice_files; _piper_voice_files('en_US-lessac-medium')"; then ok=1; break; fi; \
         echo "[build] piper voice retry $i $(date -u +%H:%M:%S)"; \
       done \
    && if [ "$ok" != "1" ]; then echo "[build] piper voice FAILED"; exit 1; fi \
    && echo "[build] piper voice done $(date -u +%H:%M:%S)"

# Runtime must not download models. This does not block gTTS, so Piper is
# selected above and its voice is already present in the image.
ENV HF_HUB_OFFLINE=1

EXPOSE 8000

CMD ["sh", "-c", "uvicorn server:app --host 0.0.0.0 --port ${PORT}"]
