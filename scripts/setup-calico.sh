#!/usr/bin/env bash
set -euo pipefail

# ==== Parametreler ====
CALICO_VER="${CALICO_VER:-v3.28.2}"
IMG_DIR="${IMG_DIR:-assets/images}"
NS="kube-system"

# Manifest dosyası
CALICO_MANIFEST="${1:-manifests/calico.yaml}"

# İmaj liste (manifest ile birebir aynı olmalı)
IMAGES=(
  "docker.io/calico/node:${CALICO_VER}"
  "docker.io/calico/cni:${CALICO_VER}"
  "docker.io/calico/kube-controllers:${CALICO_VER}"
  "docker.io/calico/typha:${CALICO_VER}"
)

echo "==> [1/4] Calico imajlarını içeri al (ctr import)"
for ref in "${IMAGES[@]}"; do
  safe="$(echo "${ref}" | tr '/:@' '___')".tar
  # parçaları birleştir
  if ls "${IMG_DIR}/${safe}.part-"* >/dev/null 2>&1; then
    echo "  -> ${ref}"
    tmp="/tmp/${safe}"
    cat "${IMG_DIR}/${safe}.part-"* > "${tmp}"
    sudo ctr -n k8s.io images import "${tmp}"
    rm -f "${tmp}"
  else
    echo "  !! Parçalar yok: ${IMG_DIR}/${safe}.part-* (atlandı)"
  fi
done

# İsteğe bağlı: manifest başka registry kullanıyorsa alias tag at
# (Bu örnekte manifest Docker Hub kullanıyor; gerek yok.
#  Eğer 'quay.io/tigera/...' kullanacaksan, aşağıdakileri aç.)
if false; then
  sudo ctr -n k8s.io images tag "docker.io/calico/node:${CALICO_VER}" "quay.io/tigera/node:${CALICO_VER}" || true
  sudo ctr -n k8s.io images tag "docker.io/calico/cni:${CALICO_VER}" "quay.io/tigera/cni:${CALICO_VER}" || true
  sudo ctr -n k8s.io images tag "docker.io/calico/kube-controllers:${CALICO_VER}" "quay.io/tigera/kube-controllers:${CALICO_VER}" || true
  sudo ctr -n k8s.io images tag "docker.io/calico/typha:${CALICO_VER}" "quay.io/tigera/typha:${CALICO_VER}" || true
fi

echo "==> [2/4] Eski flannel kalıntılarını temizle (varsa)"
kubectl delete -n kube-flannel ds/kube-flannel-ds --ignore-not-found
kubectl delete ns kube-flannel --ignore-not-found
sudo rm -f /etc/cni/net.d/10-flannel.conflist 2>/dev/null || true

echo "==> [3/4] Calico manifest uygula: ${CALICO_MANIFEST}"
kubectl apply -f "${CALICO_MANIFEST}"

echo "==> [4/4] Sağlık kontrolü (podlar Running olana kadar bekle)"
# Typha, node, controllers
kubectl -n "${NS}" rollout status deploy/calico-typha --timeout=180s || true
kubectl -n "${NS}" rollout status deploy/calico-kube-controllers --timeout=180s || true

# calico-node bir DaemonSet — en az master’da Running görülmeli
kubectl -n "${NS}" rollout status ds/calico-node --timeout=180s || true

echo
echo "==> Durum:"
kubectl -n "${NS}" get pods -o wide | egrep 'calico|coredns|kube-proxy' || true
echo "==> Bitti."

