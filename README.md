# Parley Chat Relay

A lightweight reverse proxy for [Parley Chat](https://github.com/Parley-Chat) that sits in front of a Sova backend. It lets you control which paths are exposed, block unwanted routes, forward frontend requests, and route traffic through an upstream HTTP or SOCKS5 proxy.

## What it is

Relay is a Python application (Flask + Waitress) that accepts HTTP requests and forwards them to a configured Sova backend. It is designed to be the public-facing entry point for a Parley Chat deployment, replacing or supplementing the default nginx-only setup.

Key capabilities:

- **Managed paths** — each path prefix can independently be proxied to the backend, blocked (403), or redirected to another URL
- **Frontend handling** — serve the Mura frontend from a local directory, forward to a separate URL, or disable non-API routes entirely
- **Upstream proxy** — route all outbound backend requests through an HTTP or SOCKS5 proxy
- **SSE streaming** — the `/api/v1/stream` endpoint is proxied with full Server-Sent Events streaming support
- **nginx + SSL** — the installer sets up its own nginx reverse proxy with Let's Encrypt or self-signed certificates

## Installation

Download and run the installer:

```bash
wget -qO install.sh https://github.com/Parley-Chat/relay/releases/latest/download/install.sh && sudo bash install.sh
```

Or with curl:

```bash
curl -fsSL https://github.com/Parley-Chat/relay/releases/latest/download/install.sh | sudo bash
```

The script will walk you through:

1. Domain or IP address
2. URI path prefix (must match the `uri_prefix` value in your Sova `config.toml`)
3. Sova backend URL (e.g. `http://127.0.0.1:42836`)
4. Install directory
5. Thread count
6. nginx reverse proxy (optional) with SSL certificate choice
7. Upstream proxy (optional)
8. Frontend mode

It installs Python dependencies, writes `config.toml`, creates systemd services (`parley-relay` and optionally `parley-relay-nginx`), and starts everything.

To uninstall:

```bash
sudo bash install.sh
# choose [X] Uninstall
```

## Configuration reference

The relay reads `config.toml` from its working directory. All fields:

```toml
version = 1

# Must match Sova's uri_prefix. Leave empty if Sova has no prefix.
uri_prefix = "your20charprefix"

[server]
    host = "127.0.0.1"   # Bind address
    port = 7861           # Bind port
    threads = 16          # Waitress worker threads
    max_content_length = 67108864  # Max request body size in bytes (64 MB)

[backend]
    url = "http://127.0.0.1:42836"  # Sova backend URL

[upstream_proxy]
    enabled = false
    url = ""  # e.g. "socks5://user:pass@host:1080" or "http://proxy:3128"

[frontend]
    # "serve"    — serve static files from `directory`
    # "forward"  — proxy all non-API requests to `url`
    # "disabled" — return 404 for all non-API routes
    mode = "serve"
    directory = "/opt/parley-relay/mura"
    url = ""  # used when mode = "forward"

# Managed paths — checked in order, first prefix+method match wins.
# action: "proxy", "block", or "redirect"
# methods: optional list — omit to match all methods
# block_files: optional bool (action="proxy" only) — reject multipart requests
#              that contain file uploads (403), but proxy plain form posts through
# For "redirect": target = "https://example.com"
#                 code = 301 (default), 302, 307, or 308

[[paths]]
    prefix = "/api/v1"
    action = "proxy"

[[paths]]
    prefix = "/pfp"
    action = "proxy"

[[paths]]
    prefix = "/attachment"
    action = "proxy"

[[paths]]
    prefix = "/health"
    action = "proxy"
```

## Managed paths

Managed paths let you control what the relay does with each incoming route before it reaches the frontend handler.

Each entry has a `prefix` (matched against the full request path, after prepending `uri_prefix`) and an `action`:

| Action | Behaviour |
|--------|-----------|
| `proxy` | Forward the request to the Sova backend and stream the response back |
| `block` | Return 403 Forbidden with a JSON error body |
| `redirect` | Redirect to the URL in `target` using the status code in `code` (default 301) |

Each entry also accepts an optional `methods` list. When present, the rule only applies if the request method is in that list. Rules without `methods` match all methods. This allows multiple rules for the same prefix with different per-method behaviour.

Paths are checked **in order** — the first matching prefix+method combination wins. A prefix matches if the request path equals the prefix exactly or starts with `prefix + "/"`.

### Wildcard matching

`*` can be used anywhere in a prefix to match any string within a single path segment:

| Pattern | Matches | Does not match |
|---------|---------|----------------|
| `/api/v1/channel/*/messages` | `/api/v1/channel/abc123/messages` | `/api/v1/channel/messages` |
| `/api/v1/channel/a*a/messages` | `/api/v1/channel/abca/messages` | `/api/v1/channel/abc/messages` |
| `/api/v1/channel/*/messages` | `/api/v1/channel/abc/messages/ack` (sub-path) | `/api/v1/channel/abc/other` |

Wildcards only expand within their segment — they do not cross `/`. A wildcard pattern still behaves as a prefix: if the path continues past the pattern, it still matches.

```toml
# Block message sending only on a specific channel
[[paths]]
    prefix = "/api/v1/channel/announcements-*/messages"
    methods = ["POST"]
    action = "block"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

The default managed paths correspond to Sova's actual routes:

| Prefix | Purpose |
|--------|---------|
| `/api/v1` | All REST API endpoints (auth, channels, messages, members, keys, pins, calls) |
| `/pfp` | Profile picture file serving |
| `/attachment` | Message attachment file serving |
| `/health` | Health check endpoint |

Any request that does not match a managed path is handled by the frontend mode setting.

### Example: block the health endpoint

```toml
[[paths]]
    prefix = "/health"
    action = "block"
```

### Example: redirect old path

The `code` field controls the redirect status. Supported codes:

| Code | Meaning |
|------|---------|
| `301` | Permanent — browser caches the redirect, future requests skip this server; method may change to GET |
| `302` | Temporary — not cached; method may change to GET |
| `307` | Temporary — not cached; **preserves the original method** (POST stays POST) |
| `308` | Permanent — cached; **preserves the original method** |

```toml
[[paths]]
    prefix = "/old-api"
    action = "redirect"
    target = "https://example.com/new-api"
    # code = 301   ← default, omit or set explicitly

[[paths]]
    prefix = "/beta"
    action = "redirect"
    target = "https://example.com/beta-new"
    code = 302

[[paths]]
    prefix = "/api/v1/upload"
    action = "redirect"
    target = "https://upload.example.com/api/v1/upload"
    code = 307   # preserve POST body and method
```

## Granular API control

The `methods` field lets you apply different actions to different HTTP methods on the same path. Rules are checked in order — the first rule where both the prefix and the method match is used.

### Allow reads, block writes on a route

```toml
[[paths]]
    prefix = "/api/v1/channel"
    methods = ["POST", "PATCH", "DELETE"]
    action = "block"

[[paths]]
    prefix = "/api/v1/channel"
    # no methods — matches everything else (GET, OPTIONS, HEAD, ...)
    action = "proxy"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

With this config, `GET /api/v1/channel/<id>/messages` is proxied normally while `POST /api/v1/channel/<id>/messages` (sending a message) returns 403.

### Read-only instance

Block all write operations across the entire API:

```toml
[[paths]]
    prefix = "/api/v1"
    methods = ["POST", "PUT", "PATCH", "DELETE"]
    action = "block"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"

[[paths]]
    prefix = "/pfp"
    action = "proxy"

[[paths]]
    prefix = "/attachment"
    action = "proxy"

[[paths]]
    prefix = "/health"
    action = "proxy"
```

### Block only account creation and login

```toml
[[paths]]
    prefix = "/api/v1/signup"
    action = "block"

[[paths]]
    prefix = "/api/v1/login"
    action = "block"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

### Block SSE stream (disable real-time events)

```toml
[[paths]]
    prefix = "/api/v1/stream"
    action = "block"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

### Block voice calls

Sova's call routes are `POST/DELETE /api/v1/channel/<id>/call` and `POST /api/v1/channel/<id>/call/signal`. Using a wildcard targets them precisely without touching message routes:

```toml
[[paths]]
    prefix = "/api/v1/channel/*/call"
    action = "block"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

`/api/v1/channel/*/call` matches the call endpoint exactly and as a prefix, so `/api/v1/channel/<id>/call/signal` is also blocked.

## Controlling file access

### Block attachment downloads

Attachment files are served from `GET /attachment/<file_id>`. To prevent clients from downloading any attachment:

```toml
[[paths]]
    prefix = "/attachment"
    action = "block"
```

### Block profile picture access

Profile pictures are served from `GET /pfp/<pfp_id>`. To block all profile picture serving:

```toml
[[paths]]
    prefix = "/pfp"
    action = "block"
```

### Block all file downloads

Put both blocks before the `/api/v1` proxy rule so they are matched first:

```toml
[[paths]]
    prefix = "/attachment"
    action = "block"

[[paths]]
    prefix = "/pfp"
    action = "block"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"

[[paths]]
    prefix = "/health"
    action = "proxy"
```

### Block file uploads

In Sova, file uploads are not a separate endpoint — they are embedded inside regular API calls as multipart form data:

- **Message attachments** are uploaded via `POST /api/v1/channel/<channel_id>/messages` (same endpoint as plain text messages, with an additional `files` field)
- **Profile pictures** are uploaded via `PATCH /api/v1/me` (same endpoint as display name changes, with an optional `pfp` field)

Use `block_files = true` on a proxy rule to inspect the multipart body: if the request contains file parts, it is rejected with 403; if it is a plain form post (text message, display name change), it is proxied through normally.

**Block attachment uploads while allowing plain text messages:**

```toml
[[paths]]
    prefix = "/api/v1/channel"
    methods = ["POST"]
    action = "proxy"
    block_files = true

[[paths]]
    prefix = "/api/v1/channel"
    action = "proxy"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

**Block profile picture uploads while allowing display name changes:**

```toml
[[paths]]
    prefix = "/api/v1/me"
    methods = ["PATCH"]
    action = "proxy"
    block_files = true

[[paths]]
    prefix = "/api/v1/me"
    action = "proxy"

[[paths]]
    prefix = "/api/v1"
    action = "proxy"
```

**Block all uploads and all downloads:**

```toml
[[paths]]
    prefix = "/attachment"
    action = "block"

[[paths]]
    prefix = "/pfp"
    action = "block"

[[paths]]
    prefix = "/api/v1/channel"
    methods = ["POST"]
    action = "proxy"
    block_files = true

[[paths]]
    prefix = "/api/v1/me"
    methods = ["PATCH"]
    action = "proxy"
    block_files = true

[[paths]]
    prefix = "/api/v1"
    action = "proxy"

[[paths]]
    prefix = "/health"
    action = "proxy"
```

## Manual startup

```bash
pip3 install -r requirements.txt
python3 main.py
```

`config.toml` must exist in the same directory as `main.py`.

## License

MIT
