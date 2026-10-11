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
#   CHAT_TEMPLATE_FILE=path  jinja chat template for llama-server (--jinja). Defaults to
#       templates/behemoth-tools.jinja for Behemoth: the GGUF's embedded template is chat-only
#       (supports_tools false, rejects the tool role), so tool calling never worked without it.
#       Set it empty to keep the GGUF's own template.
#   PROFILE=name   load profiles/<name>.env (e.g. PROFILE=qwen36-27b ./pod.sh up)
#   ENGINE=vllm    serve MODEL_REPO with vLLM (image :vllm, needs TOOL_PARSER) instead of llama-server
#   POD_NAME=...   separate state file + tailnet hostname, so pods can coexist (default behemoth)
set -euo pipefail

[ -f "$HOME/.config/behemoth-pod.env" ] && . "$HOME/.config/behemoth-pod.env"
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${PROFILE:-}" ]; then . "$HERE/profiles/$PROFILE.env"; fi

API=https://rest.runpod.io/v1
POD_NAME=${POD_NAME:-behemoth}
STATE="$HOME/.$POD_NAME-pod.id"
ENGINE=${ENGINE:-llama}
TOOL_PARSER=${TOOL_PARSER:-}
SERVED_AS=$([ "$ENGINE" = vllm ] && echo model || echo behemoth)   # vllm --served-model-name / llama --alias

GPU_TYPE=${GPU_TYPE:-NVIDIA H100 80GB HBM3}
GPU_COUNT=${GPU_COUNT:-1}
MODEL_REPO=${MODEL_REPO:-bartowski/Behemoth-123B-v2.2-GGUF}
MODEL_PATH=${MODEL_PATH:-Behemoth-123B-v2.2-IQ4_XS}
CTX=${CTX:-16384}
IDLE_MIN=${IDLE_MIN:-30}
TS_TAG=${TS_TAG:-tag:gpu}
TS_HOSTNAME=${TS_HOSTNAME:-$POD_NAME}
# Built by CI: :latest from Dockerfile, :vllm from Dockerfile.vllm
IMAGE=${IMAGE:-ghcr.io/bigtiger/stickybun:$([ "$ENGINE" = vllm ] && echo vllm || echo latest)}
JOIN_TIMEOUT=${JOIN_TIMEOUT:-600}    # pod must join the tailnet within this, else it is terminated
READY_TIMEOUT=${READY_TIMEOUT:-3600} # model download + load; on timeout the pod is terminated (a resumable download survives on the volume)
: "${RUNPOD_API_KEY:?set RUNPOD_API_KEY}"

