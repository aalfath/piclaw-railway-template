# PiClaw for Railway: the official PiClaw image with a small Caddy front that adds
# a login (HTTP basic auth, generated password) and an open /healthz for Railway.
# Bump both pins together with a CHANGELOG.md entry; a merge to main notifies deployers.
FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0 AS caddy

FROM ghcr.io/rcarmo/piclaw:v3.3.4@sha256:2106ba6e7421053095e7092d81adabf962e5b5336be61fffe916569fc03e6d57

USER root
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /etc/piclaw-railway/Caddyfile
COPY start.sh /usr/local/bin/piclaw-railway-start

# One Railway volume at /workspace holds everything: the workspace, PiClaw's
# database (.piclaw/store/messages.db) and the Pi profile (/config -> /workspace/.home).
# The image's "agent" user keeps passwordless sudo (upstream's sandbox design),
# but its fixed login password is locked.
RUN chmod 0755 /usr/local/bin/piclaw-railway-start && \
    rm -rf /config && ln -s /workspace/.home /config && \
    passwd -l agent >/dev/null

ENV PORT=8080 \
    PICLAW_WEB_HOST=127.0.0.1 \
    PICLAW_WEB_PORT=8081 \
    PICLAW_TRUST_PROXY=1

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/piclaw-railway-start"]
