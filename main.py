import os, sys
os.chdir(os.path.dirname(os.path.abspath(sys.argv[0])) if getattr(sys, "frozen", False) else os.path.dirname(os.path.abspath(__file__)))
import tomllib, fnmatch
import requests
import httpx
from flask import Flask, request, Response, send_from_directory, abort, jsonify
from werkzeug.middleware.proxy_fix import ProxyFix

BLUE="\033[34m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

def colored_log(color, tag, text): print(f"{color}[{tag}]{RESET} {text}")

if not os.path.isfile("config.toml"):
    colored_log(RED, "ERROR", "config.toml not found, run setup.sh to configure")
    sys.exit(1)

with open("config.toml", "rb") as f:
    config=tomllib.load(f)

if config.get("version", 0)<1:
    colored_log(RED, "ERROR", "config.toml version is outdated, remove it and run setup.sh again")
    sys.exit(1)

upstream_session=requests.Session()
upstream_stream_client=None
stream_timeout=httpx.Timeout(connect=10.0, read=None, write=60.0, pool=60.0)
if config["upstream_proxy"]["enabled"] and config["upstream_proxy"]["url"]:
    proxy_url=config["upstream_proxy"]["url"]
    upstream_session.proxies.update({"http": proxy_url, "https": proxy_url})
    colored_log(BLUE, "INFO", f"Using upstream proxy: {proxy_url}")
    upstream_stream_client=httpx.Client(http2=True, proxy=proxy_url, follow_redirects=False, timeout=stream_timeout)
else: upstream_stream_client=httpx.Client(http2=True, follow_redirects=False, timeout=stream_timeout)

backend_url=config["backend"]["url"].rstrip("/")
uri_prefix=("/"+config["uri_prefix"]) if config.get("uri_prefix") else ""
managed_paths=config.get("paths", [])
frontend_mode=config["frontend"]["mode"]
frontend_directory=config["frontend"].get("directory", "")
frontend_url=config["frontend"].get("url", "").rstrip("/")
frontend_excluded=config["frontend"].get("excluded_paths", ["README.md", "LICENSE.md", ".nojekyll", ".git", "quickrun.js"])
error_text={"404": "not found", "405": "method not allowed", "400": "bad request", "413": "content too big", "415": "unsupported media type", "500": "internal server error"}

app=Flask(__name__, static_folder=None)
app.wsgi_app=ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1, x_prefix=1)
app.config["MAX_CONTENT_LENGTH"]=config["server"].get("max_content_length", 67108864)

HOP_BY_HOP={"connection","transfer-encoding","content-encoding","content-length","host","keep-alive","proxy-authenticate","proxy-authorization","te","trailers","upgrade"}

api_url=(uri_prefix or "")+"/api/v1/"
stream_path=(uri_prefix+"/api/v1/stream") if uri_prefix else "/api/v1/stream"

@app.errorhandler(404)
@app.errorhandler(405)
@app.errorhandler(400)
@app.errorhandler(413)
@app.errorhandler(415)
@app.errorhandler(500)
def error_handler(error):
    if request.path.startswith(uri_prefix):
        if request.path==api_url or (request.path+"/").startswith(api_url): return Response(f'{{"error":"{error_text[str(error.code)]}"}}', status=error.code, content_type="application/json")
        try: return (send_from_directory(frontend_directory, f"{error.code}.html"), error.code) if frontend_mode=="serve" and os.path.isdir(frontend_directory) else (error_text[str(error.code)], error.code)
        except: return error_text[str(error.code)], error.code
    return jsonify({"error": error_text[str(error.code)]}), error.code

def path_matches(pattern, path):
    if "*" not in pattern: return path==pattern or path.startswith(pattern+"/")
    pp=pattern.split("/")
    fp=path.split("/")
    if len(fp)<len(pp): return False
    return all(fnmatch.fnmatch(a, b) for a, b in zip(fp, pp))

def build_headers():
    headers={k: v for k, v in request.headers if k.lower() not in HOP_BY_HOP}
    if request.path==stream_path: headers["Accept-Encoding"]="identity"
    headers["X-Real-IP"]=request.remote_addr
    headers["X-Forwarded-For"]=request.remote_addr
    headers["X-Forwarded-Proto"]=request.scheme
    return headers

