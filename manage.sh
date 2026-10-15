#!/usr/bin/env bash
# selfHostedIMG container manager: sd-server + web UI, all in docker.
# This script only manages the container and the Tor+SSH identity. Everything
# else (model downloads, load-model, UI toggle) happens inside, over ssh.
# Usage: ./manage.sh <command> [args]
set -euo pipefail

IMAGE="selfhosted-img"
CONTAINER="selfhosted-img"
MODELVOLUME="img-models"          # persists /models across rebuilds
IDVOLUME="img-id"                # persists tor + ssh host keys (stable .onion)
UI_PORT="${UI_PORT:-8090}"
API_PORT="${API_PORT:-7860}"

# GPU backend for the image. "auto" (default) detects at build time:
# NVIDIA runtime -> cuda, /dev/dri -> vulkan, otherwise cpu.
# Set explicitly to force it: vulkan | cuda | cpu.
BACKEND="${BACKEND:-auto}"

# GPU flag - auto-detected; override with GPU=0 ./manage.sh start
GPU="${GPU:-auto}"

# Frontend: 1 = serve web UI on :8090, 0 = API only (curl samples live in the README)
FRONTEND="${FRONTEND:-1}"

# Bind address for published ports. 127.0.0.1 = only this machine (and your
# SSH port-forwards) can reach the API/UI. Set to 0.0.0.0 for LAN access.
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"

# ── helpers ───────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n'  "$*"; }
bold()  { printf '\033[1m%s\033[0m\n'  "$*"; }

die() { red "error: $*"; exit 1; }

require() { command -v "$1" &>/dev/null || die "'$1' not found in PATH"; }

is_running() { docker ps -q -f name="^${CONTAINER}$" 2>/dev/null | grep -q .; }

read_onion() {
    # Print the .onion address, or nothing if the hidden service isn't up yet.
    docker exec "$CONTAINER" cat /id/tor/hidden/hostname 2>/dev/null || true
}

gpu_flags() {
    # $1 = resolved backend. cuda wants --gpus all, vulkan wants /dev/dri.
    local be="${1:-vulkan}"
    if [[ "$GPU" == "0" || "$be" == "cpu" ]]; then
        echo ""
    elif [[ "$be" == "cuda" ]] || docker info 2>/dev/null | grep -q "nvidia"; then
        echo "--gpus all"
    elif [[ -e /dev/dri ]]; then
        echo "--device /dev/dri:/dev/dri"
    else
        echo ""
    fi
}

detect_backend() {
    # Echo the effective backend: explicit BACKEND wins, else auto-detect.
    case "$BACKEND" in
        vulkan|cuda|cpu) echo "$BACKEND"; return ;;
        auto) ;;
        *) die "BACKEND must be one of: auto, vulkan, cuda, cpu (got '$BACKEND')" ;;
    esac
    if docker info 2>/dev/null | grep -q "nvidia"; then
        echo "cuda"
        return
    fi
    # NVIDIA GPU exists on the host but docker can't see it (no
    # nvidia-container-toolkit): say so on stderr, stdout stays clean
    # for the $(detect_backend) capture.
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        echo "note: NVIDIA GPU found on host but not visible to docker." >&2
        echo "install nvidia-container-toolkit for the cuda backend; falling back." >&2
    fi
    if [[ -e /dev/dri ]]; then
        echo "vulkan"
    else
        echo "cpu"
    fi
}

# ── container lifecycle ───────────────────────────────────────────────────

cmd_build() {
    local be
    be="$(detect_backend)"
    bold "Building image: $IMAGE (backend: $be)"
    docker build --build-arg BACKEND="$be" --label "selfhosted-img.backend=$be" -t "$IMAGE" .
    green "Done."
}

