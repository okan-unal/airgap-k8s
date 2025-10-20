#!/usr/bin/env bash
set -euo pipefail

# === Parametreler ===
K8S_VER="${K8S_VER:-v1.32.9}"
FLANNEL_VER="${FLANNEL_VER:-v0.27.4}"
FLANNEL_CNI_TAG="${FLANNEL_CNI_TAG:-ghcr.io/flannel-io/flannel-cni-plugin:v1.8.0-flannel1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPMS="$ROOT/assets/rpms"
IMGS="$ROOT/assets/images"
BINS="$ROOT/assets/bins"
MAN="$ROOT/manifests"

pass(){ printf "\033[32m✔ %s\033[0m\n" "$*"; }
fail(){ printf "\033[31m✘ %s\033[0m\n" "$*" >&2; exit 1; }
info(){ printf "\033[36m➜ %s\033[0m\n" "$*"; }

[ -d "$RPMS" ] || fail "assets/rpms klasörü yok"
[ -d "$IMGS" ] || fail "assets/images klasörü yok"
[ -d "$MAN"  ] || fail "manifests klasörü yok"

# --- 1) RPM’ler: var mı ve x86_64 mü? ---
REQ_RPMS=( kubeadm kubelet kubectl kubernetes-cni cri-tools containerd.io )
for p in "${REQ_RPMS[@]}"; do
  if ! ls "$RPMS"/${p}-*.rpm >/dev/null 2>&1; then
    fail "RPM eksik: $p"
  fi
done
file "$RPMS"/*.rpm | awk '!/x86-64|x86_64/ {bad=1} END{if (bad) exit 1}' || fail "Bazı RPM’ler x86_64 değil"
pass "RPM’ler mevcut ve x86_64"

# --- 2) Helm paketi var mı? ---
if ls "$BINS"/helm-*-linux-amd64.tar.gz >/dev/null 2>&1; then
  tar -tzf "$BINS"/helm-*-linux-amd64.tar.gz >/dev/null || fail "Helm arşivi bozuk"
  pass "Helm arşivi mevcut ve okunabilir"
else
  info "Helm arşivi bulunamadı (assets/bins/helm-*-linux-amd64.tar.gz). İsteyerek atladıysan sorun değil."
fi

# --- 3) Flannel manifest tag kontrolü ---
[ -f "$MAN/kube-flannel.yml" ] || fail "manifests/kube-flannel.yml yok"
grep -Eq "image: .*(flannel:.+$FLANNEL_VER|flannel:${FLANNEL_VER})" "$MAN/kube-flannel.yml" \
  || fail "kube-flannel.yml içinde flannel tag ${FLANNEL_VER} değil"
grep -Eq "image: .*(flannel-cni-plugin:|flannel-io/flannel-cni-plugin:)" "$MAN/kube-flannel.yml" \
  || fail "kube-flannel.yml içinde flannel-cni-plugin image satırı bulunamadı"
pass "Flannel manifest tag’leri görünüyor"

# --- 4) İmaj parçaları: beklenen listenin hepsi var mı? ---
IMAGES=(
  "registry.k8s.io/kube-apiserver:${K8S_VER}"
  "registry.k8s.io/kube-controller-manager:${K8S_VER}"
  "registry.k8s.io/kube-scheduler:${K8S_VER}"
  "registry.k8s.io/kube-proxy:${K8S_VER}"
  "registry.k8s.io/pause:3.10"
  "registry.k8s.io/etcd:3.5.15-0"
  "registry.k8s.io/coredns/coredns:v1.11.3"
  "docker.io/flannel/flannel:${FLANNEL_VER}"
  "${FLANNEL_CNI_TAG}"
)

missing=0
for img in "${IMAGES[@]}"; do
  safe=$(echo "$img" | tr '/:@' '___')
  if ! ls "$IMGS/${safe}.tar.part-"* >/dev/null 2>&1; then
    echo "eksik: $img  ->  $IMGS/${safe}.tar.part-*"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || fail "Bazı imaj parçaları eksik"

pass "Tüm imaj parçaları mevcut"

# --- 5) Örnek bir imajı birleştirip arşivi kontrol et (skopeo ile) ---
# (Diskte yer kaplamaması için /tmp üzerinde sadece 1 taneyi test ediyoruz)
test_img="registry.k8s.io/kube-apiserver:${K8S_VER}"
safe=$(echo "$test_img" | tr '/:@' '___')
tmp="/tmp/${safe}.tar"
cat "$IMGS/${safe}.tar.part-"* > "$tmp"

# skopeo ile arşivi incele (container içinde)
docker run --rm -v /tmp:/tmp quay.io/skopeo/stable:latest \
  inspect --override-arch=amd64 docker-archive:"/tmp/${safe}.tar" >/dev/null \
  || fail "Skopeo inspect başarısız: $test_img arşivi bozuk olabilir"

rm -f "$tmp"
pass "Örnek imaj arşivi (kube-apiserver) düzgün"

# --- 6) Toplam büyüklük/özet ---
info "RPM sayısı: $(ls "$RPMS"/*.rpm | wc -l)"
info "İmaj parça sayısı: $(ls "$IMGS"/*.tar.part-* | wc -l)"
[ -f "$ROOT/assets/SHA256SUMS.txt" ] && info "SHA256SUMS mevcut" || info "İstersen 'assets/SHA256SUMS.txt' üretebilirsin."

pass "Online doğrulama tamam ✅"
