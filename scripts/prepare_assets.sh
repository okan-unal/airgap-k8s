#!/usr/bin/env bash
set -euo pipefail

# ========= Versiyonlar =========
K8S_VER="${K8S_VER:-v1.32.9}"
ETCD_VER="${ETCD_VER:-3.5.16-0}"
COREDNS_VER="${COREDNS_VER:-v1.11.3}"
PAUSE_TAG="${PAUSE_TAG:-3.10}"

CALICO_VER="${CALICO_VER:-v3.28.2}"

# (Opsiyonel) RPM versiyonları
KUBE_RPM_VER="${KUBE_RPM_VER:-1.32.9-0}"   # kubeadm/kubelet/kubectl için
CONTAINERD_PKG="${CONTAINERD_PKG:-containerd}"  # RHEL türevlerinde genelde 'containerd'
CRICTL_VER="${CRICTL_VER:-v1.32.0}"        # crictl tar.gz (opsiyonel)

# ========= Çıkış dizinleri =========
mkdir -p assets/images assets/rpms assets/tools
SPLIT_SIZE="${SPLIT_SIZE:-95m}"

echo "==> K8s core images ${K8S_VER}"
K8S_IMAGES=(
  "registry.k8s.io/kube-apiserver:${K8S_VER}"
  "registry.k8s.io/kube-controller-manager:${K8S_VER}"
  "registry.k8s.io/kube-scheduler:${K8S_VER}"
  "registry.k8s.io/kube-proxy:${K8S_VER}"
  "registry.k8s.io/pause:${PAUSE_TAG}"
  "registry.k8s.io/etcd:${ETCD_VER}"
  "registry.k8s.io/coredns/coredns:${COREDNS_VER}"
)

echo "==> Calico images (amd64) ${CALICO_VER}"
CALICO_IMAGES=(
  "docker://docker.io/calico/node:${CALICO_VER}"
  "docker://docker.io/calico/cni:${CALICO_VER}"
  "docker://docker.io/calico/kube-controllers:${CALICO_VER}"
  "docker://docker.io/calico/typha:${CALICO_VER}"
)

# ----- Calico imajlarını skopeo ile kaydet -----
for SRC in "${CALICO_IMAGES[@]}"; do
  SAFE="$(echo "${SRC#docker://}" | tr '/:@' '___')"
  OUT="/out/${SAFE}.tar"
  echo "==> copy (amd64): ${SRC} -> assets/images/${SAFE}.tar"
  docker run --rm -v "$PWD/assets/images:/out" quay.io/skopeo/stable:latest \
    copy --override-arch=amd64 --override-os=linux --retry-times=3 \
    "${SRC}" "docker-archive:${OUT}:${SRC#docker://}"
  echo "==> split: assets/images/${SAFE}.tar.part-*"
  split -b "${SPLIT_SIZE}" "assets/images/${SAFE}.tar" "assets/images/${SAFE}.tar.part-"
  rm -f "assets/images/${SAFE}.tar"
done

# ----- Genel kayıt fonksiyonu (k8s core) -----
save_img() {
  local src="$1"
  local safe="assets/images/$(echo "$src" | tr '/:@' '___').tar"
  echo "==> copy (amd64): $src -> $safe"
  docker run --rm -v "$PWD/assets/images:/out" quay.io/skopeo/stable:latest \
    copy --override-arch=amd64 --override-os=linux --retry-times=3 \
    docker://"$src" docker-archive:/out/"$(basename "$safe")":"$src"
  echo "==> split: ${safe}.part-*"
  split -b "$SPLIT_SIZE" "$safe" "${safe}.part-"
  rm -f "$safe"
}

for img in "${K8S_IMAGES[@]}"; do
  save_img "$img"
done

# ----- README -----
cat > assets/images/README.txt <<'EOF'
Bu klasördeki *.tar.part-* parçalarını offline node üzerinde birleştirip:
  cat <ad>.tar.part-* > /tmp/<ad>.tar
sonra:
  ctr -n k8s.io images import /tmp/<ad>.tar
ile içeri alın. (amd64 arşivdir)
EOF

# ===== (Opsiyonel) RPM’leri indir =====
# RHEL/Rocky/Alma 9 tabanlı offline kurulum için faydalı: kubeadm/kubelet/kubectl + containerd
if command -v dnf >/dev/null 2>&1; then
  echo "==> RPM paketleri indiriliyor (kubeadm/kubelet/kubectl/containerd)"
  mkdir -p assets/rpms
  # Kubernetes repo etkin olmalı. Gerekirse:
  # sudo tee /etc/yum.repos.d/kubernetes.repo >/dev/null <<REPO
  # [kubernetes]
  # name=Kubernetes
  # baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
  # enabled=1
  # gpgcheck=0
  # REPO

  dnf download --resolve -y \
    kubeadm-"${KUBE_RPM_VER}" \
    kubelet-"${KUBE_RPM_VER}" \
    kubectl-"${KUBE_RPM_VER}" \
    ${CONTAINERD_PKG}

  mv -v ./*.rpm assets/rpms/ || true
  echo "==> RPM’ler assets/rpms/ altına alındı."
else
  echo "⚠ dnf bulunamadı; RPM indirme adımı atlandı."
fi

# ===== (Opsiyonel) crictl aracı =====
# Çoğu zaman faydalı; offline tar.gz taşımak kolay.
CRICTL_TGZ="crictl-${CRICTL_VER}-linux-amd64.tar.gz"
if [ ! -f "assets/tools/${CRICTL_TGZ}" ]; then
  echo "==> crictl arşivi indiriliyor: ${CRICTL_TGZ}"
  curl -fL -o "assets/tools/${CRICTL_TGZ}" \
    "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VER}/${CRICTL_TGZ}" || true
fi

echo "✅ Hazır. assets/images, assets/rpms ve assets/tools dolduruldu."

