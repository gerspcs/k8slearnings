# AGENTS.md: instructions for AI coding assistants

You are helping a person set up and run a **software supply chain POC** on their own machine: a local Kubernetes cluster (`kind`) with Tekton (CI), Harbor (registry), Contour (ingress), cert-manager (TLS), and a pipeline that builds a sample image, generates an SBOM, scans it, signs it with Cosign, stores it in Harbor and verifies it. Read `README.md` for the story; this file is the runbook.

## Goal and definition of done
Done means you have **shown the person evidence** of all of these:
1. `scripts/bootstrap.sh check` passed (or you reported why it failed).
2. `scripts/bootstrap.sh all` finished with exit code 0.
3. The demo pipeline shows five tasks `Succeeded`: `build-push`, `sbom`, `vuln-scan`, `sign-attest`, `verify`.
4. The `admission` stage prints three PASS lines (signed image admitted; unsigned image denied; foreign image denied) and `Admission test passed.`
5. The `negative` stage lists a repository where the signed image has `signatures= 2` and at least one artifact has `signatures= 0`.
6. Optionally, a negative test: `cosign verify` against the unsigned digest fails with `no signatures found`.

Do not report success from an exit code alone. Quote the command output that proves each item.

## Run order
```bash
scripts/bootstrap.sh check      # read-only: CPU, RAM, disk, ports, internet. STOP and report if it fails.
scripts/bootstrap.sh all        # cluster, platform, harbor, pipeline, demo, negative. Idempotent.
```
Single stages: `cluster | platform | harbor | node-trust | pipeline | kyverno | demo | admission | negative | ui | tidy`. Re-running is safe.

Report the **resource check result to the user before deploying**. If it says FAIL, do not bypass it with `SKIP_RESOURCE_CHECK=1` or lowered thresholds unless the user explicitly agrees after you explain the risk (slow builds, swapping, out-of-memory kills).

## Prerequisites you must verify (do not assume)
`docker`, `kind`, `kubectl`, `helm`, `cosign`, `curl`, `python3`. Host ports `8088` and `9443` free. Internet access to the registries listed in the script. If a tool is missing, tell the user how to install it; do not install system packages without asking.

## Rules (hard constraints)
- **Never run `sudo`.** If a step needs root (for example adding `127.0.0.1 harbor.local` to `/etc/hosts`), print the exact command in a code block and ask the user to run it. The demo does **not** need it; the script reaches Harbor with `curl --resolve`.
- **No secrets in git or in your output.** Never print or commit `infra/harbor/.harbor-admin`, the Cosign private key, robot credentials, kubeconfigs, `.env`, `*.key`, `*.pem`. They are gitignored; keep it that way. Do not paste secrets into chat.
- **Confirm before destructive actions** (`kind delete cluster`, `helm uninstall`, `kubectl delete ns`, `rm -rf`, `docker rm/stop`). List exactly what will be removed and wait for a yes.
- **Do not weaken security to make something pass.** Do not disable TLS verification, skip signature verification, drop the vulnerability gate, or loosen NetworkPolicy/RBAC. If a check fails, diagnose it. Do not delete or bypass the check.
- **Pin versions.** Images are pinned by digest, charts by version. Do not change to `latest`.
- Stay inside this repository. Do not modify the user's global configuration.

## How it fits together (for debugging)
- Cluster `sdlc-poc` from `infra/kind-config.yaml`; host `8088`→80 and `9443`→443 on loopback.
- Harbor is at `https://harbor.local:9443`. Inside the cluster, `harbor.local` resolves (CoreDNS `hosts` entry) to a fixed Service IP `10.96.0.200` (`infra/harbor/gateway-service.yaml`) that forwards 9443 to Envoy. The TLS certificate comes from a local CA (`infra/cert-manager/`); the CA file `infra/cert-manager/sdlc-ca.crt` is generated and gitignored.
- Pipeline namespace `sdlc-build`. Tasks are in `pipelines/tasks.yaml`, the pipeline in `pipelines/pipeline.yaml`, a run in `pipelines/pipelinerun.yaml`. Source for the sample image comes from a ConfigMap built from `sample-app/`.
- Pipeline credentials: a Harbor **robot account** limited to project `poc` (not admin), stored as Secret `harbor-robot`. Signing key in Secret `cosign-key`; public key at `infra/cosign/cosign.pub`.

