"""Generates docs/artifact-lifecycle.bpmn (BPMN 2.0) and docs/artifact-lifecycle.svg from one model.
The SVG carries ids/classes (data-id) so ui/app.js can highlight steps live.
Run from the repo root: python3 docs/build_diagram.py"""
import html
LH, TOP, LEFT, POOLW = 170, 20, 30, 1900
lanes = [("L_dev","Developer"),("L_ci","CI pipeline (Tekton)"),("L_reg","Registry (Harbor)"),("L_run","Cluster (Kubernetes + Kyverno)")]
# id, kind, lane, cx, label, dy
N = [
 ("start","startEvent",0,120,"Code change\nneeded",0),
 ("commit","task",0,260,"Commit and push\nsource code",0),
 ("build","task",1,420,"Build container\nimage",0),
 ("sbom","task",1,580,"Generate SBOM\n(Syft)",0),
 ("scan","task",1,740,"Scan for known\nvulnerabilities\n(Trivy / Grype)",0),
 ("gw1","exclusiveGateway",1,900,"Critical\nfindings?",0),
 ("reject","endEvent",0,900,"Rejected:\nfix and recommit",0),
 ("sign","task",1,1070,"Sign image and\nrecord provenance\n(Cosign / Chains)",0),
 ("store","task",2,1230,"Store image, SBOM\nand signature\n(Harbor)",0),
 ("req","task",3,1390,"Request\ndeployment",0),
 ("gw2","exclusiveGateway",3,1550,"Signature\nvalid?\n(Kyverno)",0),
 ("ok","endEvent",3,1710,"Workload\nruns",0),
 ("blocked","endEvent",3,1550,"Deployment\nblocked",62),
]
F = [("start","commit",""),("commit","build",""),("build","sbom",""),("sbom","scan",""),("scan","gw1",""),
     ("gw1","sign","No"),("gw1","reject","Yes"),("sign","store",""),("store","req",""),("req","gw2",""),
     ("gw2","ok","Yes"),("gw2","blocked","No")]
size={"task":(130,76),"startEvent":(36,36),"endEvent":(36,36),"exclusiveGateway":(50,50)}
nd={}
for i,k,l,cx,lab,dy in N:
    w,h=size[k]; cy=TOP+l*LH+70+dy
    nd[i]=dict(id=i,kind=k,lane=l,cx=cx,cy=cy,w=w,h=h,label=lab)
def edge(s,t):
    a,b=nd[s],nd[t]
    if a["cy"]==b["cy"]:
        return [(a["cx"]+a["w"]/2,a["cy"]),(b["cx"]-b["w"]/2,b["cy"])]
    if a["cx"]==b["cx"]:
        if b["cy"]>a["cy"]: return [(a["cx"],a["cy"]+a["h"]/2),(b["cx"],b["cy"]-b["h"]/2)]
        return [(a["cx"],a["cy"]-a["h"]/2),(b["cx"],b["cy"]+b["h"]/2)]
    ty=b["cy"]-b["h"]/2 if b["cy"]>a["cy"] else b["cy"]+b["h"]/2
    return [(a["cx"]+a["w"]/2,a["cy"]),(b["cx"],a["cy"]),(b["cx"],ty)]
H=TOP+len(lanes)*LH+20
# ---------- BPMN XML
x=['<?xml version="1.0" encoding="UTF-8"?>',
'<definitions xmlns="http://www.omg.org/spec/BPMN/20100524/MODEL" xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI" xmlns:dc="http://www.omg.org/spec/DD/20100524/DC" xmlns:di="http://www.omg.org/spec/DD/20100524/DI" id="defs" targetNamespace="http://example.org/sdlc-poc">',
'  <collaboration id="collab"><participant id="pool" name="Software artifact lifecycle" processRef="proc"/></collaboration>',
'  <process id="proc" isExecutable="false">','    <laneSet id="lanes">']
for li,(lid,ln) in enumerate(lanes):
    x.append(f'      <lane id="{lid}" name="{html.escape(ln)}">')
    for n in nd.values():
        if n["lane"]==li: x.append(f'        <flowNodeRef>{n["id"]}</flowNodeRef>')
    x.append('      </lane>')
