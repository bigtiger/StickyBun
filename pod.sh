#!/usr/bin/env bash
# Spin a Behemoth pod up/down on RunPod Secure Cloud, reachable only over Tailscale.
#   ./pod.sh test     cheap 7B smoke test (no volume): proves launch + tailnet + shutdown work
#   ./pod.sh up       the real thing (Behemoth 123B on H100, weights cached on your network volume)
#   ./pod.sh status | ssh | down
#
# Required env (or put in ~/.config/behemoth-pod.env):
#   RUNPOD_API_KEY   RunPod API key
#   TS_API_KEY       Tailscale API access token (mints a one-shot ephemeral auth key)
#   (or TS_AUTHKEY   a pre-made key instead of TS_API_KEY)
# Optional:
#   GPU_TYPE="NVIDIA H100 80GB HBM3"   comma-separated list = any of these, GPU_COUNT=1
#   MODEL_REPO=bartowski/Behemoth-123B-v2.2-GGUF   MODEL_PATH=Behemoth-123B-v2.2-IQ4_XS
#       (MODEL_PATH is a directory in the repo, or a single *.gguf file)
#   CTX=16384   IDLE_MIN=30   EXTRA_ARGS=""   TS_TAG=tag:gpu   TS_HOSTNAME=behemoth
#   NETWORK_VOLUME_ID=...  persist weights across runs (pins the pod to that datacenter)
#   HF_TOKEN=...
set -euo pipefail

[ -f "$HOME/.config/behemoth-pod.env" ] && . "$HOME/.config/behemoth-pod.env"

API=https://rest.runpod.io/v1
STATE="$HOME/.behemoth-pod.id"
HERE="$(cd "$(dirname "$0")" && pwd)"

GPU_TYPE=${GPU_TYPE:-NVIDIA H100 80GB HBM3}
GPU_COUNT=${GPU_COUNT:-1}
MODEL_REPO=${MODEL_REPO:-bartowski/Behemoth-123B-v2.2-GGUF}
MODEL_PATH=${MODEL_PATH:-Behemoth-123B-v2.2-IQ4_XS}
CTX=${CTX:-16384}
IDLE_MIN=${IDLE_MIN:-30}
TS_TAG=${TS_TAG:-tag:gpu}
TS_HOSTNAME=${TS_HOSTNAME:-behemoth}
IMAGE=${IMAGE:-ghcr.io/bigtiger/stickybun:latest}   # built from this repo's Dockerfile by CI
JOIN_TIMEOUT=${JOIN_TIMEOUT:-600}    # pod must join the tailnet within this, else it is terminated
READY_TIMEOUT=${READY_TIMEOUT:-3600} # model download + load; on timeout the pod is terminated (a resumable download survives on the volume)
: "${RUNPOD_API_KEY:?set RUNPOD_API_KEY}"

rp() { curl -fsS --http1.1 -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json' "$@"; }

mint_ts_key() {
  if [ -n "${TS_AUTHKEY:-}" ]; then echo "$TS_AUTHKEY"; return; fi
  : "${TS_API_KEY:?set TS_API_KEY or TS_AUTHKEY}"
  curl -fsS -u "$TS_API_KEY:" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg tag "$TS_TAG" '{expirySeconds:900,capabilities:{devices:{create:{reusable:false,ephemeral:true,preauthorized:true,tags:[$tag]}}}}')" \
    https://api.tailscale.com/api/v2/tailnet/-/keys | jq -r .key
}

