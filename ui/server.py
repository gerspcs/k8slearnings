#!/usr/bin/env python3
"""Live view for the lab: BPMN on the left, cluster resources on the right, kept in sync.

Standard library only. Listens on 127.0.0.1 and runs a FIXED set of kubectl commands:
  reads : get pipelineruns/taskruns/pods, logs of pods it has listed
  writes: only three demo actions (start a run, start a signed/unsigned/foreign test pod, remove the test pods)
It never sends credentials or secrets to the browser.

Run from the repo root:  python3 ui/server.py   (or: scripts/bootstrap.sh ui)
"""
import base64, hashlib, http.server, json, os, re, secrets, socket, socketserver, ssl, subprocess, threading, time, urllib.error, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI = os.path.join(ROOT, "ui")
PORT = int(os.environ.get("UI_PORT", "8099"))
NS_BUILD, NS_APPS = "sdlc-build", "sdlc-apps"
WATCH_NS = ["sdlc-build", "harbor", "tekton-pipelines", "projectcontour", "kyverno", "cert-manager", "sdlc-apps"]
TOKEN = secrets.token_urlsafe(16)                       # required on every POST (stops other web pages driving the demo)
ALLOWED_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}   # blocks DNS-rebinding
REC_FILE = os.path.join(UI, "recordings", "last-run.json")
STATIC = {"/": ("index.html", "text/html"), "/app.js": ("app.js", "text/javascript"), "/style.css": ("style.css", "text/css"),
          "/story.json": ("story.json", "application/json"), "/sample-recording.json": ("sample-recording.json", "application/json"),
          "/diagram.svg": (os.path.join("..", "docs", "artifact-lifecycle.svg"), "image/svg+xml")}

# ---------- helpers
def sh(args, timeout=15, stdin=None):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, input=stdin, cwd=ROOT)
        return r.returncode, r.stdout, r.stderr
    except Exception as e:
        return 1, "", str(e)

def kget(args):
    rc, out, _ = sh(["kubectl"] + args + ["-o", "json"])
    try:
        return json.loads(out)["items"] if rc == 0 else None
    except Exception:
        return None

def short(d): return (d or "")[:19]

# ---------- Harbor evidence (least-privilege robot account, read-only; creds stay in this process)
_harbor = {"auth": None, "at": 0, "cache": {}, "cache_at": 0}
orig_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda h, *a, **k: orig_getaddrinfo("127.0.0.1" if h == "harbor.local" else h, *a, **k)

def harbor_get(path):
    ca = os.path.join(ROOT, "infra", "cert-manager", "sdlc-ca.crt")
    if not os.path.exists(ca): return None
    for attempt in (0, 1):
        if not _harbor["auth"] or attempt == 1:
            rc, out, _ = sh(["kubectl", "-n", NS_BUILD, "get", "secret", "harbor-robot", "-o", "json"])
            try:
                cfg = json.loads(base64.b64decode(json.loads(out)["data"][".dockerconfigjson"]))
                _harbor["auth"] = cfg["auths"]["harbor.local:9443"]["auth"]
            except Exception:
                return None
        req = urllib.request.Request("https://harbor.local:9443/api/v2.0" + path, headers={"Authorization": "Basic " + _harbor["auth"]})
        try:
            return json.load(urllib.request.urlopen(req, context=ssl.create_default_context(cafile=ca), timeout=6))
        except urllib.error.HTTPError as e:
            if e.code in (401, 403) and attempt == 0: continue   # robot is rotated by the pipeline stage: reload once
            return None
        except Exception:
            return None
    return None

def evidence():
    if time.time() - _harbor["cache_at"] < 3: return _harbor["cache"]
    ev = {}
    for repo in ("sample-app", "unsigned-demo"):
        arts = harbor_get(f"/projects/poc/repositories/{repo}/artifacts?with_accessory=true&page_size=20&sort=-push_time")
        if arts is None: continue
        ev[repo] = [{"digest": a["digest"], "tags": [t["name"] for t in (a.get("tags") or [])],
                     "signatures": len(a.get("accessories") or [])} for a in arts]
    _harbor["cache"], _harbor["cache_at"] = ev, time.time()
    return ev

def pick_digest(kind):
    ev = evidence()
    if kind == "signed":
        c = [a for a in ev.get("sample-app", []) if a["signatures"] and a["tags"]] or [a for a in ev.get("sample-app", []) if a["signatures"]]
        return ("harbor.local:9443/poc/sample-app@" + c[0]["digest"]) if c else None
    if kind == "unsigned":
        c = [a for a in ev.get("unsigned-demo", []) if not a["signatures"]]
        return ("harbor.local:9443/poc/unsigned-demo@" + c[0]["digest"]) if c else None
    if kind == "foreign":
        return "docker.io/library/busybox:1.36"
    return None

# ---------- state
admission = {"phase": "idle", "kind": None, "message": "", "image": "", "run": None}
lock = threading.Lock()

def cond(obj):
    c = (obj.get("status", {}).get("conditions") or [{}])[0]
    return c.get("status"), c.get("reason", "")

