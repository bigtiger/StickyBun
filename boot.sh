#!/usr/bin/env bash
# Image ENTRYPOINT (see Dockerfile). Tailscale, aria2, jq and llama-server are baked in.
# Joins the tailnet in userspace mode, fetches the model, serves llama-server
# on 127.0.0.1 only (reachable solely via tailscale), and self-terminates when idle.
#
# Env (set by pod.sh): TS_AUTHKEY TS_HOSTNAME MODEL_REPO MODEL_PATH MODEL_DIR
#                      CTX IDLE_MIN EXTRA_ARGS HF_TOKEN(optional)
set -Eeuo pipefail

PORT=8080
exec > >(tee -a /tmp/boot.log) 2>&1   # console + file, so a failing pod can serve its own log
LLAMA_LOG=/tmp/llama.log   # prompts never go to the provider-visible console

# The key RunPod injects into pods may be too restricted to delete the pod (it was: HTTP 403),
# so try every route and, if all fail, shout. pod.sh also notices and terminates from outside.
kill_pod() {
  if command -v runpodctl >/dev/null 2>&1 && runpodctl remove pod "${RUNPOD_POD_ID:-}" 2>&1; then return; fi
  if [ -n "${RUNPOD_API_KEY:-}" ] && [ -n "${RUNPOD_POD_ID:-}" ] \
     && curl -fsS -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID"; then return; fi
  while true; do echo "[boot] !!! CANNOT SELF-TERMINATE; pod is still billing, run './pod.sh down'"; sleep 600; done
}

# Any failure: stay on the tailnet and serve the tail of the boot log on :8081 so pod.sh can print
# it and terminate us; if nobody does, try to stop the billing ourselves after 10 min.
serve_failure() {
  tailscale serve --bg --tcp=8081 tcp://127.0.0.1:8081 >/dev/null 2>&1 || true
  while true; do
    { printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n'; tail -n 60 /tmp/boot.log; } \
      | nc -l -s 127.0.0.1 -p 8081 -q1 >/dev/null 2>&1
  done
}
trap 'rc=$?; trap - ERR; echo "[boot] FAILED (line $LINENO, rc=$rc); serving log on :8081, terminating in 10m"; serve_failure & sleep 600; kill_pod' ERR

echo "[boot] started $(date -u +%FT%TZ) on $(hostname); gpu: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | paste -sd';' -)"
mkdir -p /var/run/tailscale
tailscaled --tun=userspace-networking --state=mem: \
  --socket=/var/run/tailscale/tailscaled.sock >/tmp/tailscaled.log 2>&1 &
sleep 3
tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" --ssh --accept-dns=false
unset TS_AUTHKEY
tailscale serve --bg --tcp="$PORT" "tcp://127.0.0.1:$PORT" || echo "[boot] warn: tailscale serve failed"
echo "[boot] tailnet up as $TS_HOSTNAME"

echo "[boot] model $MODEL_REPO / $MODEL_PATH -> $MODEL_DIR"
mkdir -p "$MODEL_DIR"
auth=(); [ -n "${HF_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $HF_TOKEN")
if [[ "$MODEL_PATH" == *.gguf ]]; then
  dir=$(dirname "$MODEL_PATH"); [ "$dir" = . ] && dir=""
  match="^${MODEL_PATH//./\\.}\$"
else
  dir="$MODEL_PATH"; match='.'
fi
listing=$(curl -fsSL "${auth[@]}" "https://huggingface.co/api/models/$MODEL_REPO/tree/main/$dir" \
  | jq -c --arg m "$match" '[.[] | select(.type=="file" and (.path|test($m))) | {path, size}]')
files=$(echo "$listing" | jq -r '.[].path' | sort)
[ -n "$files" ] || { echo "[boot] no files matched in repo"; false; }

need=0
while read -r path size; do   # only count files not already fully cached
  if [ ! -f "$MODEL_DIR/$path" ] || [ -f "$MODEL_DIR/$path.aria2" ]; then need=$((need + size)); fi
done < <(echo "$listing" | jq -r '.[] | "\(.path) \(.size)"')
have=$(df -B1 --output=avail "$MODEL_DIR" | tail -n1)
echo "[boot] still to download: $((need/1000000000))GB (df free: $((have/1000000000))GB; unreliable on network volumes)"
[ "$have" -gt "$need" ] || { echo "[boot] not enough free space"; false; }

for f in $files; do
  [ -f "$MODEL_DIR/$f" ] && [ ! -f "$MODEL_DIR/$f.aria2" ] && { echo "[boot] cached: $f"; continue; }
  mkdir -p "$MODEL_DIR/$(dirname "$f")"
  echo "[boot] downloading $f"
  # file-allocation=none: preallocating 40GB fails (rc 17) on RunPod network volumes.
  # If aria2 still fails, fall back to a single resumable curl stream.
  aria2c --file-allocation=none --console-log-level=warn --summary-interval=30 --download-result=hide \
    -x16 -s16 -k4M -c --dir="$MODEL_DIR/$(dirname "$f")" -o "$(basename "$f")" \
    ${HF_TOKEN:+--header="Authorization: Bearer $HF_TOKEN"} \
    "https://huggingface.co/$MODEL_REPO/resolve/main/$f" \
  || { echo "[boot] aria2c failed, falling back to curl"; rm -f "$MODEL_DIR/$f.aria2"; \
       curl -fL -C - --retry 5 --retry-delay 5 "${auth[@]}" -o "$MODEL_DIR/$f" \
         "https://huggingface.co/$MODEL_REPO/resolve/main/$f"; }
done
first="$MODEL_DIR/$(echo "$files" | head -n1)"
echo "[boot] model ready: $first"

LS=$(command -v llama-server || echo /app/llama-server)
# shellcheck disable=SC2086
nohup "$LS" -m "$first" -ngl 999 -c "$CTX" --host 127.0.0.1 --port "$PORT" \
  --metrics --alias behemoth ${EXTRA_ARGS:-} >"$LLAMA_LOG" 2>&1 &
echo "[boot] llama-server pid $! (log: $LLAMA_LOG, via 'tailscale ssh')"

# Activity = any change in llama.cpp's metrics. Unreachable/dead server counts as idle.
last=""; idle_since=$(date +%s)
while sleep 60; do
  cur=$(curl -fs "http://127.0.0.1:$PORT/metrics" | grep '^llamacpp:' | md5sum | cut -d' ' -f1 || echo down)
  [ -z "$cur" ] && cur=down
  if [ "$cur" != "$last" ]; then last="$cur"; idle_since=$(date +%s); fi
  if [ $(( $(date +%s) - idle_since )) -ge $(( IDLE_MIN * 60 )) ]; then
    echo "[watchdog] idle ${IDLE_MIN}m, terminating pod"; kill_pod
  fi
done
