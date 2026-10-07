# StickyBun

Spin up a large open-weight model (default: Behemoth 123B) on a RunPod Secure Cloud GPU,
reachable only over your Tailscale tailnet. One image, two scripts.

- `Dockerfile` / `boot.sh`: image entrypoint. Joins the tailnet (userspace mode), fetches the GGUF,
  serves llama.cpp on 127.0.0.1 only, and terminates the pod after `IDLE_MIN` minutes of inactivity.
- `pod.sh`: `test | up | status | ssh | down` against the RunPod REST API.
- CI builds `ghcr.io/<owner>/stickybun:latest` on every change to `Dockerfile` or `boot.sh`.

Keys live in `~/.config/behemoth-pod.env` (`RUNPOD_API_KEY`, `TS_API_KEY`, optional `NETWORK_VOLUME_ID`).
Nothing secret is baked into the image; auth keys are passed as single-use pod env vars.
The image is public by design, so never commit keys here.