## Known gotchas (already solved; do not re-investigate)
- **Cosign v3** rejects `--tlog-upload=false`. We pass `--signing-config infra/cosign/signing-config.json` (no transparency log). Verification uses `--insecure-ignore-tlog=true`. This is a deliberate private-lab trade-off.
- **Harbor robot lookup** only lists project robots when filtered by `Level=project,ProjectID=<id>`; the script does this.
- **CoreDNS reload** can briefly fail lookups for a few seconds after the config changes. Wait and retry before debugging.
- **Node trust for pulling from Harbor** is done by `scripts/bootstrap.sh node-trust` (adds a registry `config_path` to the kind node's containerd, installs the CA, restarts containerd inside the node, adds `harbor.local` to the node's `/etc/hosts`). It lives in the node container, so **re-run it if the node container is recreated**.
- **Kyverno** uses the new `policies.kyverno.io/v1` API (`ImageValidatingPolicy`, `ValidatingPolicy`); the old `ClusterPolicy` is deprecated. In CEL, attestor names cannot contain hyphens (`labkey`, not `lab-key`). Kyverno gets the lab CA through `SSL_CERT_DIR` (adds to system roots) and reads Harbor with the `harbor-robot` secret in the `kyverno` namespace. The pipeline stage replaces the robot each run and re-copies the secret.
- The policy is rendered from `infra/kyverno/policies.yaml.tpl`; do not hand-edit a rendered copy. Scope is the `sdlc-apps` namespace only.
- Tekton tasks that share a workspace across pods need a PVC (`volumeClaimTemplate`), not `emptyDir`.
- After deleting a failed `PipelineRun`, leftover TaskRuns/PVCs can linger; delete by label `tekton.dev/pipelineRun=<name>`.

## Live view (optional, great for showing the user)
`scripts/bootstrap.sh ui` starts a small server (`ui/server.py`, standard library only) on `http://localhost:8099`. It shows the BPMN process and the cluster side by side, kept in sync from the Kubernetes API, with buttons to start a build and to try signed, unsigned and foreign images. It runs in the foreground: start it in the background only if your tool supports that, tell the user the URL, and **stop it when you finish**.
- It listens on loopback only, runs a fixed set of `kubectl` commands, and POSTs need the per-session token the page embeds. Do not weaken that (no `0.0.0.0`, no extra actions, no secrets in responses).
- With no cluster, `python3 -m http.server 8000 --bind 127.0.0.1` from the repo root serves `http://localhost:8000/ui/` as a demo that replays `ui/sample-recording.json`.
- `ui/recordings/` is generated and gitignored. `ui/sample-recording.json` is the committed demo recording; replace it only from a real run.
- The diagram is generated: edit `docs/build_diagram.py`, run `python3 docs/build_diagram.py`, and never hand-edit the `.svg` or `.bpmn`.

## Tidy-up sweep (garbage collection)
`scripts/bootstrap.sh tidy` is a **dry run**: it lists stale or temporary items (old Tekton runs, ownerless finished test pods, demo pods in `sdlc-apps`, unused volumes, old untagged Harbor artifacts) and deletes nothing.
- Always run the dry run first and **show the list to the user**. Run `tidy --apply` only after they say yes. `--deep` (Harbor GC, Docker image prune, node image prune) needs its own yes, because images are re-downloaded afterwards.
- Offer the dry run at the end of a session. Never delete tagged registry images, secrets, keys or platform namespaces as part of tidying.

## Diagnostics
```bash
kubectl get pods -A | grep -v Running                       # unhealthy pods
kubectl -n sdlc-build get pr,tr                              # pipeline status
kubectl -n sdlc-build logs -l tekton.dev/pipelineRun=<name> --all-containers
kubectl -n harbor get pods
curl --resolve harbor.local:9443:127.0.0.1 --cacert infra/cert-manager/sdlc-ca.crt https://harbor.local:9443/api/v2.0/ping   # expect: Pong
```
"Pod Ready" is not the same as "serving": always poll the real endpoint.

## Not built yet (do not claim otherwise)
Tekton Chains (automatic provenance), widening the admission policy beyond `sdlc-apps`, GitOps. The script was run from a blank state once (cluster and generated files deleted first; exit 0, about 6.5 min, 8 cores/23 GiB Linux) and re-run idempotently several times. It has not been tested on macOS, Windows, small machines or with an empty image cache. Say so if asked.

## When you finish
Summarise what you ran, quote the evidence for each "done" item, list anything skipped, and state any step you handed back to the user.