cmd_start() {
    require docker
    if is_running; then
        green "Already running."
        [[ "$FRONTEND" == "1" ]] && dim "  UI  → http://localhost:${UI_PORT}"
        dim "  API → http://localhost:${API_PORT}"
        return
    fi

    # Build if image doesn't exist
    if ! docker image inspect "$IMAGE" &>/dev/null; then
        cmd_build
    fi

    # Warn if the on-disk image was built for a different backend than
    # the one detected now (e.g. moved to another machine).
    local be img_be
    be="$(detect_backend)"
    img_be="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "selfhosted-img.backend"}}' 2>/dev/null)"
    if [[ -n "$img_be" && "$img_be" != "$be" ]]; then
        dim "Note: image backend is '$img_be' but '$be' was selected."
        dim "Run BACKEND=$be ./manage.sh rebuild to switch."
    fi

    local -a ports=(-p "${BIND_ADDR}:${API_PORT}:7860" -p "${BIND_ADDR}:${UI_PORT}:8090")

    bold "Starting container: $CONTAINER"
    # shellcheck disable=SC2086
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        "${ports[@]}" \
        -v "${MODELVOLUME}:/models" \
        -v "${IDVOLUME}:/id" \
        -e FRONTEND="$FRONTEND" \
        -e UI_PORT="$UI_PORT" \
        $(gpu_flags "$be") \
        "$IMAGE"

    bold "Container logs (live - waiting for sshd)..."
    dim  "────────────────────────────────────────"

    # Stream container logs so you can see exactly what is happening
    docker logs -f "$CONTAINER" &
    LOGS_PID=$!

    # Poll until the Tor hidden service reports its .onion address
    local tries=0 onion=""
    while [[ $tries -lt 60 ]]; do
        onion="$(read_onion)"
        [[ -n "$onion" ]] && break
        sleep 1
        tries=$((tries + 1))
    done

    kill $LOGS_PID 2>/dev/null || true
    wait $LOGS_PID 2>/dev/null || true
    dim  "────────────────────────────────────────"

    if [[ -z "$onion" ]]; then
        red "Hidden service did not come up after 60s - run: ./manage.sh logs"
        exit 1
    fi

    green "Ready."
    dim "  Onion → $onion  (ssh ai@$onion via tor)"
    if [[ "$FRONTEND" == "1" ]]; then
        dim "  UI  → http://localhost:${UI_PORT}"
    else
        dim "  Web UI off - start it inside any time: ssh in, then: UI_PORT=${UI_PORT} /app/serve &"
    fi
    dim "  Next:"
    dim "    1. ./manage.sh auth \"ssh-ed25519 AAAA...\"   (one-time: authorize your key)"
    dim "    2. Get model files (README Suggested models), then: ./manage.sh import <files...>"
    dim "    3. ssh in, then: load-model <file.gguf> [--llm ... --vae ...]"
}

cmd_stop() {
    bold "Stopping $CONTAINER"
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true
    green "Stopped."
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_rebuild() {
    cmd_stop
    cmd_build
    cmd_start
}

cmd_logs() {
    docker logs -f "$CONTAINER"
}

cmd_shell() {
    docker exec -it "$CONTAINER" /bin/sh
}

cmd_status() {
    if is_running; then
        green "Running"
        docker ps --filter "name=^${CONTAINER}$" --format "  id={{.ID}}  uptime={{.RunningFor}}  ports={{.Ports}}"
    else
        dim "Not running"
    fi
    echo
    dim "Model volume: $MODELVOLUME"
    docker volume inspect "$MODELVOLUME" --format "  mountpoint: {{.Mountpoint}}" 2>/dev/null || dim "  (volume not yet created)"
    if is_running; then
        echo
        dim "sd-server:"
        docker exec "$CONTAINER" sh -c 'pgrep -x sd-server >/dev/null && echo "  running ($(cat /id/sd-model.args 2>/dev/null))" || echo "  not running (ssh in and: load-model <file.gguf>)"'
    fi
}

# ── tor+ssh identity ──────────────────────────────────────────────────────

cmd_auth() {
    # Authorize an SSH key for the container's ai user.
    # Usage: ./manage.sh auth "ssh-ed25519 AAAA..." [--restricted]
    # Default: full shell. --restricted: forwarding-only (web UI), no shell.
    local restricted=0 key=""
    for a in "$@"; do
        case "$a" in
            --restricted) restricted=1 ;;
            *) key="$a" ;;
        esac
    done
    [[ -n "$key" ]] || die 'Usage: ./manage.sh auth "ssh-ed25519 AAAA..." [--restricted]'
    case "$key" in
        ssh-ed25519*|ssh-rsa*|ecdsa-sha2-*) ;;
        *) die "That doesn't look like an SSH public key." ;;
    esac
    is_running || die "Container not running. Run: ./manage.sh start"
    [ "$restricted" -eq 1 ] && key="restrict,permitopen=\"localhost:${UI_PORT}\",no-pty $key"
    printf '%s\n' "$key" | docker exec -i "$CONTAINER" sh -c '
        k=$(cat)
        f=/home/ai/.ssh/authorized_keys
        grep -qxF "$k" "$f" 2>/dev/null || echo "$k" >> "$f"
        chown ai:ai "$f"; chmod 600 "$f"
    ' || die "Failed to authorize key."
    if [ "$restricted" -eq 1 ]; then green "Key authorized (forwarding-only: web UI, no shell).";
    else green "Key authorized (full shell)."; fi
}