# Ask the control plane, not the local daemon: a degraded local tailscaled never sees new peers.
# Hostname match is exact (Tailscale may append -1, -2 on collisions) so "behemoth" != "behemoth-test".
ts_devices() { curl -fsS --max-time 10 -u "$TS_API_KEY:" https://api.tailscale.com/api/v2/tailnet/-/devices 2>/dev/null; }
HOST_RE() { printf '^%s(-[0-9]+)?$' "$TS_HOSTNAME"; }
on_tailnet() {
  if [ -n "${TS_API_KEY:-}" ]; then
    ts_devices | jq -e --arg re "$(HOST_RE)" '[.devices[] | select(.hostname|test($re)) | select(.connectedToControl)] | length > 0' >/dev/null
  else
    tailscale status --json 2>/dev/null | jq -e --arg re "$(HOST_RE)" '[.Peer[]? | select(.HostName|test($re))] | length > 0' >/dev/null
  fi
}
# Tailnet IP of the pod (MagicDNS names don't always resolve locally); falls back to the hostname.
ts_ip() {
  local ip=""
  [ -n "${TS_API_KEY:-}" ] && ip=$(ts_devices | jq -r --arg re "$(HOST_RE)" '[.devices[] | select(.hostname|test($re)) | select(.connectedToControl)][0].addresses[0] // empty')
  echo "${ip:-$TS_HOSTNAME}"
}
# Only a definite 404 means the pod is gone; transient API errors (timeouts, HTTP/2 hiccups) don't.
pod_alive() {
  local code; code=$(curl -sS --http1.1 --max-time 15 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $RUNPOD_API_KEY" "$API/pods/$(cat "$STATE")" 2>/dev/null || true)
  [ "$code" != "404" ]
}

cmd_up() {
  if [ -f "$STATE" ]; then echo "pod already recorded ($(cat "$STATE")); run './pod.sh down' first" >&2; exit 1; fi

  local model_dir=/models disk=150
  if [ -n "${NETWORK_VOLUME_ID:-}" ]; then model_dir=/workspace/models; disk=30; fi
  disk=${CONTAINER_DISK:-$disk}

  local tskey; tskey=$(mint_ts_key)

  local body; body=$(jq -n \
    --arg name "$TS_HOSTNAME" --arg image "$IMAGE" --arg gpu "$GPU_TYPE" --argjson count "$GPU_COUNT" \
    --argjson disk "$disk" \
    --arg tskey "$tskey" --arg host "$TS_HOSTNAME" \
    --arg repo "$MODEL_REPO" --arg mpath "$MODEL_PATH" --arg mdir "$model_dir" \
    --arg ctx "$CTX" --arg idle "$IDLE_MIN" --arg extra "${EXTRA_ARGS:-}" --arg hf "${HF_TOKEN:-}" \
    --arg nv "${NETWORK_VOLUME_ID:-}" '
    {
      name: $name, imageName: $image, cloudType: "SECURE", computeType: "GPU",
      gpuTypeIds: ($gpu | split(",")), gpuTypePriority: "availability", gpuCount: $count,
      containerDiskInGb: $disk, volumeInGb: 0, ports: [],
      env: { TS_AUTHKEY: $tskey, TS_HOSTNAME: $host, MODEL_REPO: $repo,
             MODEL_PATH: $mpath, MODEL_DIR: $mdir, CTX: $ctx, IDLE_MIN: $idle,
             EXTRA_ARGS: $extra, HF_TOKEN: $hf }
    } + (if $nv != "" then {networkVolumeId: $nv, volumeMountPath: "/workspace"} else {} end)')

  echo "creating pod ($GPU_COUNT x $GPU_TYPE, Secure Cloud${NETWORK_VOLUME_ID:+, volume $NETWORK_VOLUME_ID})..."
  local resp; resp=$(rp -d "$body" "$API/pods")
  local id; id=$(echo "$resp" | jq -r .id)
  echo "$id" > "$STATE"
  echo "pod $id created: $(echo "$resp" | jq -r '"$\(.costPerHr // "?")/hr in \(.machine.dataCenterId // "?")"')"

  printf 'waiting for %s to join the tailnet (max %ss)' "$TS_HOSTNAME" "$JOIN_TIMEOUT"
  local t=0
  until on_tailnet; do
    sleep 10; t=$((t+10)); printf '.'
    if ! pod_alive; then echo; echo "pod vanished (self-terminated?); check RunPod console logs" >&2; rm -f "$STATE"; exit 1; fi
    if [ $t -ge "$JOIN_TIMEOUT" ]; then
      echo; echo "never joined the tailnet in ${JOIN_TIMEOUT}s; terminating pod to stop billing." >&2
      echo "see the pod's Logs in the RunPod console before retrying (boot prints [boot] lines)" >&2
      cmd_down; exit 1
    fi
  done
  echo " joined after ~${t}s"

  printf 'waiting for model load (first run downloads; max %ss)' "$READY_TIMEOUT"
  t=0; local gone=0 ip
  while true; do
    ip=$(ts_ip)
    curl -fs --max-time 5 "http://$ip:8080/health" >/dev/null 2>&1 && break
    sleep 15; t=$((t+15)); printf '.'
    if ! pod_alive; then echo; echo "pod vanished; check RunPod console logs" >&2; rm -f "$STATE"; exit 1; fi
    # boot.sh takes the node offline when it fails; 3 misses in a row = boot failed, stop billing.
    if on_tailnet; then gone=0; else gone=$((gone+1)); fi
    if [ $gone -ge 3 ]; then
      echo; echo "pod dropped off the tailnet: boot failed. terminating. Read the pod's CONTAINER logs in the RunPod console (not System logs)." >&2
      cmd_down; exit 1
    fi
    if [ $t -ge "$READY_TIMEOUT" ]; then
      echo; echo "not ready after ${READY_TIMEOUT}s; terminating pod (a partial download is kept on the volume and resumed next run)." >&2
      cmd_down; exit 1
    fi
  done
  echo
  echo "ready: http://$ip:8080/v1  (OpenAI-compatible, model name: behemoth)"
}

cmd_test() {
  # Cheap smoke test of the whole launch path: small GPU, 7B model, no volume, 10-min idle kill.
  GPU_TYPE=${TEST_GPU_TYPE:-NVIDIA RTX A4000,NVIDIA RTX A4500,NVIDIA RTX A5000,NVIDIA L4,NVIDIA GeForce RTX 3090,NVIDIA GeForce RTX 4090}
  MODEL_REPO=bartowski/Qwen2.5-7B-Instruct-GGUF
  MODEL_PATH=Qwen2.5-7B-Instruct-Q4_K_M.gguf
  CTX=4096; IDLE_MIN=10; TS_HOSTNAME=behemoth-test; CONTAINER_DISK=30
  unset NETWORK_VOLUME_ID
  cmd_up
  echo "test OK. try: curl http://$(ts_ip):8080/v1/chat/completions -H 'Content-Type: application/json' \\"
  echo "  -d '{\"model\":\"behemoth\",\"messages\":[{\"role\":\"user\",\"content\":\"say hi\"}]}'"
  echo "then: ./pod.sh down"
}

cmd_down() {
  [ -f "$STATE" ] || { echo "no pod recorded"; return 0; }
  local id; id=$(cat "$STATE")
  rp -X DELETE "$API/pods/$id" >/dev/null && echo "pod $id terminated"
  rm -f "$STATE"
}

cmd_status() {
  [ -f "$STATE" ] || { echo "no pod recorded"; exit 0; }
  rp "$API/pods/$(cat "$STATE")" | jq '{id, desiredStatus, costPerHr, gpu: .gpu.displayName, gpuCount}'
  curl -fs --max-time 5 "http://$(ts_ip):8080/health" && echo || echo "endpoint not reachable (yet)"
}

cmd_ssh() { exec tailscale ssh "root@$TS_HOSTNAME"; }   # logs: /tmp/llama.log, /tmp/tailscaled.log

case "${1:-}" in
  up) cmd_up ;; test) cmd_test ;; down) cmd_down ;; status) cmd_status ;; ssh) cmd_ssh ;;
  *) sed -n '2,5p' "$0"; exit 1 ;;
esac
