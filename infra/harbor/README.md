# Harbor (registry)
Chart harbor/harbor 1.19.2 (app 2.15.2), ns `harbor`, HTTPS (cert-manager local CA, see ../cert-manager), ingress via Contour.
Easiest install: `scripts/bootstrap.sh harbor` (below are the manual equivalents; apply `certificate.yaml` before the helm command).

    kubectl create namespace harbor
    kubectl -n harbor create secret generic harbor-admin --from-literal=HARBOR_ADMIN_PASSWORD="$(cat infra/harbor/.harbor-admin)"
    helm install harbor harbor/harbor --version 1.19.2 -n harbor -f infra/harbor/values.yaml --wait

URL: https://harbor.local:9443 (needs `127.0.0.1 harbor.local` in /etc/hosts for browsers). Admin password: infra/harbor/.harbor-admin (gitignored, 0600).
Test without a hosts entry: `curl --resolve harbor.local:9443:127.0.0.1 --cacert infra/cert-manager/sdlc-ca.crt https://harbor.local:9443/api/v2.0/ping`
In-cluster, `harbor.local` resolves to Service `harbor-gw` (10.96.0.200, gateway-service.yaml) via a CoreDNS hosts entry (../coredns). The kind node's containerd trusts the CA via `scripts/bootstrap.sh node-trust`.

Open items: pin Harbor chart image digests; the plain-HTTP port 8088 still serves Harbor on loopback (Contour's redirect drops the port).