cmd_onion() {
    is_running || die "Container not running."
    local onion
    onion="$(read_onion)"
    [ -n "$onion" ] || die "Hidden service not ready yet - check ./manage.sh logs"
    echo "$onion"
}

cmd_import() {
    # Usage: ./manage.sh import <file>... -- copy model files from the host into /models
    [[ $# -gt 0 ]] || die 'Usage: ./manage.sh import <file>...'
    is_running || die "Container not running. Run: ./manage.sh start"
    local f
    for f in "$@"; do
        [[ -f $f ]] || die "not found: $f"
        echo "Copying $(basename "$f") -> /models"
        docker cp "$f" "$CONTAINER:/models/"
    done
    docker exec -u root "$CONTAINER" chown -R ai:ai /models >/dev/null
    green "Done. Inside, run: load-model $(basename "$1")"
}

cmd_share() {
    # Print the copy-paste one-liner for loved ones (web UI only, no shell).
    # Their key must be authorized first: ./manage.sh auth "<pubkey>" --restricted
    is_running || die "Container not running. Run: ./manage.sh start"
    local onion
    onion="$(read_onion)"
    [ -n "$onion" ] || die "Hidden service not ready yet - check ./manage.sh logs"

    bold "Send this to your loved ones (web UI only - no shell access):"
    echo
    echo "  ssh -o \"ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p\" -o ServerAliveInterval=30 -L ${UI_PORT}:localhost:${UI_PORT} -N ai@${onion}"
    echo
    dim "  1. They need Tor running locally (Tor Browser also works: use -x 127.0.0.1:9150)"
    dim "  2. Their key must be added first: ./manage.sh auth \"<their-pubkey>\" --restricted"
    dim "  3. They open http://localhost:${UI_PORT} - first connect takes ~30s (Tor circuit)"
    if docker exec "$CONTAINER" pgrep -f "/app/serve" >/dev/null 2>&1; then
        dim "  Web UI is ON."
    else
        echo
        red "  Web UI is currently OFF - ssh in and run: UI_PORT=${UI_PORT} /app/serve &"
    fi
}

# ── host preflight ────────────────────────────────────────────────────────

cmd_doctor() {
    # Check this machine has what it takes to run selfHostedIMG.
    bold "selfHostedIMG doctor"
    echo
    local fail=0 onion=""
    pass() { green "  [ok] $1"; }
    warn() { red "  [!!] $1"; fail=1; }
    note() { dim  "  [..] $1"; }

    if command -v docker >/dev/null 2>&1; then pass "docker installed"; else warn "docker not in PATH"; fi
    if docker info >/dev/null 2>&1; then pass "docker daemon running"; else warn "docker daemon not reachable"; fi

    local mem_gb disk_gb
    if [ -f /proc/meminfo ]; then
        mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)"
    else
        mem_gb="$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1024/1024/1024}')"
    fi
    disk_gb="$(df -k . 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')"
    if [ "${mem_gb:-0}" -ge 8 ] 2>/dev/null; then pass "memory: ${mem_gb}GB"; else warn "memory: ${mem_gb:-?}GB (want 8GB+)"; fi
    if [ "${disk_gb:-0}" -ge 20 ] 2>/dev/null; then pass "disk: ${disk_gb}GB free"; else warn "disk: ${disk_gb:-?}GB free (models are 5GB+)"; fi

    if docker info 2>/dev/null | grep -q nvidia; then
        pass "NVIDIA GPU visible to docker (cuda backend)"
    elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        warn "NVIDIA GPU on host but invisible to docker - install nvidia-container-toolkit for cuda"
    elif [[ -e /dev/dri ]]; then
        pass "/dev/dri present (vulkan backend)"
    else
        note "no GPU detected (cpu backend)"
    fi

    onion="$(read_onion)"
    if [ -n "$onion" ]; then
        pass "Tor hidden service: $onion"
    else
        note "no Tor hidden service (container not running or still starting)"
    fi

    echo
    if [ "$fail" -eq 0 ]; then green "Ready to roll."; else dim "Fix the [!!] items above, then re-run."; fi
}

# ── volume management ─────────────────────────────────────────────────────

cmd_volume_info() {
    docker volume inspect "$MODELVOLUME" 2>/dev/null || dim "Volume '$MODELVOLUME' does not exist yet."
}

cmd_volume_clean() {
    is_running && die "Stop the container first: ./manage.sh stop"
    read -rp "Delete volume '$MODELVOLUME' and ALL downloaded models? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { dim "Aborted."; exit 0; }
    docker volume rm "$MODELVOLUME"
    green "Volume removed."
}

# ── help ──────────────────────────────────────────────────────────────────

cmd_help() {
    bold "manage.sh - selfHostedIMG (container lifecycle + tor+ssh identity)"
    echo
    echo "Container"
    echo "  start              Build (if needed) and start"
    echo "  stop               Stop and remove container"
    echo "  restart            stop + start"
    echo "  rebuild            stop + build + start"
    echo "  logs               Follow container logs"
    echo "  shell              Root shell inside (break-glass when ssh is down)"
    echo "  status             Show running state (+ loaded model)"
    echo "  import <files...>  Copy model files from host into /models"
    echo
    echo "Tor+SSH identity"
    echo "  auth \"<pubkey>\" [--restricted]  Authorize a key (restricted = UI only, no shell)"
    echo "  onion              Print the .onion address"
    echo "  share              Print the one-liner for loved ones"
    echo
    echo "Inside, over ssh (ssh ai@<onion> via tor) - this is the daily driver:"
    echo "  load-model <file.gguf> [flags]   (Re)start sd-server with a model from /models"
    echo "    e.g. load-model flux2-klein-4b-fp8.gguf --vae-tiling"
    echo "    extra flags pass straight to sd-server (--vae, --llm, --steps, ...)"
    echo "  ls /models                       What you have downloaded"
    echo "  tail -f /tmp/sd-server.log       Generation log"
    echo "  UI_PORT=${UI_PORT} /app/serve &  Start the web UI (pkill -f /app/serve to stop)"
    echo
    echo "Machine"
    echo "  doctor             Check this machine can run selfHostedIMG"
    echo
    echo "Volume (persistent model storage)"
    echo "  volume-info        Inspect the model volume"
    echo "  volume-clean       Delete the volume (wipes all models)"
    echo
    echo "Env overrides (prefix the command)"
    echo "  BACKEND=auto      auto-detect at build: NVIDIA->cuda, /dev/dri->vulkan, else cpu"
    echo "                    force one: BACKEND=vulkan|cuda|cpu"
    echo "  FRONTEND=1        0 = API only, no web UI (default: on)"
    echo "  GPU=0             disable GPU passthrough"
    echo "  UI_PORT=${UI_PORT}  API_PORT=${API_PORT}"
    echo "  BIND_ADDR=127.0.0.1   bind published ports (0.0.0.0 = LAN)"
    echo
    echo "Get rolling:"
    echo "  ./manage.sh start"
    echo "  ./manage.sh auth \"ssh-ed25519 AAAA...\"   # your key"
    echo "  ./manage.sh onion                        # prints the .onion address"
    echo "  ssh -o \"ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p\" ai@\$(./manage.sh onion)"
    echo "  # inside:  curl -L -o /models/flux2-klein-4b-fp8.gguf <url>"
    echo "  # inside:  load-model flux2-klein-4b-fp8.gguf --vae-tiling"
}

# ── dispatch ──────────────────────────────────────────────────────────────
CMD="${1:-help}"
shift || true

case "$CMD" in
    build)        cmd_build        ;;
    start)        cmd_start        ;;
    stop)         cmd_stop         ;;
    restart)      cmd_restart      ;;
    rebuild)      cmd_rebuild      ;;
    logs)         cmd_logs         ;;
    shell)        cmd_shell        ;;
    status)       cmd_status       ;;
    auth)         cmd_auth   "$@"  ;;
    import)       cmd_import "$@"  ;;
    onion)        cmd_onion        ;;
    share)        cmd_share  "$@"  ;;
    doctor)       cmd_doctor       ;;
    volume-info)  cmd_volume_info  ;;
    volume-clean) cmd_volume_clean ;;
    help|--help|-h) cmd_help       ;;
    *) red "Unknown command: $CMD"; cmd_help; exit 1 ;;
esac
