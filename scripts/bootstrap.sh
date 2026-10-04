#!/usr/bin/env bash
# Idempotent bootstrap for the software-artifact SDLC POC. Safe to re-run.
# Usage: scripts/bootstrap.sh [all|check|cluster|platform|harbor|node-trust|pipeline|kyverno|demo|admission|negative|ui|tidy [--apply] [--deep]]
# Needs: docker kind kubectl helm cosign curl python3. No sudo required (Harbor is reached
# from the host via curl --resolve, so no /etc/hosts edit is needed).
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=sdlc-poc; NS=sdlc-build; HARBOR=https://harbor.local:9443
CA=infra/cert-manager/sdlc-ca.crt
say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
need(){ command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
hcurl(){ curl -sS --resolve harbor.local:9443:127.0.0.1 --cacert "$CA" "$@"; }
wait_deploy(){ kubectl -n "$1" wait --for=condition=Available deployment --all --timeout=300s; }

# Resource thresholds (override via env). Based on measurements of this lab: ~2.6 GiB RAM in the
# kind node at steady state, ~9 GB image/volume storage, 42 pods. Minimums include headroom for
# image builds and the Trivy vulnerability database download.
MIN_CPUS=${MIN_CPUS:-4};  REC_CPUS=${REC_CPUS:-6}
MIN_RAM_GB=${MIN_RAM_GB:-6}; REC_RAM_GB=${REC_RAM_GB:-10}      # RAM available to Docker (and free on the host)
MIN_DISK_GB=${MIN_DISK_GB:-20}; REC_DISK_GB=${REC_DISK_GB:-30} # free space where Docker stores data
REQUIRED_HOSTS="registry-1.docker.io ghcr.io quay.io gcr.io registry.k8s.io helm.goharbor.io charts.jetstack.io infra.tekton.dev raw.githubusercontent.com"

resources(){ say "Resource check (set SKIP_RESOURCE_CHECK=1 to bypass)"
  [ "${SKIP_RESOURCE_CHECK:-0}" = 1 ] && { echo "skipped"; return 0; }
  local fail=0 warn=0 cpus docker_ram_gb host_avail_gb root disk_gb
  docker info >/dev/null 2>&1 || { echo "FAIL  Docker daemon is not reachable (is it running, and can this user use it?)"; exit 1; }
  cpus=$(docker info -f '{{.NCPU}}')
  docker_ram_gb=$(docker info -f '{{.MemTotal}}' | awk '{printf "%d", $1/1073741824}')
  host_avail_gb=$(awk '/MemAvailable/{printf "%d",$2/1048576}' /proc/meminfo 2>/dev/null || echo "$docker_ram_gb")
  root=$(docker info -f '{{.DockerRootDir}}'); disk_gb=$(df -BG --output=avail "$root" 2>/dev/null | tail -1 | tr -dc '0-9')
  [ -n "$disk_gb" ] || disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  local exists=0; kind get clusters 2>/dev/null | grep -qx "$CLUSTER" && exists=1
  chk(){ # name have min rec unit
    if [ "$2" -lt "$3" ]; then echo "FAIL  $1: $2 $5 (need at least $3, recommended $4)"; fail=1
    elif [ "$2" -lt "$4" ]; then echo "WARN  $1: $2 $5 (minimum met; $4 recommended)"; warn=1
    else echo "ok    $1: $2 $5"; fi; }
  chk "CPU cores visible to Docker" "$cpus" "$MIN_CPUS" "$REC_CPUS" cores
  chk "RAM available to Docker" "$docker_ram_gb" "$MIN_RAM_GB" "$REC_RAM_GB" GiB
  if [ $exists = 1 ]; then echo "info  free host RAM: ${host_avail_gb} GiB (cluster '$CLUSTER' already running, so its memory is already in use)"
  else chk "Free host RAM" "$host_avail_gb" "$MIN_RAM_GB" "$REC_RAM_GB" GiB; fi
  chk "Free disk for Docker data ($root)" "$disk_gb" "$MIN_DISK_GB" "$REC_DISK_GB" GiB
  local h bad=""; for h in $REQUIRED_HOSTS; do curl -s -o /dev/null -m 6 "https://$h/" || bad="$bad $h"; done
  if [ -n "$bad" ]; then echo "FAIL  cannot reach:$bad (internet access to these registries is required)"; fail=1; else echo "ok    internet access to all required registries"; fi
  if [ $exists = 0 ]; then for p in 8088 9443; do ss -tln | awk '{print $4}' | grep -qE ":$p$" && { echo "FAIL  host port $p is in use; free it or edit infra/kind-config.yaml"; fail=1; }; done; fi
  if [ $fail = 1 ]; then echo "Resource check FAILED. Fix the items above, or override thresholds (MIN_RAM_GB=.. MIN_DISK_GB=..) at your own risk."; exit 1; fi
  [ $warn = 1 ] && echo "Resource check passed with warnings: expect slow builds or swapping." || echo "Resource check passed."; }

preflight(){ for t in docker kind kubectl helm cosign curl python3; do need $t; done; resources; }

cluster(){ say "kind cluster"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --config infra/kind-config.yaml
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  kubectl wait --for=condition=Ready node --all --timeout=180s; }

platform(){ say "Tekton, Contour, cert-manager"
  kubectl apply -f infra/tekton/pipeline-v1.17.0.yaml >/dev/null; wait_deploy tekton-pipelines
  kubectl apply -f infra/contour/contour-v1.33.7.yaml >/dev/null
  kubectl -n projectcontour patch svc envoy -p '{"spec":{"type":"NodePort"}}' >/dev/null
  kubectl -n projectcontour rollout status ds/envoy --timeout=300s
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true; helm repo update jetstack >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.2 -n cert-manager --create-namespace --set crds.enabled=true --wait --timeout 5m >/dev/null
  kubectl apply -f infra/cert-manager/issuers.yaml >/dev/null
  kubectl -n cert-manager wait --for=condition=Ready certificate/sdlc-ca --timeout=120s
  kubectl -n cert-manager get secret sdlc-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA"; }

node_trust(){ say "Make the kind node's containerd trust the local CA and resolve harbor.local"
  local node="$CLUSTER-control-plane" changed=0
  docker exec "$node" sh -c 'grep -q "^\s*config_path" /etc/containerd/config.toml' || {
    docker exec "$node" sh -c 'printf "\n[plugins.\"io.containerd.grpc.v1.cri\".registry]\n  config_path = \"/etc/containerd/certs.d\"\n" >> /etc/containerd/config.toml'; changed=1; }
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/harbor.local:9443"
  docker cp "$CA" "$node:/etc/containerd/certs.d/harbor.local:9443/ca.crt"
  printf 'server = "https://harbor.local:9443"\n\n[host."https://harbor.local:9443"]\n  capabilities = ["pull", "resolve"]\n  ca = "/etc/containerd/certs.d/harbor.local:9443/ca.crt"\n' \
    | docker exec -i "$node" sh -c 'cat > "/etc/containerd/certs.d/harbor.local:9443/hosts.toml"'
  docker exec "$node" sh -c 'grep -q "harbor.local" /etc/hosts || echo "10.96.0.200 harbor.local" >> /etc/hosts'
  if [ $changed = 1 ]; then docker exec "$node" systemctl restart containerd; sleep 15
    kubectl wait --for=condition=Ready node --all --timeout=120s; fi; }

harbor(){ say "Harbor"
  helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true; helm repo update harbor >/dev/null
  kubectl create ns harbor --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if [ ! -s infra/harbor/.harbor-admin ]; then
    ( umask 077; python3 -c "import secrets;print(secrets.token_urlsafe(20),end='')" > infra/harbor/.harbor-admin ); fi
  kubectl -n harbor create secret generic harbor-admin --from-file=HARBOR_ADMIN_PASSWORD=infra/harbor/.harbor-admin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f infra/harbor/certificate.yaml >/dev/null
  kubectl -n harbor wait --for=condition=Ready certificate/harbor-tls --timeout=120s
  helm upgrade --install harbor harbor/harbor --version 1.19.2 -n harbor -f infra/harbor/values.yaml --wait --timeout 10m >/dev/null
  kubectl apply -f infra/harbor/gateway-service.yaml -f infra/coredns/coredns-configmap.yaml >/dev/null   # harbor.local inside the cluster
  kubectl -n kube-system rollout restart deploy/coredns >/dev/null; kubectl -n kube-system rollout status deploy/coredns --timeout=120s
  for i in $(seq 1 30); do [ "$(hcurl -s -o /dev/null -w '%{http_code}' $HARBOR/api/v2.0/ping)" = 200 ] && break; sleep 5; done
  hcurl $HARBOR/api/v2.0/ping; echo; }

pipeline(){ say "Registry project, robot account, signing key, pipeline"
  local pw; pw=$(cat infra/harbor/.harbor-admin)
  kubectl create ns $NS --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n $NS create configmap sdlc-ca --from-file=ca.crt="$CA" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  hcurl -o /dev/null -u "admin:$pw" -X POST $HARBOR/api/v2.0/projects -H 'Content-Type: application/json' \
    -d '{"project_name":"poc","metadata":{"public":"false"}}' || true     # 409 if it already exists
  # robot secrets can't be read back, so replace the robot each run
  local pid rid; pid=$(hcurl -u "admin:$pw" "$HARBOR/api/v2.0/projects?name=poc" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['project_id'])")
  rid=$(hcurl -u "admin:$pw" "$HARBOR/api/v2.0/robots?q=Level%3Dproject%2CProjectID%3D$pid" | python3 -c "import sys,json;print(next((r['id'] for r in json.load(sys.stdin) if r['name']=='robot\$poc+ci'),''))")
  [ -n "$rid" ] && hcurl -o /dev/null -u "admin:$pw" -X DELETE $HARBOR/api/v2.0/robots/$rid
  hcurl -u "admin:$pw" -X POST $HARBOR/api/v2.0/robots -H 'Content-Type: application/json' -d '{"name":"ci","description":"Tekton pipeline","duration":90,"level":"project","permissions":[{"kind":"project","namespace":"poc","access":[{"resource":"repository","action":"push"},{"resource":"repository","action":"pull"},{"resource":"artifact","action":"read"},{"resource":"artifact","action":"list"}]}]}' \
   | python3 -c "
import sys,json,base64
d=json.load(sys.stdin); a=base64.b64encode(f\"{d['name']}:{d['secret']}\".encode()).decode()
print(json.dumps({'auths':{'harbor.local:9443':{'auth':a}}}))" \
   | kubectl -n $NS create secret generic harbor-robot --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if ! kubectl -n $NS get secret cosign-key >/dev/null 2>&1; then
    local d cp; d=$(mktemp -d); cp=$(python3 -c "import secrets;print(secrets.token_urlsafe(24))")
    ( cd "$d" && COSIGN_PASSWORD="$cp" cosign generate-key-pair >/dev/null 2>&1 )
    kubectl -n $NS create secret generic cosign-key --from-file=cosign.key="$d/cosign.key" --from-literal=password="$cp" >/dev/null
    mkdir -p infra/cosign; cp "$d/cosign.pub" infra/cosign/cosign.pub; rm -rf "$d"
  fi
  kubectl -n $NS create configmap cosign-pub --from-file=cosign.pub=infra/cosign/cosign.pub --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n $NS create configmap cosign-signing-config --from-file=signing-config.json=infra/cosign/signing-config.json --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n $NS create configmap sample-app-src --from-file=sample-app --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n $NS apply -f pipelines/tasks.yaml -f pipelines/pipeline.yaml >/dev/null
  sync_robot_secret; }

sync_robot_secret(){ # copy the current robot pull secret into namespaces that need it (the robot is replaced on every pipeline stage)
  local ns; for ns in kyverno sdlc-apps; do kubectl get ns "$ns" >/dev/null 2>&1 || continue
    kubectl -n $NS get secret harbor-robot -o json | python3 -c "
import sys,json
d=json.load(sys.stdin); print(json.dumps({'apiVersion':'v1','kind':'Secret','type':d['type'],'metadata':{'name':'harbor-robot','namespace':'$ns'},'data':d['data']}))" | kubectl apply -f - >/dev/null; done; }

kyverno(){ say "Kyverno: refuse unsigned images in namespace sdlc-apps"
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true; helm repo update kyverno >/dev/null
  kubectl create ns kyverno --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n kyverno create configmap sdlc-ca --from-file=ca.crt="$CA" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create ns sdlc-apps --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sync_robot_secret
  kubectl -n sdlc-apps patch sa default -p '{"imagePullSecrets":[{"name":"harbor-robot"}]}' >/dev/null
  helm upgrade --install kyverno kyverno/kyverno --version 3.9.1 -n kyverno -f infra/kyverno/values.yaml --wait --timeout 8m >/dev/null
  python3 - <<'PY' | kubectl apply -f - >/dev/null
pub=open('infra/cosign/cosign.pub').read().strip().splitlines()
print(open('infra/kyverno/policies.yaml.tpl').read().replace('__COSIGN_PUB__',"\n".join(' '*12+l for l in pub)))
PY
  sleep 10; kubectl get ivpol,vpol; }

harbor_digest(){ # harbor_digest <repo> <tag|"signed"|"unsigned"> -> prints digest
  local pw; pw=$(cat infra/harbor/.harbor-admin)
  hcurl -u "admin:$pw" "$HARBOR/api/v2.0/projects/poc/repositories/$1/artifacts?with_accessory=true&page_size=50" | python3 -c "
import sys,json
a=json.load(sys.stdin); w='$2'
if w=='signed': c=[x for x in a if x.get('accessories') and x.get('tags')] or [x for x in a if x.get('accessories')]
else: c=[x for x in a if any(t['name']==w for t in (x.get('tags') or []))]
print(c[0]['digest'] if c else '')"; }

unsigned_fixture(){ # an image that never goes through sign-attest, in its own repo, for the negative admission test
  [ -n "$(harbor_digest unsigned-demo fixture)" ] && return 0
  echo "building the unsigned test image (repo poc/unsigned-demo, never signed)..."
  local tr; tr=$(kubectl -n $NS create -f - -o jsonpath='{.metadata.name}' <<YAML
apiVersion: tekton.dev/v1
kind: TaskRun
metadata: {generateName: unsigned-fixture-}
spec:
  taskRef: {name: build-push}
  params: [{name: image, value: "harbor.local:9443/poc/unsigned-demo"}, {name: tag, value: fixture}]
  workspaces: [{name: source, configMap: {name: sample-app-src}}]
YAML
)
  kubectl -n $NS wait --for=condition=Succeeded taskrun/"$tr" --timeout=300s; }

admission(){ say "Admission test: the cluster must refuse unsigned and foreign images"
  local sd ud fail=0; sd=$(harbor_digest sample-app signed); unsigned_fixture; ud=$(harbor_digest unsigned-demo fixture)
  [ -n "$sd" ] && [ -n "$ud" ] || { echo "missing signed/unsigned digests; run the pipeline stage first" >&2; exit 1; }
  try(){ # name image expect(admit|deny)
    local out rc=0; out=$(kubectl -n sdlc-apps run "$1" --image="$2" --restart=Never --command -- sh -c 'sleep 600' 2>&1) || rc=$?
    if [ "$3" = admit ] && [ $rc = 0 ]; then echo "PASS  $1: admitted as expected"
    elif [ "$3" = deny ] && [ $rc != 0 ]; then echo "PASS  $1: denied as expected -> $(echo "$out" | grep -oE 'failed: .*' | head -1 | cut -c1-110)"
    else echo "FAIL  $1: expected $3, got rc=$rc: $out"; fail=1; fi; }
  try t-signed   "harbor.local:9443/poc/sample-app@$sd"   admit
  try t-unsigned "harbor.local:9443/poc/unsigned-demo@$ud" deny
  try t-foreign  "docker.io/library/busybox:1.36"         deny
  kubectl -n sdlc-apps delete pod t-signed t-unsigned t-foreign --ignore-not-found --grace-period=1 --wait=false >/dev/null
  [ $fail = 0 ] && echo "Admission test passed." || { echo "Admission test FAILED" >&2; exit 1; }; }

# ---- tidy: sweep stale / temporary artifacts across every stage. Dry-run unless --apply. ----
KEEP_RUNS=${KEEP_RUNS:-3}; KEEP_ARTIFACTS=${KEEP_ARTIFACTS:-3}
tidy(){ local apply=0 deep=0 n=0 a; for a in "$@"; do case $a in --apply) apply=1;; --deep) deep=1;; esac; done
  say "Tidy-up sweep ($([ $apply = 1 ] && echo APPLYING || echo "DRY RUN: nothing is deleted; add --apply"))"
  act(){ n=$((n+1)); if [ $apply = 1 ]; then echo "  delete: $1"; shift; "$@" >/dev/null 2>&1 || echo "    (failed or already gone)"; else echo "  would delete: $1"; fi; }
  local x
  # 1. Tekton: old PipelineRuns (their TaskRuns, pods and workspace volumes are removed with them)
  for x in $(kubectl -n $NS get pipelinerun --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | head -n -"$KEEP_RUNS"); do
    act "$x (keeping the newest $KEEP_RUNS runs; also removes its pods and volume)" kubectl -n $NS delete "$x" --wait=false; done
  # 2. Tekton: one-off TaskRuns that are not part of a pipeline run (test runs)
  for x in $(kubectl -n $NS get taskrun -o json 2>/dev/null | python3 -c "
import sys,json
for t in json.load(sys.stdin)['items']:
    if 'tekton.dev/pipelineRun' not in t['metadata'].get('labels',{}): print('taskrun/'+t['metadata']['name'])"); do
    act "$x (one-off test run)" kubectl -n $NS delete "$x" --wait=false; done
  # 3. Orphaned finished pods with no owner (leftover 'kubectl run' tests) in lab namespaces
  for x in $(kubectl get pods -A -o json | python3 -c "
import sys,json
for p in json.load(sys.stdin)['items']:
    m=p['metadata']
    if m['namespace'] in ('sdlc-build','sdlc-apps','default') and p['status'].get('phase') in ('Failed','Succeeded') and not m.get('ownerReferences') and not m.get('deletionTimestamp'): print(m['namespace']+'/'+m['name'])"); do
    act "pod $x (finished, no owner)" kubectl -n "${x%/*}" delete pod "${x#*/}" --wait=false; done
  # 4. Demo workloads left running in sdlc-apps
  for x in $(kubectl -n sdlc-apps get pods -o json 2>/dev/null | python3 -c "
import sys,json
for p in json.load(sys.stdin)['items']:
    if not p['metadata'].get('deletionTimestamp'): print('pod/'+p['metadata']['name'])"); do act "$x (demo workload in sdlc-apps)" kubectl -n sdlc-apps delete "$x" --wait=false; done
  # 5. Volumes in sdlc-build that no pod uses and no run owns
  for x in $(kubectl -n $NS get pvc -o json 2>/dev/null | python3 -c "
import sys,json,subprocess
pods=json.loads(subprocess.run(['kubectl','-n','$NS','get','pods','-o','json'],capture_output=True,text=True).stdout)['items']
used={v['persistentVolumeClaim']['claimName'] for p in pods for v in p['spec'].get('volumes',[]) if 'persistentVolumeClaim' in v}
for c in json.load(sys.stdin)['items']:
    if not c['metadata'].get('ownerReferences') and c['metadata']['name'] not in used: print('pvc/'+c['metadata']['name'])"); do
    act "$x (unused, unowned volume)" kubectl -n $NS delete "$x" --wait=false; done
  # 6. Harbor: old untagged artifacts (each keeps its signatures with it). Newest KEEP_ARTIFACTS per repo and anything tagged is kept.
  if [ -s infra/harbor/.harbor-admin ] && [ "$(hcurl -s -o /dev/null -w '%{http_code}' $HARBOR/api/v2.0/ping 2>/dev/null)" = 200 ]; then
    local pw r; pw=$(cat infra/harbor/.harbor-admin)
    for r in sample-app unsigned-demo; do
      for x in $(hcurl -u "admin:$pw" "$HARBOR/api/v2.0/projects/poc/repositories/$r/artifacts?page_size=100&sort=-push_time" 2>/dev/null | python3 -c "
import sys,json
try: a=json.load(sys.stdin)
except Exception: a=[]
for i,x in enumerate(a):
    if i>=$KEEP_ARTIFACTS and not x.get('tags'): print(x['digest'])"); do
        act "Harbor poc/$r@${x:0:19} (old, untagged)" hcurl -o /dev/null -u "admin:$pw" -X DELETE "$HARBOR/api/v2.0/projects/poc/repositories/$r/artifacts/$x"; done; done
  else echo "  (Harbor not reachable: skipped registry sweep)"; fi
  # 7. Deep: reclaim disk (re-downloads images on the next run)
  if [ $deep = 1 ]; then
    act "Harbor garbage collection (frees blobs of deleted artifacts)" hcurl -u "admin:$(cat infra/harbor/.harbor-admin)" -X POST $HARBOR/api/v2.0/system/gc/schedule -H 'Content-Type: application/json' -d '{"schedule":{"type":"Manual"}}'
    act "dangling Docker images on the host (docker image prune)" docker image prune -f
    act "unused images inside the kind node (crictl rmi --prune)" docker exec "$CLUSTER-control-plane" crictl rmi --prune
  else echo "  (add --deep to also reclaim disk: Harbor GC, dangling Docker images, unused node images)"; fi
  [ $n = 0 ] && echo "Nothing to tidy." || { [ $apply = 1 ] && echo "Tidied $n item(s)." || echo "$n item(s) would be removed. Re-run with --apply to do it."; }; }

ui(){ say "Live view (Ctrl+C to stop). Open the address below in a browser."
  need python3; kubectl config use-context "kind-$CLUSTER" >/dev/null 2>&1 || true
  [ -s "$CA" ] || { echo "run the platform stage first (no CA file at $CA)" >&2; exit 1; }
  ss -tln | awk '{print $4}' | grep -qE ":${UI_PORT:-8099}$" && { echo "port ${UI_PORT:-8099} is in use; set UI_PORT=<free port>" >&2; exit 1; }
  exec python3 ui/server.py; }

demo(){ say "Run the pipeline: build > SBOM > scan > sign > verify"
  local pr s; pr=$(kubectl -n $NS create -f pipelines/pipelinerun.yaml -o jsonpath='{.metadata.name}'); echo "PipelineRun: $pr"
  for i in $(seq 1 60); do s=$(kubectl -n $NS get pr "$pr" -o jsonpath='{.status.conditions[0].status}'); [ "$s" = True ] || [ "$s" = False ] && break; sleep 10; done
  kubectl -n $NS get taskrun -l tekton.dev/pipelineRun="$pr" -o custom-columns=TASK:.metadata.labels.tekton\\.dev/pipelineTask,RESULT:.status.conditions[0].reason
  [ "$s" = True ] || { echo "PIPELINE FAILED: kubectl -n $NS logs -l tekton.dev/pipelineRun=$pr --all-containers" >&2; exit 1; }
  echo "SUCCESS: image built, scanned, signed and verified. Browse https://harbor.local:9443 (needs a hosts entry) or use the API."; }

negative(){ say "Negative test: an unsigned image must fail verification"
  local pw r; pw=$(cat infra/harbor/.harbor-admin)
  for r in sample-app unsigned-demo; do echo "poc/$r:"
    hcurl -u "admin:$pw" "$HARBOR/api/v2.0/projects/poc/repositories/$r/artifacts?with_accessory=true" 2>/dev/null \
     | python3 -c "
import sys,json
try: a=json.load(sys.stdin)
except Exception: a=[]
for x in a: print('  ',x['digest'][:19], 'tags=',[t['name'] for t in x.get('tags') or []], 'signatures=',len(x.get('accessories') or []))"; done
  echo "An artifact with signatures=0 fails 'cosign verify' and is refused by the cluster (see the admission stage and the README section \"Where the project stands\")."; }

case "${1:-all}" in
  all) preflight; cluster; platform; harbor; node_trust; pipeline; kyverno; demo; admission; negative
       echo; echo "Tip: review leftovers with: scripts/bootstrap.sh tidy";;
  check) preflight;;
  cluster) preflight; cluster;; platform) platform;; harbor) harbor;; node-trust) node_trust;;
  pipeline) pipeline;; kyverno) kyverno;; demo) demo;; admission) admission;; negative) negative;;
  ui) ui;;
  tidy) shift; tidy "$@";;
  *) echo "usage: $0 [all|check|cluster|platform|harbor|node-trust|pipeline|kyverno|demo|admission|negative|ui|tidy [--apply] [--deep]]"; exit 2;;
esac
