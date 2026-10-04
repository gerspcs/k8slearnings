# cert-manager + local CA
cert-manager chart v1.21.2 (ns cert-manager, crds.enabled). `kubectl apply -f infra/cert-manager/issuers.yaml` -> ClusterIssuer `sdlc-ca` (self-signed root, 10y).
Harbor cert: infra/harbor/certificate.yaml (secret harbor-tls). Harbor externalURL https://harbor.local:9443.
Export CA (public cert, gitignored): kubectl -n cert-manager get secret sdlc-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > infra/cert-manager/sdlc-ca.crt
Test: curl --resolve harbor.local:9443:127.0.0.1 --cacert infra/cert-manager/sdlc-ca.crt https://harbor.local:9443/api/v2.0/ping
Known: HTTP 8088 still serves Harbor (loopback only); Contour's redirect drops the port so it is not enforced.
Done: kind-node containerd trust is `scripts/bootstrap.sh node-trust`. Open: the host Docker daemon does not trust this CA (not needed by the lab; would need /etc/docker/certs.d/harbor.local:9443/ca.crt, root).
