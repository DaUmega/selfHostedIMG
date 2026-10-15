# syntax=docker/dockerfile:1
# selfHostedIMG: offline image-generation appliance.
# sd-server (stable-diffusion.cpp) + web UI + Tor + SSH, all in one box.
# Universal build: BACKEND=vulkan (default; Alpine; AMD/Intel/NVIDIA via /dev/dri),
# BACKEND=cuda (NVIDIA; Ubuntu base), BACKEND=cpu (no GPU at all).
#   docker build --build-arg BACKEND=cuda -t selfhosted-img .
ARG BACKEND=vulkan
ARG SD_CPP_REF=master
ARG CUDA_ARCH="89;90;120"

# Stage 1: Go file server (static UI + /v1 reverse proxy to sd-server).
FROM golang:alpine AS gobuild
WORKDIR /src
COPY go.mod serve.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/serve serve.go

# Stage 2: build sd-server from source (pinned ref).
FROM alpine:3.21 AS sdbuild-vulkan
FROM alpine:3.21 AS sdbuild-cpu
FROM nvidia/cuda:12.8.1-devel-ubuntu24.04 AS sdbuild-cuda
FROM sdbuild-${BACKEND} AS sdbuild
ARG BACKEND
ARG SD_CPP_REF
ARG CUDA_ARCH
RUN set -e; \
    if [ "$BACKEND" = "cuda" ]; then \
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
            git cmake build-essential && rm -rf /var/lib/apt/lists/*; \
        SD_FLAGS="-DSD_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}"; \
    else \
        apk add --no-cache git cmake build-base; \
        SD_FLAGS=""; \
        if [ "$BACKEND" = "vulkan" ]; then apk add --no-cache vulkan-headers; SD_FLAGS="-DSD_VULKAN=ON"; fi; \
    fi; \
    git clone --recursive https://github.com/leejet/stable-diffusion.cpp /src/sd && \
    cd /src/sd && git checkout -q "$SD_CPP_REF" && \
    cmake -B build -DCMAKE_BUILD_TYPE=Release $SD_FLAGS && \
    cmake --build build -j"$(nproc)"; \
    BIN="$(find build -maxdepth 4 -type f -name '*server*' -executable | head -1)"; \
    [ -n "$BIN" ] || { echo "ERROR: no server binary built"; exit 1; }; \
    mkdir -p /out && cp "$BIN" /out/sd-server && echo "sd-server built: $BIN"

# Stage 3: the appliance.
FROM alpine:3.21 AS final-vulkan
FROM alpine:3.21 AS final-cpu
FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04 AS final-cuda
FROM final-${BACKEND} AS final
ARG BACKEND
RUN set -e; \
    if [ "$BACKEND" = "cuda" ]; then \
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
            tor openssh-server procps curl ca-certificates libgomp1 && rm -rf /var/lib/apt/lists/*; \
    else \
        apk add --no-cache tor openssh-server procps curl ca-certificates \
            libstdc++ libgomp shadow; \
        if [ "$BACKEND" = "vulkan" ]; then apk add --no-cache vulkan-loader; fi; \
    fi; \
    mkdir -p /var/run/sshd /id /models /app && \
    useradd -m -s /bin/sh ai && usermod -p '*' ai
# '*' = no password login possible, but the account is NOT locked.
# useradd alone leaves it locked ('!' in shadow) and sshd rejects ALL auth.

WORKDIR /app
COPY --from=gobuild /out/serve /app/serve
COPY --from=sdbuild /out/sd-server /app/sd-server
COPY entrypoint.sh index.html sshd_config ./
COPY load-model /usr/local/bin/load-model
RUN chmod +x entrypoint.sh /app/serve /app/sd-server /usr/local/bin/load-model && \
    chown ai:ai /models

# 7860 = sd-server API (OpenAI-compatible) | 8090 = web UI (both localhost-bound)
EXPOSE 7860 8090
ENTRYPOINT ["/app/entrypoint.sh"]
