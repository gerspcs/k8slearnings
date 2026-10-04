# Contour (ingress)
ingress-nginx was NOT used: upstream repo archived 2026-03 (no security fixes).

Install (pinned v1.33.7; Envoy already binds hostPort 80/443 -> kind maps to 127.0.0.1:8088/9443):

    kubectl apply -f infra/contour/contour-v1.33.7.yaml
    kubectl -n projectcontour patch svc envoy -p '{"spec":{"type":"NodePort"}}'   # no LoadBalancer on kind

Test: Ingress with host `echo.test`, then `curl -H 'Host: echo.test' http://127.0.0.1:8088/`.
