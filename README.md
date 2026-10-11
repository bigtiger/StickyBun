# StickyBun

Spin up a large open-weight model (default: Behemoth 123B) on a RunPod Secure Cloud GPU,
reachable only over your Tailscale tailnet. One image, two scripts.

- `Dockerfile` / `boot.sh`: image entrypoint. Joins the tailnet (userspace mode), fetches the GGUF,
  serves llama.cpp on 127.0.0.1 only, and terminates the pod after `IDLE_MIN` minutes of inactivity.
- `pod.sh`: `test | up | status | ssh | down` against the RunPod REST API.
- CI builds `ghcr.io/<owner>/stickybun:latest` on every change to `Dockerfile` or `boot.sh`,
  and `:vllm` from `Dockerfile.vllm`.

## vLLM mode

`ENGINE=vllm` serves a safetensors/FP8 `MODEL_REPO` with vLLM (pinned in `Dockerfile.vllm`):
native tool-call parsing (`TOOL_PARSER`), request priority (send `"priority": -1` to jump the
queue), and JSON-schema output without whitespace padding. Weights cache in `HF_HOME` on the
network volume. Ready-made candidates live in `profiles/`:

```
PROFILE=qwen36-27b ./pod.sh up        # Qwen3.6-27B-FP8, hostname "analyst", model name "model"
PROFILE=gemma4-31b-heretic ./pod.sh up
POD_NAME=analyst ./pod.sh down
```

`POD_NAME` gives each pod its own state file and tailnet hostname, so a vLLM pod and a
Behemoth pod can run side by side.

Keys live in `~/.config/behemoth-pod.env` (`RUNPOD_API_KEY`, `TS_API_KEY`, optional `NETWORK_VOLUME_ID`).
Nothing secret is baked into the image; auth keys are passed as single-use pod env vars.
The image is public by design, so never commit keys here.