x.append('    </laneSet>')
inc={n:[] for n in nd}; out={n:[] for n in nd}
for s,t,_ in F: out[s].append(f"f_{s}_{t}"); inc[t].append(f"f_{s}_{t}")
for n in nd.values():
    lab=html.escape(n["label"].replace("\n"," "))
    x.append(f'    <{n["kind"]} id="{n["id"]}" name="{lab}">')
    for i in inc[n["id"]]: x.append(f'      <incoming>{i}</incoming>')
    for o in out[n["id"]]: x.append(f'      <outgoing>{o}</outgoing>')
    x.append(f'    </{n["kind"]}>')
for s,t,lab in F:
    nm=f' name="{lab}"' if lab else ''
    x.append(f'    <sequenceFlow id="f_{s}_{t}"{nm} sourceRef="{s}" targetRef="{t}"/>')
x+=['  </process>','  <bpmndi:BPMNDiagram id="d"><bpmndi:BPMNPlane id="p" bpmnElement="collab">',
f'    <bpmndi:BPMNShape id="s_pool" bpmnElement="pool" isHorizontal="true"><dc:Bounds x="0" y="{TOP}" width="{POOLW}" height="{len(lanes)*LH}"/></bpmndi:BPMNShape>']
for li,(lid,_) in enumerate(lanes):
    x.append(f'    <bpmndi:BPMNShape id="s_{lid}" bpmnElement="{lid}" isHorizontal="true"><dc:Bounds x="{LEFT}" y="{TOP+li*LH}" width="{POOLW-LEFT}" height="{LH}"/></bpmndi:BPMNShape>')
for n in nd.values():
    mk=' isMarkerVisible="true"' if n["kind"]=="exclusiveGateway" else ''
    x.append(f'    <bpmndi:BPMNShape id="s_{n["id"]}" bpmnElement="{n["id"]}"{mk}><dc:Bounds x="{n["cx"]-n["w"]/2:g}" y="{n["cy"]-n["h"]/2:g}" width="{n["w"]}" height="{n["h"]}"/></bpmndi:BPMNShape>')
for s,t,_ in F:
    x.append(f'    <bpmndi:BPMNEdge id="e_{s}_{t}" bpmnElement="f_{s}_{t}">'+''.join(f'<di:waypoint x="{px:g}" y="{py:g}"/>' for px,py in edge(s,t))+'</bpmndi:BPMNEdge>')
x+=['  </bpmndi:BPMNPlane></bpmndi:BPMNDiagram>','</definitions>']
open("docs/artifact-lifecycle.bpmn","w").write("\n".join(x)+"\n")
# ---------- SVG (styled via CSS variables; the UI overrides them for light/dark and live states)
CSS = """
svg.bpmn{--bg:#fff;--lane0:#eef4ff;--lane1:#eefaf0;--lane2:#fff8e8;--lane3:#f6eefa;--ink:#111;--line:#333;--card:#fff;--ok:#2e7d32;--bad:#b71c1c}
.bg{fill:var(--bg)} .pool{fill:var(--bg);stroke:var(--line);stroke-width:1.5}
.lane rect{stroke:var(--line)} .lane.l0 rect{fill:var(--lane0)} .lane.l1 rect{fill:var(--lane1)} .lane.l2 rect{fill:var(--lane2)} .lane.l3 rect{fill:var(--lane3)}
text{fill:var(--ink);font-family:Helvetica,Arial,sans-serif;font-size:13px} .lane text{font-weight:bold} .elabel{font-weight:bold}
.flow path{fill:none;stroke:var(--line);stroke-width:1.6} #ar path{fill:var(--line)}
.task rect,.gateway polygon{fill:var(--card);stroke:var(--line);stroke-width:1.6} .gateway .x{stroke:var(--line);stroke-width:2.5;fill:none}
.start circle{fill:var(--card);stroke:var(--ok);stroke-width:2} .end circle{fill:var(--card);stroke:var(--bad);stroke-width:4} .end.good circle{stroke:var(--ok)}
"""
s=[f'<svg xmlns="http://www.w3.org/2000/svg" class="bpmn" viewBox="0 0 {POOLW+10} {H}" width="{POOLW+10}" height="{H}" font-family="Helvetica,Arial,sans-serif">',
f'<title>BPMN 2.0: software artifact lifecycle</title><desc>Commit, build, SBOM, scan, decision on critical findings, sign, store in Harbor, request deployment, signature check, run or block.</desc>',
f'<style>{CSS}</style>',
'<defs><marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0,0 L10,5 L0,10 z"/></marker></defs>',
'<rect class="bg" width="100%" height="100%"/>',
f'<rect class="pool" x="1" y="{TOP}" width="{POOLW-1}" height="{len(lanes)*LH}"/>',
f'<text transform="translate(18,{TOP+len(lanes)*LH/2}) rotate(-90)" text-anchor="middle" font-weight="bold">Software artifact lifecycle</text>']
for li,(lid,ln) in enumerate(lanes):
    y=TOP+li*LH
    s.append(f'<g class="lane l{li}" data-id="{lid}"><rect x="{LEFT}" y="{y}" width="{POOLW-LEFT}" height="{LH}"/><text x="{LEFT+12}" y="{y+20}">{html.escape(ln)}</text></g>')
