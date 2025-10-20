#!/usr/bin/env bash
set -euo pipefail

# Versiyonlar
K8S_VER="v1.32.9"
FLANNEL_VER="v0.27.4"

# Flannel imajları:
# Seçenek A (Docker Hub): flannel/flannel-cni-plugin:v1.4.0-flannel1
# Seçenek B (Önerilen, flannel 0.27.4 ile eşleşir): ghcr.io/flannel-io/flannel-cni-plugin:v1.8.0-flannel1
FLANNEL_IMG="docker.io/flannel/flannel:${FLANNEL_VER}"
FLANNEL_CNI_IMG="ghcr.io/flannel-io/flannel-cni-plugin:v1.8.0-flannel1"

IMAGES=(
  "registry.k8s.io/kube-apiserver:${K8S_VER}"
  "registry.k8s.io/kube-controller-manager:${K8S_VER}"
  "registry.k8s.io/kube-scheduler:${K8S_VER}"
  "registry.k8s.io/kube-proxy:${K8S_VER}"
  "registry.k8s.io/pause:3.10"
  "registry.k8s.io/etcd:3.5.15-0"
  "registry.k8s.io/coredns/coredns:v1.11.3"
  "${FLANNEL_IMG}"
  "${FLANNEL_CNI_IMG}"
)

mkdir -p assets/images
SPLIT_SIZE="95m"

save_img() {
  local src="$1"
  local safe
  safe="$(echo "$src" | tr '/:@' '___')"
  local out="assets/images/${safe}.tar"

  echo "==> copy (amd64): $src -> $out"
  docker run --rm \
    -v "$PWD/assets/images:/out" \
    quay.io/skopeo/stable:latest \
      copy --override-arch=amd64 --override-os=linux \
           --retry-times=3 \
           docker://"$src" \
           docker-archive:/out/"${safe}.tar":"$src"

  echo "==> split: ${out}.part-*"
  split -b "$SPLIT_SIZE" "$out" "${out}.part-"
  rm -f "$out"
}

for img in "${IMAGES[@]}"; do
  save_img "$img"
done

cat > assets/images/README.txt <<'EOF'
Bu klasördeki *.tar.part-* parçaları offline tarafta birleştirilip
ctr -n k8s.io images import --all-platforms <dosya.tar> ile içeri alınır.
EOF

