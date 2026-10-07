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
READY_TIMEOUT=${READY_TIMEOUT:-2700} # model download + load; on timeout the pod is left running
: "${RUNPOD_API_KEY:?set RUNPOD_API_KEY}"

rp() { curl -fsS -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json' "$@"; }

mint_ts_key() {
  if [ -n "${TS_AUTHKEY:-}" ]; then echo "$TS_AUTHKEY"; return; fi
  : "${TS_API_KEY:?set TS_API_KEY or TS_AUTHKEY}"
  curl -fsS -u "$TS_API_KEY:" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg tag "$TS_TAG" '{expirySeconds:900,capabilities:{devices:{create:{reusable:false,ephemeral:true,preauthorized:true,tags:[$tag]}}}}')" \
    https://api.tailscale.com/api/v2/tailnet/-/keys | jq -r .key
}

on_tailnet() { tailscale status --json 2>/dev/null | jq -e --arg h "$TS_HOSTNAME" '[.Peer[]? | select(.HostName|startswith($h))] | length > 0' >/dev/null; }
pod_alive()  { rp "$API/pods/$(cat "$STATE")" >/dev/null 2>&1; }

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
  t=0
  until curl -fs --max-time 5 "http://$TS_HOSTNAME:8080/health" >/dev/null 2>&1; do
    sleep 15; t=$((t+15)); printf '.'
    if ! pod_alive; then echo; echo "pod vanished; check RunPod console logs" >&2; rm -f "$STATE"; exit 1; fi
    if [ $t -ge "$READY_TIMEOUT" ]; then
      echo; echo "not ready after ${READY_TIMEOUT}s; pod LEFT RUNNING. './pod.sh ssh' (tail /tmp/llama.log) or './pod.sh down'" >&2
      exit 1
    fi
  done
  echo
  echo "ready: http://$TS_HOSTNAME:8080/v1  (OpenAI-compatible, model name: behemoth)"
}

cmd_test() {
  # Cheap smoke test of the whole launch path: small GPU, 7B model, no volume, 10-min idle kill.
  GPU_TYPE=${TEST_GPU_TYPE:-NVIDIA RTX A4000,NVIDIA RTX A4500,NVIDIA RTX A5000,NVIDIA L4,NVIDIA GeForce RTX 3090,NVIDIA GeForce RTX 4090}
  MODEL_REPO=bartowski/Qwen2.5-7B-Instruct-GGUF
  MODEL_PATH=Qwen2.5-7B-Instruct-Q4_K_M.gguf
  CTX=4096; IDLE_MIN=10; TS_HOSTNAME=behemoth-test; CONTAINER_DISK=30
  unset NETWORK_VOLUME_ID
  cmd_up
  echo "test OK. try: curl http://$TS_HOSTNAME:8080/v1/chat/completions -H 'Content-Type: application/json' \\"
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
  curl -fs --max-time 5 "http://$TS_HOSTNAME:8080/health" && echo || echo "endpoint not reachable (yet)"
}

cmd_ssh() { exec tailscale ssh "root@$TS_HOSTNAME"; }   # logs: /tmp/llama.log, /tmp/tailscaled.log

case "${1:-}" in
  up) cmd_up ;; test) cmd_test ;; down) cmd_down ;; status) cmd_status ;; ssh) cmd_ssh ;;
  *) sed -n '2,5p' "$0"; exit 1 ;;
esac
