#!/usr/bin/env bash
set -euo pipefail

# Versiyonlar
K8S_VER="v1.32.9"
CALICO_VER="v3.28.2"

# (Flannel kullanmayacaksan bu iki satır gereksiz; istersen sil)
FLANNEL_VER="v0.27.4"
FLANNEL_IMG="docker.io/flannel/flannel:${FLANNEL_VER}"
FLANNEL_CNI_IMG="ghcr.io/flannel-io/flannel-cni-plugin:v1.8.0-flannel1"

# Çıkış klasörü ve parça boyutu (Calico döngüsünden ÖNCE!)
mkdir -p assets/images
SPLIT_SIZE="95m"

# Çekilecek imajlar (flannel satırlarını istersen kaldır)
IMAGES=(
  "registry.k8s.io/kube-apiserver:${K8S_VER}"
  "registry.k8s.io/kube-controller-manager:${K8S_VER}"
  "registry.k8s.io/kube-scheduler:${K8S_VER}"
  "registry.k8s.io/kube-proxy:${K8S_VER}"
  "registry.k8s.io/pause:3.10"
  "registry.k8s.io/etcd:3.5.16-0"                # <-- düzeltildi
  "registry.k8s.io/coredns/coredns:v1.11.3"
  # "${FLANNEL_IMG}"                              # flannel kullanmıyorsan yorumda bırak
  # "${FLANNEL_CNI_IMG}"
)

echo "==> Calico images (amd64) ${CALICO_VER}"
CALICO_IMAGES=(
  "docker://docker.io/calico/node:${CALICO_VER}"
  "docker://docker.io/calico/cni:${CALICO_VER}"
  "docker://docker.io/calico/kube-controllers:${CALICO_VER}"
  "docker://docker.io/calico/typha:${CALICO_VER}"
)

# Calico imajlarını skopeo ile docker-archive olarak kaydet + parçala
for SRC in "${CALICO_IMAGES[@]}"; do
  SAFE="$(echo "${SRC#docker://}" | tr '/:@' '___')"     # ör: docker.io_calico_node_v3.28.2
  OUT="/out/${SAFE}.tar"
  echo "==> copy (amd64): ${SRC} -> assets/images/${SAFE}.tar"
  docker run --rm \
    -v "$PWD/assets/images:/out" \
    quay.io/skopeo/stable:latest \
      copy --override-arch=amd64 --override-os=linux \
           --retry-times=3 \
           "${SRC}" \
           "docker-archive:${OUT}:${SRC#docker://}"
  echo "==> split: assets/images/${SAFE}.tar.part-*"
  split -b "${SPLIT_SIZE}" "assets/images/${SAFE}.tar" "assets/images/${SAFE}.tar.part-"
  rm -f "assets/images/${SAFE}.tar"
done

# Genel kayıt fonksiyonu
save_img() {
  local src="$1"
  local safe out
  safe="$(echo "$src" | tr '/:@' '___')"
  out="assets/images/${safe}.tar"

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

# K8s çekirdek imajlarını kaydet
for img in "${IMAGES[@]}"; do
  save_img "$img"
done

# Kısa bilgi
cat > assets/images/README.txt <<'EOF'
Bu klasördeki *.tar.part-* parçaları offline tarafta birleştirip:
  cat <ad>.tar.part-* > /tmp/<ad>.tar
ve sonra:
  ctr -n k8s.io images import /tmp/<ad>.tar
ile içeri alın. (amd64 arşivdir)
EOF

