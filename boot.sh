#!/usr/bin/env bash
# Image ENTRYPOINT (see Dockerfile / Dockerfile.vllm). Joins the tailnet in
# userspace mode, serves the model on 127.0.0.1 only (reachable solely via
# tailscale), and self-terminates when idle.
#
# ENGINE=llama (default, Dockerfile): fetches and verifies GGUF files, runs llama-server.
# ENGINE=vllm (Dockerfile.vllm): vLLM fetches MODEL_REPO itself into HF_HOME on the
#   volume and serves it with native tool-call parsing (TOOL_PARSER) and request
#   priority, so a live-coach call can jump ahead of long analyst generations.
#
# Env (set by pod.sh): TS_AUTHKEY TS_HOSTNAME MODEL_REPO MODEL_PATH MODEL_DIR
#                      CTX IDLE_MIN EXTRA_ARGS HF_TOKEN(optional) ENGINE TOOL_PARSER
set -Eeuo pipefail

PORT=8080
ENGINE=${ENGINE:-llama}
exec > >(tee -a /tmp/boot.log) 2>&1   # console + file, so a failing pod can serve its own log
LLAMA_LOG=/tmp/llama.log   # server log (either engine); prompts never go to the provider-visible console

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
    { printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n'; tail -n 90 /tmp/boot.log; } \
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

if [ "$ENGINE" = vllm ]; then
  # vLLM downloads and caches the repo itself; HF_HOME on the volume makes the
  # next pod's start a cache hit. Served as "model" so clients don't care which.
  export HF_HOME="$MODEL_DIR/hf"
  mkdir -p "$HF_HOME"
  echo "[boot] vllm serving $MODEL_REPO (tool parser ${TOOL_PARSER:?set TOOL_PARSER for ENGINE=vllm})"
  # shellcheck disable=SC2086
  nohup vllm serve "$MODEL_REPO" --host 127.0.0.1 --port "$PORT" --served-model-name model \
    --max-model-len "$CTX" --enable-auto-tool-choice --tool-call-parser "$TOOL_PARSER" \
    --scheduling-policy priority \
    --structured-outputs-config '{"backend":"xgrammar","disable_any_whitespace":true}' \
    ${EXTRA_ARGS:-} >"$LLAMA_LOG" 2>&1 &
  LLAMA_PID=$!
  METRIC_PREFIX='^vllm:'
else
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
  | jq -c --arg m "$match" '[.[] | select(.type=="file" and (.path|test($m))) | {path, size, oid: (.lfs.oid // "")}]')
files=$(echo "$listing" | jq -r '.[].path' | sort)
[ -n "$files" ] || { echo "[boot] no files matched in repo"; false; }

# A file counts as cached only if it carries our .ok marker (written after size + GGUF magic + sha256
# checks) and its size still matches. Anything else is deleted and fetched fresh: a failed or
# preallocated download can leave a full-size, zero-filled file that merely looks complete.
is_cached() { [ -f "$MODEL_DIR/$1.ok" ] && [ "$(stat -c %s "$MODEL_DIR/$1" 2>/dev/null || echo 0)" = "$2" ]; }

need=0
while read -r path size oid; do
  is_cached "$path" "$size" || need=$((need + size))
done < <(echo "$listing" | jq -r 'sort_by(.path)[] | "\(.path) \(.size) \(.oid)"')
have=$(df -B1 --output=avail "$MODEL_DIR" | tail -n1)
echo "[boot] still to download: $((need/1000000000))GB (df free: $((have/1000000000))GB; unreliable on network volumes)"
[ "$have" -gt "$need" ] || { echo "[boot] not enough free space"; false; }

