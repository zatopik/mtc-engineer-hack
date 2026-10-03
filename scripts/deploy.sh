#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "========================================"
echo "MTC ENGINEER HACK - Application deploy"
echo "========================================"

command -v kubectl >/dev/null 2>&1 || {
    echo "ERROR: kubectl is not installed"
    exit 1
}

command -v helm >/dev/null 2>&1 || {
    echo "ERROR: helm is not installed"
    exit 1
}

echo "==> Installing Gateway API CRDs"
kubectl apply -f \
    "${REPO_ROOT}/manifests/gateway/gateway-api-standard.yaml"

echo "==> Installing NGINX Gateway Fabric CRDs"
kubectl apply -f \
    "${REPO_ROOT}/manifests/gateway/nginx-gateway-crds.yaml"

echo "==> Installing NGINX Gateway Fabric"
kubectl apply -f \
    "${REPO_ROOT}/manifests/gateway/nginx-gateway-deploy.yaml"

echo "==> Waiting for NGINX Gateway Fabric"
kubectl rollout status deployment/nginx-gateway \
    -n nginx-gateway \
    --timeout=180s

echo "==> Waiting for GatewayClass"
for i in {1..60}; do
    ACCEPTED="$(kubectl get gatewayclass nginx \
        -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' \
        2>/dev/null || true)"

    if [[ "${ACCEPTED}" == "True" ]]; then
        break
    fi

    sleep 2
done

ACCEPTED="$(kubectl get gatewayclass nginx \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' \
    2>/dev/null || true)"

if [[ "${ACCEPTED}" != "True" ]]; then
    echo "ERROR: GatewayClass nginx was not accepted"
    kubectl get gatewayclass nginx -o yaml
    exit 1
fi

echo "==> Deploying web application"
kubectl apply -f \
    "${REPO_ROOT}/k8s/app/nginx.yaml"

kubectl rollout status deployment/nginx \
    -n demo \
    --timeout=180s

echo "==> Deploying Gateway"
kubectl apply -f \
    "${REPO_ROOT}/k8s/gateway/gateway.yaml"

echo "==> Deploying HTTPRoute"
kubectl apply -f \
    "${REPO_ROOT}/k8s/gateway/httproute.yaml"

echo "==> Waiting for Gateway"
for i in {1..60}; do
    PROGRAMMED="$(kubectl get gateway demo-gateway \
        -n demo \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' \
        2>/dev/null || true)"

    if [[ "${PROGRAMMED}" == "True" ]]; then
        break
    fi

    sleep 2
done

PROGRAMMED="$(kubectl get gateway demo-gateway \
    -n demo \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' \
    2>/dev/null || true)"

if [[ "${PROGRAMMED}" != "True" ]]; then
    echo "ERROR: Gateway is not programmed"
    kubectl describe gateway demo-gateway -n demo
    exit 1
fi

echo "==> Adding Prometheus repository"
helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts \
    >/dev/null 2>&1 || true

helm repo update >/dev/null

echo "==> Installing Prometheus"
helm upgrade --install prometheus \
    prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --version 91.9.0 \
    -f "${REPO_ROOT}/k8s/monitoring/prometheus-values.yaml"

echo "==> Adding Fluentd repository"
helm repo add fluent \
    https://fluent.github.io/helm-charts \
    >/dev/null 2>&1 || true

helm repo update >/dev/null

echo "==> Installing Fluentd"
helm upgrade --install fluentd \
    fluent/fluentd \
    --namespace logging \
    --create-namespace \
    --version 0.6.0 \
    -f "${REPO_ROOT}/k8s/logging/fluentd-values.yaml"

echo "==> Waiting for monitoring"
kubectl rollout status deployment/prometheus-kube-prometheus-operator \
    -n monitoring \
    --timeout=300s

kubectl rollout status statefulset/prometheus-prometheus-kube-prometheus-prometheus \
    -n monitoring \
    --timeout=300s

echo "==> Waiting for logging"
kubectl rollout status daemonset/fluentd \
    -n logging \
    --timeout=300s

echo
echo "========================================"
echo "Deployment completed"
echo "========================================"

echo
echo "--- Nodes ---"
kubectl get nodes

echo
echo "--- Application ---"
kubectl get pods -n demo
kubectl get svc -n demo

echo
echo "--- Gateway ---"
kubectl get gateway -n demo
kubectl get httproute -n demo

echo
echo "--- Monitoring ---"
kubectl get pods -n monitoring

echo
echo "--- Logging ---"
kubectl get pods -n logging
