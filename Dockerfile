FROM ghcr.io/ggml-org/llama.cpp:server-cuda
LABEL org.opencontainers.image.source="https://github.com/bigtiger/StickyBun"
LABEL org.opencontainers.image.description="llama.cpp server + Tailscale, started by boot.sh (see repo)"

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl aria2 jq ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && f=$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' | jq -r '.Tarballs.amd64') \
 && curl -fsSL "https://pkgs.tailscale.com/stable/${f}" | tar -xz -C /tmp \
 && cp /tmp/tailscale_*/tailscale /tmp/tailscale_*/tailscaled /usr/local/bin/ \
 && rm -rf /tmp/tailscale_*

COPY boot.sh /boot.sh
RUN chmod +x /boot.sh
ENTRYPOINT ["/boot.sh"]
