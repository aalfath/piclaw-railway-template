[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/piclaw?utm_medium=integration&utm_source=button&utm_campaign=piclaw)

# PiClaw on Railway

One-click [PiClaw](https://github.com/rcarmo/piclaw) for [Railway](https://railway.com): a self-hosted web workspace for the [Pi coding agent](https://github.com/earendil-works/pi), with chat, a file browser and editor, and a terminal in the browser.

- **Version:** PiClaw **3.3.4**, official image `ghcr.io/rcarmo/piclaw:v3.3.4@sha256:2106ba6e7421053095e7092d81adabf962e5b5336be61fffe916569fc03e6d57`, behind Caddy **2.11.9** (`caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0`).
- **Login:** a fresh PiClaw instance has no login of its own, and the agent can run shell commands. So Caddy puts HTTP basic auth (user `piclaw`, generated `PICLAW_PASSWORD`) in front of everything except `/healthz`. The container refuses to start without a password of 12+ characters. You can add PiClaw's own TOTP or passkey login later (`/totp` in the chat).
- **Model:** set `LLM_API_KEY` (and, for a provider other than OpenAI, `LLM_BASE_URL` and `LLM_MODEL`). On every start the service writes an "OpenAI-compatible" provider into Pi's `models.json` that reads the key from the environment, so the key is never stored on the volume. If you set up a provider with `/login` in the chat instead, the service leaves it alone.
- **Data:** one volume at `/workspace` holds the workspace files, PiClaw's database (`/workspace/.piclaw/store/messages.db`: chats, tasks, settings) and the Pi profile (`/workspace/.home`, linked as `/config`).
- **Restarts:** PiClaw runs under upstream's supervisord. If supervisord, Caddy, or PiClaw itself stops for good (supervisord gives up after repeated crashes), the container exits 1, so Railway's on-failure restart policy brings it back.
- **Memory:** about 230 MB at idle; it runs on a 0.5 GB service. Give it 1 GB or more if the agent builds or runs heavy code in its terminal.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `LLM_API_KEY` | required | API key for your model provider, e.g. from https://platform.openai.com/api-keys or https://openrouter.ai/keys. |
| `LLM_BASE_URL` | `https://api.openai.com/v1` | Any OpenAI-compatible API (OpenRouter `https://openrouter.ai/api/v1`, Groq, DeepSeek, a vLLM or Ollama server, ...). |
| `LLM_MODEL` | `gpt-5.4-mini` | Model ID at that provider; the default model for new chats. Add more with `LLM_EXTRA_MODELS` (comma-separated). |
| `PICLAW_PASSWORD` | `${{secret(24)}}` | Login password (user `piclaw`). Find it in the service's Variables tab. |
| `PICLAW_USERNAME` | `piclaw` | Login user name. |
| `PORT` | `8080` | Port Caddy listens on (Railway's public domain targets it). |

Optional: `LLM_CONTEXT_WINDOW` (default `128000`), `PICLAW_WEB_WORKSPACE_UPLOAD_LIMIT_MB` (default: memory limit / 8, at most 256).

## Limits

- PiClaw is single-user. Its experimental multi-user "family mode" is off.
- The agent runs as the container's `agent` user, which has passwordless `sudo` inside the container (upstream's design). Treat the service as the agent's sandbox: don't add secrets to it that the agent shouldn't see.
- No Docker-in-Docker, Tailscale or VNC desktop on Railway. There is no GPU; PiClaw calls the model provider you configure.

## Updates

Railway builds this service from this repo, so a merge to `main` that bumps the pinned image shows deployers an "update available" notice. Read [`CHANGELOG.md`](CHANGELOG.md) (breaking changes first) before applying it. Data stays on the volume.