def build_state():
    prs, trs, pods = kget(["-n", NS_BUILD, "get", "pipelinerun"]), kget(["-n", NS_BUILD, "get", "taskrun"]), kget(["get", "pods", "-A"])
    if prs is None or pods is None:
        return {"ok": False, "error": "cluster not reachable (is kubectl pointed at kind-sdlc-poc?)"}
    run = None
    if prs:
        pr = sorted(prs, key=lambda x: x["metadata"]["creationTimestamp"])[-1]
        st, reason = cond(pr)
        run = {"name": pr["metadata"]["name"], "status": {"True": "Succeeded", "False": "Failed"}.get(st, "Running"), "reason": reason,
               "started": pr["metadata"]["creationTimestamp"], "finished": pr.get("status", {}).get("completionTime"), "tasks": {}, "digest": None}
        for tr in trs or []:
            if tr["metadata"].get("labels", {}).get("tekton.dev/pipelineRun") != run["name"]: continue
            tname = tr["metadata"]["labels"].get("tekton.dev/pipelineTask")
            s, r = cond(tr)
            run["tasks"][tname] = {"status": {"True": "done", "False": "failed"}.get(s, "active"), "reason": r,
                                   "pod": tr.get("status", {}).get("podName"), "started": tr.get("status", {}).get("startTime"),
                                   "finished": tr.get("status", {}).get("completionTime")}
            for res in tr.get("status", {}).get("results") or []:
                if tname == "build-push" and res["name"] == "digest": run["digest"] = res["value"]
    out_pods = []
    for p in pods:
        ns = p["metadata"]["namespace"]
        if ns not in WATCH_NS: continue
        lab = p["metadata"].get("labels", {})
        task = lab.get("tekton.dev/pipelineTask")
        if ns == NS_BUILD and not (run and lab.get("tekton.dev/pipelineRun") == run["name"]): continue   # only the current run
        cs = p["status"].get("containerStatuses") or []
        out_pods.append({"name": p["metadata"]["name"], "ns": ns, "phase": p["status"].get("phase", "Unknown"), "task": task,
                         "ready": f"{sum(1 for c in cs if c.get('ready'))}/{len(cs) or len(p['spec']['containers'])}",
                         "restarts": sum(c.get("restartCount", 0) for c in cs), "started": p["status"].get("startTime"),
                         "deleting": bool(p["metadata"].get("deletionTimestamp"))})
    out_pods.sort(key=lambda x: (x["ns"], x["name"]))
    # ---- BPMN step states
    S = {k: "idle" for k in ["start", "commit", "build", "sbom", "scan", "gw1", "reject", "sign", "store", "req", "gw2", "ok", "blocked"]}
    dec = {"gw1": None, "gw2": None}
    if run:
        T = run["tasks"]; g = lambda n: T.get(n, {}).get("status", "idle")
        S.update(start="done", commit="done", build=g("build-push"), sbom=g("sbom"), scan=g("vuln-scan"), sign=g("sign-attest"), store=g("verify"))
        if g("vuln-scan") == "done": S["gw1"], dec["gw1"] = "done", "no"
        elif g("vuln-scan") == "failed": S["gw1"], S["reject"], dec["gw1"] = "done", "failed", "yes"
    a = admission
    if run and a["run"] not in (None, run["name"]): a.update(phase="idle", kind=None, message="", image="", run=None)
    if a["phase"] != "idle":
        S["req"] = "active" if a["phase"] == "running" else "done"
        S["gw2"] = "active" if a["phase"] == "running" else "done"
        if a["phase"] == "admitted": S["ok"], dec["gw2"] = "done", "yes"
        if a["phase"] == "denied": S["blocked"], dec["gw2"] = "failed", "no"
    return {"ok": True, "run": run, "pods": out_pods, "steps": S, "decisions": dec, "admission": dict(a),
            "evidence": evidence(), "kube_system_pods": sum(1 for p in pods if p["metadata"]["namespace"] == "kube-system")}

# ---------- broadcaster + recording
cv = threading.Condition()
current = {"state": {"ok": False, "error": "starting"}, "version": 0, "hash": ""}
rec = {"t0": time.time(), "frames": [], "run": None, "saved": 0}

def poller():
    while True:
        try:
            with lock: st = build_state()
        except Exception as e:
            st = {"ok": False, "error": str(e)}
        h = hashlib.sha1(json.dumps(st, sort_keys=True).encode()).hexdigest()
        if h != current["hash"]:
            with cv:
                current.update(state=st, hash=h, version=current["version"] + 1)
                cv.notify_all()
            record(st)
        time.sleep(1.0)

def record(st):
    run = (st.get("run") or {}).get("name")
    if run and run != rec["run"]:
        rec.update(t0=time.time(), frames=[], run=run)
    if run or st.get("admission", {}).get("phase", "idle") != "idle":
        rec["frames"].append({"t": round(time.time() - rec["t0"], 2), "s": st}); rec["frames"] = rec["frames"][-900:]
        if time.time() - rec["saved"] > 2:
            try:
                os.makedirs(os.path.dirname(REC_FILE), exist_ok=True)
                with open(REC_FILE, "w") as f: json.dump({"frames": rec["frames"]}, f)
                rec["saved"] = time.time()
            except Exception: pass

