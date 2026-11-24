#!/bin/bash
# PiClaw on Railway: seed the LLM provider, start PiClaw (upstream entrypoint +
# supervisord, 127.0.0.1:8081) and Caddy ($PORT: login + /healthz).
# Exits non-zero as soon as Caddy, supervisord or the PiClaw program stops for
# good, so Railway's ON_FAILURE restart policy brings the service back.
set -euo pipefail

log() { echo "piclaw-railway: $*"; }

export PICLAW_USERNAME="${PICLAW_USERNAME:-piclaw}"
if [ -z "${PICLAW_PASSWORD:-}" ] || [ "${#PICLAW_PASSWORD}" -lt 12 ]; then
	echo "piclaw-railway: PICLAW_PASSWORD must be set (12+ characters). Refusing to start an open agent with a shell." >&2
	exit 1
fi

# --- Persistent layout: everything lives on the /workspace volume -------------
mkdir -p /workspace/.home/.pi/agent
chown agent:agent /workspace /workspace/.home /workspace/.home/.pi /workspace/.home/.pi/agent
# A fresh container has no /home/agent marker, so the upstream entrypoint
# re-creates the home skeleton and re-links ~/.pi and ~/.gitconfig to /config.

# --- Size limits from the service's memory limit -------------------------------
limit_mb=0
if [ -r /sys/fs/cgroup/memory.max ]; then
	raw=$(cat /sys/fs/cgroup/memory.max)
	[ "$raw" != "max" ] && limit_mb=$((raw / 1048576))
fi
if [ -z "${PICLAW_WEB_WORKSPACE_UPLOAD_LIMIT_MB:-}" ]; then
	up=256
	if [ "$limit_mb" -gt 0 ]; then
		up=$((limit_mb / 8)); [ "$up" -lt 16 ] && up=16; [ "$up" -gt 256 ] && up=256
	fi
	export PICLAW_WEB_WORKSPACE_UPLOAD_LIMIT_MB="$up"
fi
export PICLAW_WEB_COMPOSE_UPLOAD_LIMIT_MB="${PICLAW_WEB_COMPOSE_UPLOAD_LIMIT_MB:-16}"

# --- LLM provider (OpenAI-compatible) from Railway variables -------------------
# The key itself never touches the disk: models.json refers to $LLM_API_KEY.
# The entry is ours while its apiKey is still that reference; if you set the
# provider up again with /login in the UI, this script leaves it alone.
AGENT_DIR=/workspace/.home/.pi/agent
MODELS="$AGENT_DIR/models.json"
SETTINGS="$AGENT_DIR/settings.json"
PROVIDER=openai-compatible
LLM_BASE_URL="${LLM_BASE_URL:-https://api.openai.com/v1}"
LLM_MODEL="${LLM_MODEL:-gpt-5.4-mini}"
LLM_CONTEXT_WINDOW="${LLM_CONTEXT_WINDOW:-128000}"
if [ -n "${LLM_API_KEY:-}" ]; then
	[ -s "$MODELS" ] || echo '{}' > "$MODELS"
	[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
	if jq -e --arg p "$PROVIDER" '(.providers[$p] // null) == null or .providers[$p].apiKey == "$LLM_API_KEY"' "$MODELS" >/dev/null 2>&1; then
		models_ids=$(printf '%s' "$LLM_MODEL${LLM_EXTRA_MODELS:+,$LLM_EXTRA_MODELS}" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | jq -R . | jq -s .)
		jq --arg p "$PROVIDER" --arg url "$LLM_BASE_URL" --argjson ids "$models_ids" --argjson ctx "$LLM_CONTEXT_WINDOW" \
			'.providers = (.providers // {}) | .providers[$p] = {baseUrl: $url, api: "openai-completions", apiKey: "$LLM_API_KEY",
			  models: [$ids[] | {id: ., name: ., contextWindow: $ctx}]}' "$MODELS" > "$MODELS.tmp" && mv "$MODELS.tmp" "$MODELS"
		# Point new sessions at it unless the user picked a model of another provider.
		jq --arg p "$PROVIDER" --arg m "$LLM_MODEL" \
			'if (.defaultProvider // $p) == $p then .defaultProvider = $p | .defaultModel = $m else . end' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
		log "LLM provider '$PROVIDER' set to $LLM_BASE_URL, default model $LLM_MODEL"
	else
		log "LLM provider '$PROVIDER' was set up in the UI; leaving it unchanged"
	fi
	chown agent:agent "$MODELS" "$SETTINGS"
	chmod 600 "$MODELS"
else
	log "LLM_API_KEY is empty: set it in Railway, or configure a provider with /login in the chat"
fi

# --- Caddy (login + /healthz) --------------------------------------------------
PICLAW_PASSWORD_HASH=$(caddy hash-password --algorithm bcrypt --bcrypt-cost 10 --plaintext "$PICLAW_PASSWORD")
export PICLAW_PASSWORD_HASH
unset PICLAW_PASSWORD
mkdir -p /tmp/caddy
(cd /tmp/caddy && HOME=/tmp/caddy XDG_CONFIG_HOME=/tmp/caddy XDG_DATA_HOME=/tmp/caddy GOMEMLIMIT="${GOMEMLIMIT:-48MiB}" GOMAXPROCS="${CADDY_GOMAXPROCS:-2}" \
	exec caddy run --adapter caddyfile --config /etc/piclaw-railway/Caddyfile) &
proxy=$!
unset PICLAW_PASSWORD_HASH

# --- PiClaw: upstream entrypoint (home skeleton, supervisord as manager) -------
/entrypoint.sh &
app=$!

stopping=0
term() {
	stopping=1
	kill -TERM "$app" "$proxy" 2>/dev/null || true
}
trap term TERM INT

log "PiClaw $(jq -r .version /usr/local/lib/bun/install/global/node_modules/piclaw/package.json 2>/dev/null || echo '?') starting (memory limit ${limit_mb:-?} MB)"
reason=""
while :; do
	sleep 5 &
	wait $! || true
	[ "$stopping" = 1 ] && break
	if ! kill -0 "$proxy" 2>/dev/null; then reason="Caddy stopped"; break; fi
	if ! kill -0 "$app" 2>/dev/null; then reason="supervisord stopped"; break; fi
	# supervisord keeps running after PiClaw gives up (FATAL): treat that as a crash.
	state=$(supervisorctl -s unix:///var/run/supervisor.sock status piclaw 2>/dev/null | awk '{print $2}' || true)
	case "$state" in
		FATAL) reason="PiClaw is $state under supervisord"; break ;;
	esac
done

kill -TERM "$app" "$proxy" 2>/dev/null || true
wait "$app" 2>/dev/null || true
wait "$proxy" 2>/dev/null || true
if [ "$stopping" = 1 ]; then
	exit 0
fi
echo "piclaw-railway: $reason; exiting 1 so Railway restarts the service" >&2
tail -n 20 /var/log/piclaw/piclaw.stderr.log >&2 2>/dev/null || true
exit 1
