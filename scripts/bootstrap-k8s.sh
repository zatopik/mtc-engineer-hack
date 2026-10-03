#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

K8S_MINOR_VERSION="1.37"
K8S_VERSION="1.37.1-1.1"

KUBEADM_CONFIG="${REPO_ROOT}/cluster/kubeadm-config.yaml"

echo "========================================"
echo "MTC ENGINEER HACK - Kubernetes bootstrap"
echo "========================================"

echo "==> Checking OS"
source /etc/os-release

if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
    echo "ERROR: Ubuntu 24.04 is required"
    exit 1
fi

echo "==> Checking repository files"

for file in \
    "${KUBEADM_CONFIG}" \
    "${REPO_ROOT}/manifests/calico/v3_projectcalico_org.yaml" \
    "${REPO_ROOT}/manifests/calico/tigera-operator.yaml" \
    "${REPO_ROOT}/manifests/calico/custom-resources.yaml"
do
    if [[ ! -f "${file}" ]]; then
        echo "ERROR: Required file not found: ${file}"
        exit 1
    fi
done

echo "==> Disabling swap"

sudo swapoff -a || true

if grep -qE '^/swap\.img[[:space:]]' /etc/fstab; then
    sudo sed -i 's|^/swap\.img|#/swap.img|' /etc/fstab
fi

if swapon --show | grep -q .; then
    echo "ERROR: Swap is still enabled"
    exit 1
fi

echo "==> Preparing kernel modules"

sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'MODULES'
overlay
br_netfilter
MODULES

sudo modprobe overlay
sudo modprobe br_netfilter

echo "==> Preparing sysctl"

sudo tee /etc/sysctl.d/99-kubernetes.conf >/dev/null <<'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL

sudo sysctl --system >/dev/null

echo "==> Installing containerd"

sudo apt-get update

sudo apt-get install -y \
    ca-certificates \
    curl \
    gpg \
    apt-transport-https \
    containerd

echo "==> Configuring containerd"

sudo mkdir -p /etc/containerd

containerd config default |
    sudo tee /etc/containerd/config.toml >/dev/null

sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
    /etc/containerd/config.toml

sudo systemctl enable --now containerd
sudo systemctl restart containerd

echo "==> Checking containerd"

if [[ "$(systemctl is-active containerd)" != "active" ]]; then
    echo "ERROR: containerd is not active"
    exit 1
fi

echo "==> Configuring Kubernetes repository"

sudo mkdir -p -m 755 /etc/apt/keyrings

curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR_VERSION}/deb/Release.key" |
    sudo gpg --dearmor --yes \
    -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR_VERSION}/deb/ /" |
    sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update

echo "==> Installing Kubernetes ${K8S_VERSION}"
echo "==> Installing Helm"

curl -fsSL \
    -o /tmp/get_helm.sh \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4

chmod 700 /tmp/get_helm.sh
sudo /tmp/get_helm.sh

rm -f /tmp/get_helm.sh

echo "==> Checking Helm"
helm version
sudo apt-get install -y \
    "kubelet=${K8S_VERSION}" \
    "kubeadm=${K8S_VERSION}" \
    "kubectl=${K8S_VERSION}"

sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable kubelet

echo "==> Checking whether cluster is already initialized"

if [[ ! -f /etc/kubernetes/admin.conf ]]; then

    echo "==> Initializing Kubernetes cluster"

    sudo kubeadm init \
        --config "${KUBEADM_CONFIG}"

else

    echo "==> Existing Kubernetes cluster detected"
    echo "==> Skipping kubeadm init"

fi

echo "==> Configuring kubectl"

mkdir -p "${HOME}/.kube"

sudo cp -f \
    /etc/kubernetes/admin.conf \
    "${HOME}/.kube/config"

sudo chown \
    "$(id -u):$(id -g)" \
    "${HOME}/.kube/config"

export KUBECONFIG="${HOME}/.kube/config"

echo "==> Allowing workloads on the single control-plane node"

kubectl taint nodes --all \
    node-role.kubernetes.io/control-plane- \
    2>/dev/null || true

echo "==> Installing Calico"

kubectl apply -f \
    "${REPO_ROOT}/manifests/calico/v3_projectcalico_org.yaml"

kubectl apply -f \
    "${REPO_ROOT}/manifests/calico/tigera-operator.yaml"

kubectl apply -f \
    "${REPO_ROOT}/manifests/calico/custom-resources.yaml"

echo "==> Waiting for Kubernetes node"

kubectl wait \
    --for=condition=Ready \
    node \
    --all \
    --timeout=300s

echo "==> Waiting for Calico"

kubectl wait \
    --for=condition=Ready \
    pods \
    --all \
    -n calico-system \
    --timeout=300s

echo
echo "========================================"
echo "Kubernetes bootstrap completed"
echo "========================================"

kubectl get nodes -o wide

echo
echo "Calico:"
kubectl get tigerastatus
