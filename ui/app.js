/* Software Supply Chain Live: BPMN on top, the cluster underneath, kept in sync.
   Works in two ways: live (served by ui/server.py) or demo (any static server; replays a recorded run). */
(() => {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const mk = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const store = { get(k, d) { try { return localStorage.getItem(k) || d; } catch { return d; } }, set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } } };
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const TOKEN = document.querySelector('meta[name="ui-token"]').content;

  const ORDER = ["commit", "build", "sbom", "scan", "gw1", "sign", "store", "req", "gw2", "ok", "blocked", "reject"];
  const TASKS = ["build-push", "sbom", "vuln-scan", "sign-attest", "verify"];
  const COMP_ORDER = ["harbor", "tekton-pipelines", "projectcontour", "kyverno", "cert-manager", "sdlc-apps"];
  const STEP_OF_TASK = { "build-push": "build", sbom: "sbom", "vuln-scan": "scan", "sign-attest": "sign", verify: "store" };
  const ICON = { idle: "", active: "▶", done: "✓", failed: "✕" };

  let story, state = null, prev = null, mode = store.get("mode", "plain"), live = true, backend = false, hoverStep = null, focusStep = null;
  let replay = null;           // { frames, i, timer, speed }
  let latestLive = null;       // newest real state, kept while a replay is showing

  /* ---------- setup ---------- */
  async function getText(urls) { for (const u of urls) { try { const r = await fetch(u); if (r.ok) return await r.text(); } catch { /* try next */ } } throw new Error("missing " + urls[0]); }

  async function init() {
    story = JSON.parse(await getText(["story.json"]));
    try { const r = await fetch("api/state"); backend = r.ok; } catch { backend = false; }
    $("#bpmn").innerHTML = await getText(backend ? ["diagram.svg"] : ["../docs/artifact-lifecycle.svg", "diagram.svg"]);
    wireBpmn(); setMode(mode); setLayout(store.get("layout", innerWidth >= 2300 ? "side" : "stacked"));
    $("#m-plain").onclick = () => setMode("plain"); $("#m-tech").onclick = () => setMode("tech");
    $("#b-layout").onclick = () => setLayout(document.body.dataset.layout === "side" ? "stacked" : "side");
    $("#b-start").onclick = () => act("start"); $("#b-reset").onclick = () => act("reset");
    $("#b-signed").onclick = () => act("deploy/signed"); $("#b-unsigned").onclick = () => act("deploy/unsigned"); $("#b-foreign").onclick = () => act("deploy/foreign");
    $("#b-replay").onclick = () => (replay ? stopReplay() : startReplay());
    $("#logs-close").onclick = () => { $("#logs").hidden = true; };
    if (backend) connect(); else demoMode();
    updateButtons(); render();
  }

  function setMode(m) { mode = m; store.set("mode", m); document.body.dataset.mode = m; $("#m-plain").setAttribute("aria-pressed", m === "plain"); $("#m-tech").setAttribute("aria-pressed", m === "tech"); if (story) render(); }
  function setLayout(l) { document.body.dataset.layout = l; store.set("layout", l); }

  function banner(text) { const b = $("#banner"); b.hidden = !text; b.textContent = text || ""; }
  function toast(text, ms = 4500) { const t = $("#toast"); t.textContent = text; t.hidden = false; clearTimeout(toast.h); toast.h = setTimeout(() => { t.hidden = true; }, ms); }

  /* ---------- live connection ---------- */
  function connect() {
    const es = new EventSource("api/events");
    es.onmessage = (e) => { const s = JSON.parse(e.data); latestLive = s; if (live) apply(s); };
    es.onerror = () => { if (live) banner("Lost the connection to the lab server. Retrying…"); };
    es.onopen = () => { if (live) banner(""); };
  }
  async function demoMode() {
    live = false;
    const still = new URLSearchParams(location.search).get("frame");
    if (still !== null) { const fr = await loadFrames(); if (fr) { banner("Demo mode: a still from a recording of a real run."); apply(fr[Math.min(+still, fr.length - 1)].s, true); $("#s-kicker").textContent = "RECORDING · frame " + still; return; } }
    banner("Demo mode: you are watching a recording of a real run. To see it live, run the lab (see the README), then open this page from its server.");
    await startReplay(true);
  }

  async function act(path) {
    if (!backend) return toast("Actions need the live lab. This is a recording.");
    setBusy(true);
    try {
      const r = await fetch("api/action/" + path, { method: "POST", headers: { "X-UI-Token": TOKEN } });
      const j = await r.json();
      if (!j.ok) toast(j.message || "That did not work.");
    } catch { toast("Could not reach the lab server."); }
    setBusy(false);
  }
  function setBusy(b) { document.querySelectorAll(".controls button").forEach((x) => { x.dataset.busy = b ? "1" : ""; }); updateButtons(); }
  function updateButtons() {
    const s = state, run = s && s.run, ev = (s && s.evidence) || {};
    const canDeploy = backend && live && !!(ev["sample-app"] || []).some((a) => a.signatures);
    const busy = document.querySelector('.controls button[data-busy="1"]');
    $("#b-start").disabled = !backend || !live || !!busy || (run && run.status === "Running");
    $("#b-signed").disabled = !canDeploy || !!busy;
    $("#b-unsigned").disabled = !canDeploy || !!busy || !(ev["unsigned-demo"] || []).length;
    $("#b-foreign").disabled = !canDeploy || !!busy;
    $("#b-reset").disabled = !backend || !live || !!busy;
    $("#b-replay").textContent = replay ? "⏹ Back to live" : "⏵ Replay";
    $("#b-replay").disabled = false;
  }

  /* ---------- replay ---------- */
  async function loadFrames() {
    for (const u of backend ? ["api/recording", "sample-recording.json"] : ["sample-recording.json"]) {
      try { const r = await fetch(u); if (r.ok) { const j = await r.json(); if (j.frames && j.frames.length > 1) return j.frames; } } catch { /* next */ }
    }
    return null;
  }
  async function startReplay(auto) {
    const frames = await loadFrames();
    if (!frames) { toast("No recording yet. Start a build first, then replay it."); return; }
    live = false; replay = { frames, i: 0, speed: 1 }; prev = null; state = null;
    banner(auto ? $("#banner").textContent : "");
    step();
    updateButtons();
    function step() {
      if (!replay) return;
      const f = replay.frames[replay.i]; apply(f.s, true);
      $("#s-kicker").textContent = "REPLAY · " + (replay.i + 1) + " / " + replay.frames.length + " · " + replay.speed + "×";
      const nxt = replay.frames[replay.i + 1];
      if (!nxt) { replay.timer = setTimeout(() => { if (!replay) return; replay.i = 0; prev = null; step(); }, 4000); return; }   // loop
      const gap = Math.min(Math.max((nxt.t - f.t), 0.25), 3.0) / replay.speed * 1000;
      replay.timer = setTimeout(() => { if (replay) { replay.i++; step(); } }, gap);
    }
    $("#s-kicker").onclick = () => { if (replay) { replay.speed = replay.speed === 1 ? 4 : replay.speed === 4 ? 8 : 1; } };
  }
  function stopReplay() {
    if (replay) clearTimeout(replay.timer); replay = null;
    if (backend) { live = true; prev = null; banner(""); if (latestLive) apply(latestLive); } else { startReplay(true); }
    updateButtons();
  }

  /* ---------- rendering ---------- */
  function apply(s, fromReplay) { prev = state; state = s; render(fromReplay); }

  function flowState(src, tgt, S, dec) {
    if (S[src] !== "done") return "idle";
    if (src === "gw1" && dec.gw1 !== (tgt === "sign" ? "no" : "yes")) return "idle";
    if (src === "gw2" && dec.gw2 !== (tgt === "ok" ? "yes" : "no")) return "idle";
    const t = S[tgt]; return t === "active" ? "active" : (t === "done" || t === "failed") ? "done" : "idle";
  }

  function pickFocus(s) {
    if (!s || !s.ok) return null;
    const S = s.steps, a = s.admission || {};
    if (a.phase === "running") return "gw2";
    if (a.phase === "denied") return "blocked";
    if (a.phase === "admitted") return "ok";
    if (!s.run) return null;
    for (const k of ORDER) if (S[k] === "active") return k;
    if (S.reject === "failed") return "reject";
    for (const k of ["scan", "build", "sbom", "sign", "store"]) if (S[k] === "failed") return k;
    if (s.run.status === "Succeeded") return "done";
    for (const k of [...ORDER].reverse()) if (S[k] === "done") return k;
    return "commit";
  }

  function render(fromReplay) {
    if (!story) return;
    const s = state;
    if (!s || !s.ok) { $("#s-kicker").textContent = s ? "Waiting" : ""; $("#s-title").textContent = s ? "Cannot see the cluster" : "Loading…"; $("#s-plain").textContent = s ? (s.error || "") : ""; return; }
    focusStep = pickFocus(s);
    renderStory(s); renderBpmn(s, fromReplay); renderCluster(s); renderEvidence(s); updateButtons();
  }

  function renderStory(s) {
    const f = focusStep, box = $("#story");
    const c = f === null ? story.idle : f === "done" ? story.done : story.steps[f];
    if (!replay) $("#s-kicker").textContent = f === null || f === "done" ? "Ready" : "Right now";
    $("#s-title").textContent = c.title; $("#s-plain").textContent = c.plain; $("#s-tech").textContent = c.technical;
    box.classList.toggle("fail", f === "blocked" || f === "reject"); box.classList.toggle("good", f === "ok" || f === "done");
  }

  function wireBpmn() {
    document.querySelectorAll("#bpmn .node").forEach((n) => {
      const id = n.dataset.id;
      n.addEventListener("mouseenter", () => { hoverStep = id; highlight(); }); n.addEventListener("mouseleave", () => { hoverStep = null; highlight(); });
      n.addEventListener("click", () => { const t = story.steps[id] && story.steps[id].task; if (t) openLogsForTask(t); });
      const shape = n.querySelector("rect, polygon, circle"), bb = shape.getBBox(), b = document.createElementNS("http://www.w3.org/2000/svg", "text");
      const isTask = n.classList.contains("task");
      b.setAttribute("class", "badge"); b.setAttribute("x", isTask ? bb.x + bb.width - 4 : bb.x + bb.width + 12); b.setAttribute("y", isTask ? bb.y + 18 : bb.y + 6);
      b.setAttribute("text-anchor", isTask ? "end" : "start"); n.appendChild(b);
    });
  }

  function renderBpmn(s, fromReplay) {
    const S = s.steps, dec = s.decisions || {};
    document.querySelectorAll("#bpmn .node").forEach((n) => {
      const st = S[n.dataset.id] || "idle";
      n.setAttribute("class", n.getAttribute("class").replace(/\bst-\w+/g, "").trim() + " st-" + st);
      const b = n.querySelector(".badge"); if (b) { b.textContent = ICON[st]; b.style.fill = st === "done" ? "var(--ui-ok)" : st === "failed" ? "var(--ui-bad)" : "var(--accent)"; }
    });
    document.querySelectorAll("#bpmn .flow").forEach((f) => {
      const [, src, tgt] = f.dataset.id.split("_"); const st = flowState(src, tgt, S, dec);
      f.setAttribute("class", "flow fl-" + st);
    });
    if (prev && prev.ok && !reduceMotion) for (const id of Object.keys(S)) if (prev.steps[id] !== "done" && S[id] === "done") flyToken(id, S, dec);
    highlight();
  }

  function flyToken(src, S, dec) {
    document.querySelectorAll(`#bpmn .flow[data-id^="f_${src}_"]`).forEach((f) => {
      const [, , tgt] = f.dataset.id.split("_"); if (flowState(src, tgt, S, dec) === "idle") return;
      const path = f.querySelector("path"), len = path.getTotalLength(), svg = path.ownerSVGElement;
      const c = document.createElementNS("http://www.w3.org/2000/svg", "circle"); c.setAttribute("r", 9); c.setAttribute("class", "token"); svg.appendChild(c);
      const t0 = performance.now(), dur = 800;
      (function tick(t) { const k = Math.min((t - t0) / dur, 1), p = path.getPointAtLength(len * k); c.setAttribute("cx", p.x); c.setAttribute("cy", p.y); k < 1 ? requestAnimationFrame(tick) : c.remove(); })(t0);
    });
  }

  function highlight() {
    const step = hoverStep, touches = step && story.steps[step] ? story.steps[step].touches : [], task = step && story.steps[step] ? story.steps[step].task : null;
    document.querySelectorAll("#bpmn .node").forEach((n) => n.classList.toggle("hl", n.dataset.id === step));
    document.querySelectorAll(".task").forEach((t) => t.classList.toggle("hl", !!task && t.dataset.task === task));
    document.querySelectorAll(".tile").forEach((t) => t.classList.toggle("hl", !!task && t.dataset.task === task));
    const active = focusStep && story.steps[focusStep] ? story.steps[focusStep].touches : [];
    document.querySelectorAll(".comp").forEach((c) => c.classList.toggle("hot", (step ? touches : active).includes(c.dataset.ns)));
  }

  const nice = (name) => name.replace(/-[a-z0-9]{8,10}-[a-z0-9]{5}$/, "").replace(/-[a-z0-9]{5}$/, "");
  const dur = (a, b) => { if (!a || !b) return ""; const s = Math.max(0, Math.round((new Date(b) - new Date(a)) / 1000)); return s >= 60 ? Math.floor(s / 60) + "m " + (s % 60) + "s" : s + "s"; };

  function renderCluster(s) {
    const run = $("#run"); run.textContent = "";
    const head = mk("div", "runhead");
    if (s.run) { head.append(mk("b", null, mode === "tech" ? s.run.name : "This build"), mk("span", null, " · " + (s.run.status === "Succeeded" ? "finished in " + dur(s.run.started, s.run.finished) : s.run.status === "Failed" ? "stopped" : "running…"))); }
    else head.textContent = "No build yet. Press “Start a build”.";
    run.append(head);
    TASKS.forEach((t, i) => {
      const info = (s.run && s.run.tasks[t]) || null, st = info ? info.status : "idle";
      const d = mk("div", "task " + st); d.dataset.task = t; d.tabIndex = 0; d.setAttribute("role", "button");
      d.append(mk("div", "ic", ICON[st]), mk("div", "t", story.tasks[t][mode === "tech" ? "tech" : "plain"]),
        mk("div", "s", st === "idle" ? "waiting" : st === "active" ? "working…" : st === "done" ? "done " + dur(info.started, info.finished) : "failed"),
        mk("div", "pod", info && info.pod ? info.pod : ""));
      d.onmouseenter = () => { hoverStep = STEP_OF_TASK[t]; highlight(); }; d.onmouseleave = () => { hoverStep = null; highlight(); };
      d.onclick = () => openLogsForTask(t); d.onkeydown = (e) => { if (e.key === "Enter") openLogsForTask(t); };
      run.append(d); if (i < TASKS.length - 1) run.append(mk("span", "arrow", "→"));
    });
    const comps = $("#comps"); comps.textContent = "";
    for (const ns of COMP_ORDER) {
      const c = story.components[ns], pods = s.pods.filter((p) => p.ns === ns);
      const card = mk("div", "comp"); card.dataset.ns = ns;
      const ready = pods.filter((p) => p.phase === "Succeeded" || (p.phase === "Running" && p.ready.split("/")[0] === p.ready.split("/")[1])).length;
      const h = mk("h4", null, mode === "tech" ? c.tech : c.plain); h.append(mk("span", "cnt", pods.length ? ready + "/" + pods.length + " ready" : "empty"));
      card.append(h, mk("p", null, c.blurb));
      const tiles = mk("div", "tiles");
      for (const p of pods) {
        const ok = p.phase === "Running" && p.ready.split("/")[0] === p.ready.split("/")[1], bad = p.phase === "Failed" || p.restarts > 3;
        const t = mk("span", "tile " + (bad ? "bad" : ok ? "ok" : p.phase === "Succeeded" ? "ok" : "warn") + (p.deleting ? " deleting" : ""), nice(p.name));
        t.title = p.name + " · " + p.phase + " · " + p.ready; tiles.append(t);
      }
      card.append(tiles); comps.append(card);
    }
    highlight();
  }

  function renderEvidence(s) {
    const ev = $("#ev"); ev.textContent = ""; const S = s.steps, row = (k, v, cls) => { ev.append(mk("dt", null, k)); const d = mk("dd", cls || null); typeof v === "string" ? d.textContent = v : d.append(v); ev.append(d); };
    const sa = ((s.evidence || {})["sample-app"] || [])[0], digest = (s.run && s.run.digest) || (sa && sa.digest) || "";
    row(mode === "tech" ? "Image" : "The package", digest ? (mode === "tech" ? "harbor.local:9443/poc/sample-app@" + digest.slice(0, 19) + "…" : "sample-app, fingerprint " + digest.slice(7, 19) + "…") : "not built yet", digest ? "mono" : "");
    row(mode === "tech" ? "Safety scan (Trivy, CRITICAL gate)" : "Safety check", { idle: "—", active: "checking…", done: "passed: nothing critical found", failed: "STOPPED: a critical problem was found" }[S.scan]);
    row(mode === "tech" ? "Signatures stored in Harbor" : "Seals attached", !sa ? "—" : sa.signatures === 0 ? "none yet" : sa.signatures + (mode === "tech" ? " (signature + SBOM attestation)" : " (the seal and the ingredient list)"));
    row(mode === "tech" ? "cosign verify" : "Seal re-checked", { idle: "—", active: "checking…", done: "valid ✓", failed: "INVALID ✕" }[S.store]);
    const a = s.admission || {}, v = $("#verdict");
    v.hidden = a.phase === "idle" || !a.phase; if (!v.hidden) {
      const label = { signed: "signed package", unsigned: "unsigned package", foreign: "image from the public internet" }[a.kind] || "package";
      v.className = a.phase === "denied" ? "bad" : a.phase === "admitted" ? "good" : ""; v.textContent = "";
      v.append(mk("strong", null, a.phase === "running" ? "The cluster is checking the " + label + "…" : a.phase === "admitted" ? "ALLOWED: the " + label + " was started." : "BLOCKED: the " + label + " was refused."));
      if (a.message && mode === "tech" || a.phase === "denied") v.append(mk("code", null, "Kyverno says: " + (a.message || "")));
      if (a.image && mode === "tech") v.append(mk("code", null, a.image));
    }
  }

  async function openLogsForTask(task) {
    const info = state && state.run && state.run.tasks[task]; if (!info || !info.pod) return toast("That step has not started yet.");
    if (!backend || !live) return toast("Raw logs are only available in the live lab.");
    $("#logs-title").textContent = "Raw log · " + info.pod; $("#logs-body").textContent = "loading…"; $("#logs").hidden = false;
    try { const r = await fetch("api/logs?ns=sdlc-build&pod=" + encodeURIComponent(info.pod)); $("#logs-body").textContent = (await r.json()).log || "(empty)"; } catch { $("#logs-body").textContent = "could not load the log"; }
  }

  init().catch((e) => { $("#s-title").textContent = "Could not start the page"; $("#s-plain").textContent = String(e); });
})();