# Not curl -f: that discards RunPod's error body, which says why a create was refused (e.g. no capacity).
rp() {
  local out code
  out=$(curl -sS --http1.1 -w '\n%{http_code}' -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json' "$@") || return
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [ "$code" -ge 400 ]; then echo "RunPod HTTP $code: $out" >&2; return 22; fi
  printf '%s\n' "$out"
}

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
# Offline ephemeral nodes from earlier runs keep the hostname for a while, so the next pod becomes
# behemoth-1 and MagicDNS "behemoth" points at a dead node. Remove only offline tag nodes with our hostname.
ts_cleanup() {
  [ -n "${TS_API_KEY:-}" ] || return 0
  ts_devices | jq -r --arg re "$(HOST_RE)" --arg tag "$TS_TAG" \
    '.devices[] | select(.hostname|test($re)) | select(.connectedToControl|not) | select((.tags // []) | index($tag)) | .id' \
  | while read -r id; do
      curl -fsS -X DELETE -u "$TS_API_KEY:" "https://api.tailscale.com/api/v2/device/$id" >/dev/null \
        && echo "removed stale tailnet node $id"
    done
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

  ts_cleanup
  local model_dir=/models disk=150
  if [ -n "${NETWORK_VOLUME_ID:-}" ]; then model_dir=/workspace/models; disk=30; fi
  disk=${CONTAINER_DISK:-$disk}

  local tskey; tskey=$(mint_ts_key)

  # Shipped in an env var and written out by a start-command wrapper, so the image
  # (built by CI from boot.sh) doesn't need rebuilding to change the template.
  local extra="${EXTRA_ARGS:-}" tpl_b64=""
  if [ -z "${CHAT_TEMPLATE_FILE+x}" ] && [ "$ENGINE" = llama ] && [[ "$MODEL_REPO" == *Behemoth* ]]; then
    CHAT_TEMPLATE_FILE="$HERE/templates/behemoth-tools.jinja"
  fi
  if [ -n "${CHAT_TEMPLATE_FILE:-}" ]; then
    tpl_b64=$(base64 < "$CHAT_TEMPLATE_FILE" | tr -d '\n')
    extra="--jinja --chat-template-file /tmp/chat.jinja $extra"
  fi

  local body; body=$(jq -n \
    --arg name "$TS_HOSTNAME" --arg image "$IMAGE" --arg gpu "$GPU_TYPE" --argjson count "$GPU_COUNT" \
    --argjson disk "$disk" \
    --arg tskey "$tskey" --arg host "$TS_HOSTNAME" \
    --arg repo "$MODEL_REPO" --arg mpath "$MODEL_PATH" --arg mdir "$model_dir" \
    --arg ctx "$CTX" --arg idle "$IDLE_MIN" --arg extra "$extra" --arg hf "${HF_TOKEN:-}" \
    --arg tpl "$tpl_b64" --arg nv "${NETWORK_VOLUME_ID:-}" \
    --arg engine "$ENGINE" --arg parser "$TOOL_PARSER" '
    {
      name: $name, imageName: $image, cloudType: "SECURE", computeType: "GPU",
      gpuTypeIds: ($gpu | split(",")), gpuTypePriority: "availability", gpuCount: $count,
      containerDiskInGb: $disk, volumeInGb: 0, ports: [],
      env: { TS_AUTHKEY: $tskey, TS_HOSTNAME: $host, MODEL_REPO: $repo,
             MODEL_PATH: $mpath, MODEL_DIR: $mdir, CTX: $ctx, IDLE_MIN: $idle,
             EXTRA_ARGS: $extra, HF_TOKEN: $hf, CHAT_TEMPLATE_B64: $tpl,
             ENGINE: $engine, TOOL_PARSER: $parser }
    } + (if $tpl != "" then {dockerEntrypoint: ["/bin/bash", "-c"],
            dockerStartCmd: ["printf %s \"$CHAT_TEMPLATE_B64\" | base64 -d > /tmp/chat.jinja && exec /boot.sh"]}
         else {} end)
      + (if $nv != "" then {networkVolumeId: $nv, volumeMountPath: "/workspace"} else {} end)')

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
    # A failed boot.sh serves its log on :8081. Print it, then stop the billing.
    local flog; flog=$(curl -fs --max-time 5 "http://$ip:8081/" 2>/dev/null || true)
    if [ -n "$flog" ]; then
      echo; echo "---- pod boot failed; its log: ----" >&2; echo "$flog" >&2; echo "-----------------------------------" >&2
      cmd_down; exit 1
    fi
    # Fallback: node dropped off the tailnet 3 checks in a row (crash with no log).
    if on_tailnet; then gone=0; else gone=$((gone+1)); fi
    if [ $gone -ge 3 ]; then
      echo; echo "pod dropped off the tailnet with no log; terminating. Check the pod's CONTAINER logs in the RunPod console." >&2
      cmd_down; exit 1
    fi
    if [ $t -ge "$READY_TIMEOUT" ]; then
      echo; echo "not ready after ${READY_TIMEOUT}s; terminating pod (a partial download is kept on the volume and resumed next run)." >&2
      cmd_down; exit 1
    fi
  done
  echo
  echo "ready: http://$ip:8080/v1  (OpenAI-compatible, model name: $SERVED_AS)"
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
  echo "  -d '{\"model\":\"$SERVED_AS\",\"messages\":[{\"role\":\"user\",\"content\":\"say hi\"}]}'"
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