def lines(txt,cx,cy,anchor="middle"):
    ls=txt.split("\n"); y0=cy-(len(ls)-1)*8
    return "".join(f'<text x="{cx}" y="{y0+i*16+4}" text-anchor="{anchor}">{html.escape(l)}</text>' for i,l in enumerate(ls))
for sid,tid,lab in F:
    p=edge(sid,tid); d="M"+" L".join(f"{a:g},{b:g}" for a,b in p)
    g=f'<g class="flow" data-id="f_{sid}_{tid}"><path id="path_f_{sid}_{tid}" d="{d}" marker-end="url(#ar)"/>'
    if lab:
        a,b=p[0],p[1] if len(p)>1 else p[0]
        g+=f'<text class="elabel" x="{a[0]+(10 if a[1]==b[1] else 8)}" y="{a[1]+(-6 if a[1]==b[1] else (-10 if b[1]<a[1] else 18))}">{lab}</text>'
    s.append(g+'</g>')
for n in nd.values():
    cx,cy,w,h=n["cx"],n["cy"],n["w"],n["h"]; i=n["id"]
    if n["kind"]=="task":
        s.append(f'<g class="node task" data-id="{i}"><rect x="{cx-w/2:g}" y="{cy-h/2:g}" width="{w}" height="{h}" rx="10"/>'+lines(n["label"],cx,cy)+'</g>')
    elif n["kind"]=="startEvent":
        s.append(f'<g class="node event start" data-id="{i}"><circle cx="{cx}" cy="{cy}" r="18"/>'+lines(n["label"],cx,cy+38)+'</g>')
    elif n["kind"]=="endEvent":
        good=" good" if i=="ok" else ""
        ly=cy-50 if i=="reject" else cy+40
        lab=lines(n["label"],cx+24,cy,"start") if i=="blocked" else lines(n["label"],cx,ly)
        s.append(f'<g class="node event end{good}" data-id="{i}"><circle cx="{cx}" cy="{cy}" r="18"/>'+lab+'</g>')
    else:
        ly=cy+52 if i=="gw1" else cy-62
        s.append(f'<g class="node gateway" data-id="{i}"><polygon points="{cx},{cy-25} {cx+25},{cy} {cx},{cy+25} {cx-25},{cy}"/><path class="x" d="M{cx-9},{cy-9} L{cx+9},{cy+9} M{cx-9},{cy+9} L{cx+9},{cy-9}"/>'+lines(n["label"],cx,ly)+'</g>')
s.append('</svg>')
open("docs/artifact-lifecycle.svg","w").write("\n".join(s)+"\n")