# ---------- actions
def action(name, kind=None):
    global admission
    if name == "start":
        rc, out, err = sh(["kubectl", "-n", NS_BUILD, "create", "-f", "pipelines/pipelinerun.yaml", "-o", "name"])
        admission.update(phase="idle", kind=None, message="", image="", run=None)
        return {"ok": rc == 0, "message": (out or err).strip()[:200]}
    if name == "reset":
        sh(["kubectl", "-n", NS_APPS, "delete", "pods", "--all", "--grace-period=1", "--wait=false"])
        admission.update(phase="idle", kind=None, message="", image="", run=None)
        return {"ok": True, "message": "demo pods removed"}
    if name == "deploy" and kind in ("signed", "unsigned", "foreign"):
        img = pick_digest(kind)
        if not img: return {"ok": False, "message": "image not available yet (run the pipeline first)"}
        run = (current["state"].get("run") or {}).get("name")
        admission.update(phase="running", kind=kind, message="", image=short_image(img), run=run)
        pod = "demo-%s-%s" % (kind, secrets.token_hex(2))
        rc, out, err = sh(["kubectl", "-n", NS_APPS, "run", pod, "--image=" + img, "--restart=Never", "--command", "--", "sh", "-c", "echo hello from a verified artifact; sleep 600"], timeout=60)
        msg = re.sub(r"^Error from server[^:]*: admission webhook \"[^\"]+\" denied the request: ", "", (err or out).strip())
        admission.update(phase="admitted" if rc == 0 else "denied", message=msg[:300])
        return {"ok": True, "outcome": admission["phase"], "message": admission["message"]}
    return {"ok": False, "message": "unknown action"}

def short_image(img):
    return re.sub(r"@sha256:([0-9a-f]{12})[0-9a-f]+", r"@sha256:\1…", img)

def logs_for(ns, pod):
    st = current["state"]
    if not any(p["name"] == pod and p["ns"] == ns for p in st.get("pods", [])): return "pod not in the current view"
    rc, out, err = sh(["kubectl", "-n", ns, "logs", pod, "--all-containers=true", "--prefix=true", "--tail=40"], timeout=15)
    return out if rc == 0 else err

# ---------- HTTP
class H(http.server.BaseHTTPRequestHandler):
    server_version = "lab-ui"
    def log_message(self, *a): pass
    def _ok_host(self): return self.headers.get("Host", "") in ALLOWED_HOSTS
    def _send(self, code, body, ctype="application/json"):
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype + "; charset=utf-8"); self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store"); self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if not self._ok_host(): return self._send(403, b'{"error":"bad host"}')
        path, _, q = self.path.partition("?")
        if path in STATIC:
            fn, ct = STATIC[path]
            try:
                data = open(os.path.join(UI, fn), "rb").read()
            except FileNotFoundError:
                return self._send(404, b'{"error":"not found"}')
            if path == "/": data = data.replace(b"__TOKEN__", TOKEN.encode())
            return self._send(200, data, ct)
        if path == "/api/state": return self._send(200, json.dumps(current["state"]))
        if path == "/api/recording":
            return self._send(200, json.dumps({"frames": rec["frames"]}) if rec["frames"] else (open(REC_FILE).read() if os.path.exists(REC_FILE) else '{"frames":[]}'))
        if path == "/api/logs":
            m = re.fullmatch(r"ns=([a-z0-9-]+)&pod=([a-z0-9.-]+)", q)
            return self._send(200, json.dumps({"log": logs_for(m.group(1), m.group(2)) if m else "bad request"}))
        if path == "/api/events": return self._sse()
        self._send(404, b'{"error":"not found"}')
    def _sse(self):
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-store"); self.end_headers()
        seen = -1
        try:
            while True:
                with cv:
                    if current["version"] == seen: cv.wait(timeout=15)
                    v, st = current["version"], current["state"]
                if v != seen:
                    self.wfile.write(("data: " + json.dumps(st) + "\n\n").encode()); seen = v
                else:
                    self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except Exception:
            return
    def do_POST(self):
        if not self._ok_host() or self.headers.get("X-UI-Token") != TOKEN: return self._send(403, b'{"error":"forbidden"}')
        m = re.fullmatch(r"/api/action/(start|reset|deploy)(?:/(signed|unsigned|foreign))?", self.path)
        if not m: return self._send(404, b'{"error":"unknown action"}')
        with lock: res = action(m.group(1), m.group(2))
        with cv: current["hash"] = ""            # force a fresh broadcast on the next poll
        self._send(200, json.dumps(res))

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

if __name__ == "__main__":
    threading.Thread(target=poller, daemon=True).start()
    srv = Server(("127.0.0.1", PORT), H)
    print(f"Lab UI: open http://localhost:{PORT}  (loopback only; Ctrl+C to stop)", flush=True)
    try: srv.serve_forever()
    except KeyboardInterrupt: pass
