import os, sys
os.chdir(os.path.dirname(os.path.abspath(sys.argv[0])) if getattr(sys, "frozen", False) else os.path.dirname(os.path.abspath(__file__)))
import tomllib, fnmatch
import requests
from flask import Flask, request, Response, send_from_directory, abort
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
if config["upstream_proxy"]["enabled"] and config["upstream_proxy"]["url"]:
    proxy_url=config["upstream_proxy"]["url"]
    upstream_session.proxies.update({"http": proxy_url, "https": proxy_url})
    colored_log(BLUE, "INFO", f"Using upstream proxy: {proxy_url}")

backend_url=config["backend"]["url"].rstrip("/")
uri_prefix=("/"+config["uri_prefix"]) if config.get("uri_prefix") else ""
managed_paths=config.get("paths", [])
frontend_mode=config["frontend"]["mode"]
frontend_directory=config["frontend"].get("directory", "")
frontend_url=config["frontend"].get("url", "").rstrip("/")

app=Flask(__name__, static_folder=None)
app.wsgi_app=ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1, x_prefix=1)
app.config["MAX_CONTENT_LENGTH"]=config["server"].get("max_content_length", 67108864)

HOP_BY_HOP={"connection","transfer-encoding","content-encoding","content-length","host","keep-alive","proxy-authenticate","proxy-authorization","te","trailers","upgrade"}

def path_matches(pattern, path):
    if "*" not in pattern: return path==pattern or path.startswith(pattern+"/")
    pp=pattern.split("/")
    fp=path.split("/")
    if len(fp)<len(pp): return False
    return all(fnmatch.fnmatch(a, b) for a, b in zip(fp, pp))

def build_headers():
    headers={k: v for k, v in request.headers if k.lower() not in HOP_BY_HOP}
    headers["X-Real-IP"]=request.remote_addr
    headers["X-Forwarded-For"]=request.remote_addr
    headers["X-Forwarded-Proto"]=request.scheme
    return headers

def proxy_to(url, stream=False):
    if request.query_string:
        url=url+"?"+request.query_string.decode("utf-8", errors="replace")
    try:
        resp=upstream_session.request(method=request.method, url=url, headers=build_headers(), data=request.get_data(), stream=stream, timeout=(10, None) if stream else 60, allow_redirects=False)
    except requests.RequestException as e:
        colored_log(RED, "ERROR", f"Backend request failed: {e}")
        return Response('{"error":"backend unavailable"}', status=502, content_type="application/json")
    out_headers={k: v for k, v in resp.headers.items() if k.lower() not in HOP_BY_HOP}
    if stream:
        def generate():
            try:
                for chunk in resp.iter_content(chunk_size=None):
                    if chunk: yield chunk
            finally: resp.close()
        return Response(generate(), status=resp.status_code, headers=out_headers, direct_passthrough=True)
    return Response(resp.content, status=resp.status_code, headers=out_headers)

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
            return proxy_to(target, stream="text/event-stream" in request.headers.get("Accept",""))
        if action=="block": return Response('{"error":"forbidden"}', status=403, content_type="application/json")
        if action=="redirect": return Response(status=p.get("code", 301), headers={"Location": p.get("target","/")})
    if frontend_mode=="disabled": abort(404)
    if frontend_mode=="forward": return proxy_to(frontend_url+full_path)
    if frontend_mode=="serve":
        if not os.path.isdir(frontend_directory): abort(404)
        rel=full_path[len(uri_prefix):] if uri_prefix and full_path.startswith(uri_prefix) else full_path
        rel=rel.lstrip("/") or "index.html"
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
