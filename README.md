# MTC ENGINEER HACK — DevOps

## Описание

Kubernetes-стенд с веб-приложением Nginx, маршрутизацией через Gateway API,
мониторингом Prometheus и сбором логов Fluentd.

## Архитектура

HTTP client
→ NGINX Gateway Fabric
→ Gateway
→ HTTPRoute
→ Service
→ Nginx

Monitoring:
Prometheus → kubelet / API server / CoreDNS / kube-state-metrics / node-exporter

Logging:
Nginx container logs → Fluentd → /var/log/fluentd/demo/

## Версии

| Компонент | Версия |
|---|---|
| Ubuntu Server | 24.04.5 LTS |
| Kubernetes | v1.37.1 |
| kubeadm | v1.37.1 |
| kubelet | v1.37.1 |
| kubectl | v1.37.1 |
| containerd | 2.2.1 |
| Calico | v3.33.0 |
| Helm | v4.3.0 |
| NGINX Gateway Fabric | v2.7.2 |
| kube-prometheus-stack | 91.9.0 |
| Fluentd | 1.19.3 |
| Fluentd Helm chart | 0.6.0 |

## Требования

- Ubuntu Server 24.04
- 4 vCPU
- 8 GiB RAM
- 50 GiB disk
- доступ в интернет
- swap отключён

## Структура проекта

    cluster/
      kubeadm-config.yaml

    k8s/
      app/
      gateway/
      monitoring/
      logging/

    manifests/
      calico/
      gateway/

    scripts/
      bootstrap-k8s.sh
      deploy.sh
      verify.sh

## Развёртывание

На чистой Ubuntu:

    ./scripts/bootstrap-k8s.sh

После подготовки Kubernetes:

    ./scripts/deploy.sh

## Проверка

Полная автоматическая проверка:

    ./scripts/verify.sh

Успешный результат:

    ALL CHECKS PASSED

## Проверка веб-приложения

    curl http://10.0.2.15:30267/

Ожидаемый ответ:

    Hello World!
    MTC ENGINEER HACK

## Gateway API

Используются:

- GatewayClass nginx
- Gateway demo-gateway
- HTTPRoute nginx-route

Проверка:

    kubectl get gatewayclass
    kubectl get gateway -n demo
    kubectl get httproute -n demo

Ожидается:

    GatewayClass nginx: Accepted=True
    Gateway demo-gateway: Programmed=True
    HTTPRoute nginx-route: Accepted=True
    HTTPRoute nginx-route: ResolvedRefs=True

## Prometheus

Проверка:

    kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

Во втором терминале:

    curl -s 'http://127.0.0.1:9090/api/v1/query?query=up'

Проверка метрики памяти:

    curl -s 'http://127.0.0.1:9090/api/v1/query?query=node_memory_MemAvailable_bytes'

## Fluentd

Тестовый HTTP-запрос:

    curl -s -o /dev/null -w "HTTP status: %{http_code}\n" "http://10.0.2.15:30267/?logtest=final123"

Проверка собранного лога:

    sudo find /var/log/fluentd/demo -type f -exec grep -H "final123" {} \;

В записи должны присутствовать Kubernetes metadata,
включая namespace demo и container nginx.

## Финальная проверка

    ./scripts/verify.sh
