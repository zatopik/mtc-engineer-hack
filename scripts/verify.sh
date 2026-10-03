#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo "MTC ENGINEER HACK - Verification"
echo "========================================"

echo
echo "==> Kubernetes node"
kubectl wait --for=condition=Ready node --all --timeout=60s
kubectl get nodes -o wide

echo
echo "==> Application"
kubectl rollout status deployment/nginx \
    -n demo \
    --timeout=60s

echo
echo "==> GatewayClass"
ACCEPTED="$(kubectl get gatewayclass nginx \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')"

if [[ "${ACCEPTED}" != "True" ]]; then
    echo "ERROR: GatewayClass nginx is not accepted"
    exit 1
fi

echo "GatewayClass nginx: Accepted=True"

echo
echo "==> Gateway"
PROGRAMMED="$(kubectl get gateway demo-gateway \
    -n demo \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"

if [[ "${PROGRAMMED}" != "True" ]]; then
    echo "ERROR: Gateway demo-gateway is not programmed"
    exit 1
fi

echo "Gateway demo-gateway: Programmed=True"

echo
echo "==> HTTPRoute"
ROUTE_ACCEPTED="$(kubectl get httproute nginx-route \
    -n demo \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"

ROUTE_RESOLVED="$(kubectl get httproute nginx-route \
    -n demo \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')"

if [[ "${ROUTE_ACCEPTED}" != "True" || "${ROUTE_RESOLVED}" != "True" ]]; then
    echo "ERROR: HTTPRoute is not ready"
    kubectl describe httproute nginx-route -n demo
    exit 1
fi

echo "HTTPRoute: Accepted=True, ResolvedRefs=True"

echo
echo "==> HTTP smoke test through Gateway"

NODE_IP="$(kubectl get node mtc-devops \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"

NODE_PORT="$(kubectl get svc demo-gateway-nginx \
    -n demo \
    -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')"

URL="http://${NODE_IP}:${NODE_PORT}/"

echo "Testing: ${URL}"

HTTP_CODE="$(curl -sS -o /tmp/mtc-response.html \
    -w '%{http_code}' \
    --max-time 10 \
    "${URL}")"

if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "ERROR: HTTP smoke test returned ${HTTP_CODE}"
    cat /tmp/mtc-response.html
    exit 1
fi

if ! grep -q "Hello World!" /tmp/mtc-response.html; then
    echo "ERROR: Expected application response was not found"
    cat /tmp/mtc-response.html
    exit 1
fi

echo "HTTP: 200"
echo "Application response: Hello World!"

echo
echo "==> Prometheus"

PROM_POD="$(kubectl get pods -n monitoring \
    -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].metadata.name}')"

kubectl port-forward \
    -n monitoring \
    svc/prometheus-kube-prometheus-prometheus \
    19090:9090 \
    >/tmp/mtc-prometheus-port-forward.log 2>&1 &

PF_PID=$!

cleanup() {
    kill "${PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT

sleep 3

PROM_RESULT="$(curl -sS --max-time 10 \
    'http://127.0.0.1:19090/api/v1/query?query=up')"

if ! grep -q '"status":"success"' <<<"${PROM_RESULT}"; then
    echo "ERROR: Prometheus query failed"
    exit 1
fi

if ! grep -q '"1"' <<<"${PROM_RESULT}"; then
    echo "ERROR: Prometheus returned no up=1 targets"
    exit 1
fi

echo "Prometheus query: OK"

echo
echo "==> Fluentd"

FLUENTD_POD="$(kubectl get pods -n logging \
    -l app.kubernetes.io/name=fluentd \
    -o jsonpath='{.items[0].metadata.name}')"

LOG_TOKEN="verify-$(date +%s)"

curl -sS -o /dev/null \
    "${URL}?logtest=${LOG_TOKEN}"

echo "Waiting for Fluentd..."
sleep 15

if ! kubectl exec -n logging "${FLUENTD_POD}" -- \
    sh -c "grep -R -q '${LOG_TOKEN}' /var/log/fluentd/demo/nginx* 2>/dev/null"
then
    echo "ERROR: Fluentd did not collect the test log"
    exit 1
fi

echo "Fluentd: log collected successfully"

echo
echo "========================================"
echo "ALL CHECKS PASSED"
echo "========================================"