while read -r f size oid; do
  if is_cached "$f" "$size"; then echo "[boot] cached (verified): $f"; continue; fi
  rm -f "$MODEL_DIR/$f" "$MODEL_DIR/$f.aria2" "$MODEL_DIR/$f.ok"
  mkdir -p "$MODEL_DIR/$(dirname "$f")"
  echo "[boot] downloading $f"
  # file-allocation=none: preallocating 40GB fails (rc 17) on RunPod network volumes.
  # If aria2 still fails, fall back to a single resumable curl stream. </dev/null keeps them off the loop's stdin.
  aria2c --file-allocation=none --console-log-level=warn --summary-interval=30 --download-result=hide \
    -x16 -s16 -k4M -c --dir="$MODEL_DIR/$(dirname "$f")" -o "$(basename "$f")" \
    ${HF_TOKEN:+--header="Authorization: Bearer $HF_TOKEN"} \
    "https://huggingface.co/$MODEL_REPO/resolve/main/$f" </dev/null \
  || { echo "[boot] aria2c failed, falling back to curl"; rm -f "$MODEL_DIR/$f.aria2"; \
       curl -fL -C - --retry 5 --retry-delay 5 "${auth[@]}" -o "$MODEL_DIR/$f" \
         "https://huggingface.co/$MODEL_REPO/resolve/main/$f" </dev/null; }
  echo "[boot] verifying $f"
  [ "$(stat -c %s "$MODEL_DIR/$f")" = "$size" ] || { echo "[boot] size mismatch for $f"; rm -f "$MODEL_DIR/$f"; false; }
  if [[ "$f" == *.gguf ]] && [ "$(head -c4 "$MODEL_DIR/$f")" != "GGUF" ]; then
    echo "[boot] $f has no GGUF header"; rm -f "$MODEL_DIR/$f"; false
  fi
  if [ -n "$oid" ]; then
    got=$(sha256sum "$MODEL_DIR/$f" | cut -d' ' -f1)
    [ "$got" = "$oid" ] || { echo "[boot] sha256 mismatch for $f (got $got, want $oid)"; rm -f "$MODEL_DIR/$f"; false; }
  fi
  touch "$MODEL_DIR/$f.ok"
done < <(echo "$listing" | jq -r 'sort_by(.path)[] | "\(.path) \(.size) \(.oid)"')
first="$MODEL_DIR/$(echo "$files" | head -n1)"
echo "[boot] model ready: $first"

LS=$(command -v llama-server || echo /app/llama-server)
# shellcheck disable=SC2086
nohup "$LS" -m "$first" -ngl 999 -c "$CTX" --host 127.0.0.1 --port "$PORT" \
  --metrics --alias behemoth ${EXTRA_ARGS:-} >"$LLAMA_LOG" 2>&1 &
LLAMA_PID=$!
METRIC_PREFIX='^llamacpp:'
fi
echo "[boot] $ENGINE server pid $LLAMA_PID (log: $LLAMA_LOG, via 'tailscale ssh')"

# Supervise startup: if llama-server dies (bad GGUF, CUDA OOM, flag error) surface its log through the
# failure path instead of idling silently until the watchdog. Ready = /health answers 200.
for _ in $(seq 1 240); do                         # up to ~40 min to load
  if ! kill -0 "$LLAMA_PID" 2>/dev/null; then
    # The cause sits above a long traceback: vLLM's last 40 lines were all
    # "Engine core initialization failed" frames, the real error scrolled off.
    echo "[boot] $ENGINE server exited during startup; error lines from $LLAMA_LOG:"
    grep -E "Error|Exception|error:|CUDA|out of memory|not supported|Traceback" "$LLAMA_LOG" \
      | grep -v '^ *File "' | grep -v "Engine core initialization failed" | tail -n 25 || true
    echo "[boot] last lines:"
    tail -n 15 "$LLAMA_LOG"
    false
  fi
  curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { echo "[boot] $ENGINE server healthy"; break; }
  sleep 10
done

# Activity = any change in the server's metrics. Unreachable/dead server counts as idle.
last=""; idle_since=$(date +%s)
while sleep 60; do
  cur=$(curl -fs "http://127.0.0.1:$PORT/metrics" | grep "$METRIC_PREFIX" | md5sum | cut -d' ' -f1 || echo down)
  [ -z "$cur" ] && cur=down
  if [ "$cur" != "$last" ]; then last="$cur"; idle_since=$(date +%s); fi
  if [ $(( $(date +%s) - idle_since )) -ge $(( IDLE_MIN * 60 )) ]; then
    echo "[watchdog] idle ${IDLE_MIN}m, terminating pod"; kill_pod
  fi
done
