#!/bin/sh
set -e

# ── identity: ssh host keys + tor hidden-service keys (persisted in /id) ──
# Kept in a volume so the .onion address and host keys survive rebuilds.
mkdir -p /id/ssh /id/tor/hidden /id/tor/data /run/sshd
[ -f /id/ssh/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -f /id/ssh/ssh_host_ed25519_key -N ""
[ -f /id/ssh/ssh_host_rsa_key ]     || ssh-keygen -q -t rsa -b 3072 -f /id/ssh/ssh_host_rsa_key -N ""
chmod 600 /id/ssh/ssh_host_*_key
chmod 700 /id/tor/hidden
chown ai:ai /id /models
# load-model records its choice here; keep it ai-writable even if a
# root shell ever ran load-model and left it root-owned.
touch /id/sd-model.args && chown ai:ai /id/sd-model.args
# Heal permissions every boot (runs as root): load-model must stay
# executable by ai no matter how it got into the image, model files often
# arrive via docker cp as root, and a root-run server leaves its log
# root-owned. This keeps ai fully functional with no sudo needed.
chmod +x /usr/local/bin/load-model
chown -R ai:ai /models
touch /tmp/sd-server.log && chown ai:ai /tmp/sd-server.log

# ai user: keys are added from the host via ./manage.sh auth
mkdir -p /home/ai/.ssh
touch /home/ai/.ssh/authorized_keys
chmod 700 /home/ai/.ssh
chmod 600 /home/ai/.ssh/authorized_keys
chown -R ai:ai /home/ai/.ssh

# ── tor: hidden service for ssh. Tor only makes outbound connections,
#    so the container needs no inbound ports at all.
#    DataDirectory lives on /id (not /var/lib/tor): the Debian package chowns
#    /var/lib/tor to the debian-tor user, which breaks tor when run as root.
cat > /app/torrc <<EOF
SocksPort 0
DataDirectory /id/tor/data
PidFile /run/tor.pid
HiddenServiceDir /id/tor/hidden
HiddenServicePort 22 127.0.0.1:22
EOF
echo "[entrypoint] Starting tor..."
tor -f /app/torrc --RunAsDaemon 1

echo "[entrypoint] Starting sshd..."
/usr/sbin/sshd -f /app/sshd_config

# wait for the onion address (fast; reachability takes ~30s more)
tries=0
while [ ! -f /id/tor/hidden/hostname ] && [ $tries -lt 30 ]; do
  sleep 1; tries=$((tries+1))
done
if [ -f /id/tor/hidden/hostname ]; then
  echo "[entrypoint] Onion address: $(cat /id/tor/hidden/hostname)"
else
  echo "[entrypoint] WARNING: hidden service not created"
fi

# ── sd-server: restore the last loaded model, if one was recorded ──────────
# No default model ships with the image. First boot always lands here until
# you ssh in and run:  load-model <file.gguf> [sd-server flags...]
if [ -f /id/sd-model.args ]; then
  echo "[entrypoint] Restoring model: $(cat /id/sd-model.args)"
  # shellcheck disable=SC2046
  su ai -s /bin/sh -c "/usr/local/bin/load-model $(cat /id/sd-model.args)" \
    || echo "[entrypoint] WARNING: model restore failed; ssh in and run load-model manually."
else
  echo "[entrypoint] No model loaded yet - ssh in and run: load-model <file.gguf>"
fi

# ── optional web UI ───────────────────────────────────────────────────────
if [ "${FRONTEND:-1}" = "1" ]; then
  echo "[entrypoint] Serving UI on :${UI_PORT:-8090} (proxies /v1 to sd-server)"
  UI_PORT="${UI_PORT:-8090}" /app/serve &
fi

# ── supervise: sshd and tor must stay up; sd-server is optional ────────────
# (it only runs after you load-model; a crash there shouldn't kill the box)
while true; do
  pgrep -x sshd >/dev/null || { echo "[entrypoint] sshd died"; exit 1; }
  pgrep -x tor >/dev/null || { echo "[entrypoint] tor died"; exit 1; }
  sleep 15
done