def proxy_to(url, max_size=0):
    if request.query_string:
        url=url+"?"+request.query_string.decode("utf-8", errors="replace")
    if max_size>0 and request.method in ["GET", "HEAD"]:
        try: head_resp=upstream_session.request(method="HEAD", url=url, headers=build_headers(), timeout=60, allow_redirects=False)
        except requests.RequestException as e:
            colored_log(RED, "ERROR", f"Upstream HEAD request failed: {e}")
            return Response('{"error":"backend unavailable"}', status=502, content_type="application/json")
        if head_resp.status_code<400:
            content_length=head_resp.headers.get("Content-Length", "").strip()
            if not content_length.isdigit():
                head_resp.close()
                return Response('{"error":"content size unavailable"}', status=502, content_type="application/json")
            if int(content_length)>max_size:
                head_resp.close()
                return Response('{"error":"content too large"}', status=413, content_type="application/json")
        if request.method=="HEAD":
            out_headers={k: v for k, v in head_resp.headers.items() if k.lower() not in HOP_BY_HOP}
            status_code=head_resp.status_code
            head_resp.close()
            return Response(status=status_code, headers=out_headers)
        head_resp.close()
    is_stream=request.path==stream_path
    if is_stream:
        colored_log(BLUE, "STREAM", f"Opening {request.method} {url}")
        req=upstream_stream_client.build_request(request.method, url, headers=build_headers(), content=request.get_data())
        try: resp=upstream_stream_client.send(req, stream=True)
        except httpx.HTTPError as e:
            colored_log(RED, "STREAM", f"Upstream stream failed: {e}")
            return Response('{"error":"backend unavailable"}', status=502, content_type="application/json")
        colored_log(BLUE, "STREAM", f"Upstream response {resp.status_code} via {resp.http_version}")
        out_headers={k: v for k, v in resp.headers.items() if k.lower() not in HOP_BY_HOP}
        out_headers["Cache-Control"]="no-cache"
        out_headers["X-Accel-Buffering"]="no"
        out_headers["Content-Type"]="text/event-stream"
        def generate_stream():
            first_chunk=True
            try:
                yield b": relay\n\n"
                for chunk in resp.iter_raw():
                    if chunk:
                        if first_chunk:
                            colored_log(BLUE, "STREAM", f"First chunk received ({len(chunk)} bytes)")
                            first_chunk=False
                        yield chunk
            except httpx.HTTPError as e: colored_log(RED, "STREAM", f"Stream interrupted: {e}")
            finally:
                resp.close()
                colored_log(BLUE, "STREAM", f"Closed {request.method} {url}")
        return Response(generate_stream(), status=resp.status_code, headers=out_headers, direct_passthrough=True)
    try:
        resp=upstream_session.request(method=request.method, url=url, headers=build_headers(), data=request.get_data(), stream=True, timeout=(10, None) if is_stream else (10, 60), allow_redirects=False)
    except requests.RequestException as e:
        colored_log(RED, "ERROR", f"Backend request failed: {e}")
        return Response('{"error":"backend unavailable"}', status=502, content_type="application/json")
    out_headers={k: v for k, v in resp.headers.items() if k.lower() not in HOP_BY_HOP}
    if is_stream or resp.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()=="text/event-stream":
        out_headers["Cache-Control"]="no-cache"
        out_headers["X-Accel-Buffering"]="no"
    def generate():
        try:
            for chunk in resp.iter_content(chunk_size=1 if is_stream else None):
                if chunk: yield chunk
        finally: resp.close()
    return Response(generate(), status=resp.status_code, headers=out_headers, direct_passthrough=True)

def proxy_no_files(url):
    if "multipart/form-data" in (request.content_type or ""):
        if any(f.filename for f in request.files.values()):
            return Response('{"error":"file uploads are not allowed"}', status=403, content_type="application/json")
        if request.query_string:
            url=url+"?"+request.query_string.decode("utf-8", errors="replace")
        headers=build_headers()
        del headers["Content-Type"]
        form_data=[(k, v) for k, vals in request.form.to_dict(flat=False).items() for v in vals]
        try:
            resp=upstream_session.request(method=request.method, url=url, headers=headers, data=form_data, timeout=60, allow_redirects=False)
        except requests.RequestException as e:
            colored_log(RED, "ERROR", f"Backend request failed: {e}")
            return Response('{"error":"backend unavailable"}', status=502, content_type="application/json")
        out_headers={k: v for k, v in resp.headers.items() if k.lower() not in HOP_BY_HOP}
        return Response(resp.content, status=resp.status_code, headers=out_headers)
    return proxy_to(url)

@app.route("/", defaults={"path": ""}, methods=["GET","POST","PUT","PATCH","DELETE","OPTIONS","HEAD"])
@app.route("/<path:path>", methods=["GET","POST","PUT","PATCH","DELETE","OPTIONS","HEAD"])
def catch_all(path):
    full_path="/"+path
    for p in managed_paths:
        if not path_matches(uri_prefix+p["prefix"], full_path): continue
        allowed_methods=p.get("methods")
        if allowed_methods and request.method not in [m.upper() for m in allowed_methods]: continue
        action=p["action"]
        if action=="proxy":
            target=backend_url+full_path
            if p.get("block_files"): return proxy_no_files(target)
            return proxy_to(target, max_size=p.get("max_size", 0))
        if action=="block": return Response('{"error":"forbidden"}', status=403, content_type="application/json")
        if action=="redirect": return Response(status=p.get("code", 301), headers={"Location": p.get("target","/")})
    if frontend_mode=="disabled": abort(404)
    if frontend_mode=="forward": return proxy_to(frontend_url+full_path)
    if frontend_mode=="serve":
        if not os.path.isdir(frontend_directory): abort(404)
        rel=full_path[len(uri_prefix):] if uri_prefix and full_path.startswith(uri_prefix) else full_path
        rel=rel.lstrip("/") or "index.html"
        if rel.split("/")[0] in frontend_excluded: abort(404)
        if "." not in rel.split("/")[-1]: rel+=".html"
        try: return send_from_directory(frontend_directory, rel)
        except: abort(404)
    abort(404)

colored_log(BLUE, "INFO", f"Backend: {backend_url}")
if frontend_mode=="serve":
    if os.path.isdir(frontend_directory): colored_log(BLUE, "INFO", f"Frontend: serving static files from {frontend_directory}")
    else: colored_log(RED, "ERROR", f"Frontend directory not found: {frontend_directory}")
elif frontend_mode=="forward": colored_log(BLUE, "INFO", f"Frontend: forwarding to {config['frontend']['url']}")
else: colored_log(BLUE, "INFO", "Frontend: disabled")
colored_log(BLUE, "INFO", f"Relay listening at http://{config['server']['host']}:{config['server']['port']}/")

try:
    from waitress import serve
    serve(app, host=config["server"]["host"], port=config["server"]["port"], threads=config["server"]["threads"])
except KeyboardInterrupt: pass
finally: colored_log(BLUE, "LOG", "Exiting...")
