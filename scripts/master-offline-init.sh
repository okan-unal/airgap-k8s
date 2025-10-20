#!/usr/bin/env bash
set -euo pipefail

# master-offline-init.sh
# - Çalıştırınca mod sorar: [1] PINNED (offline güvenli, önerilen)  [2] DEFAULT (internet gerekir)
# - PINNED: etcd imajını repodaki 3.5.15-0’a pinler, tamamen offline ilerler.
# - DEFAULT: kubeadm kendi default imajlarını pull eder (internetsiz ortamda başarısız olur).

# ---- Varsayılanlar ----
K8S_VER="${K8S_VER:-v1.32.9}"
ETCD_TAG_PINNED="${ETCD_TAG_PINNED:-3.5.15-0}"
PAUSE_TAG="${PAUSE_TAG:-3.10}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_RPMS="$ROOT/assets/rpms"
ASSETS_IMGS="$ROOT/assets/images"
MANIFESTS="$ROOT/manifests"

# root değilse kendini sudo ile tekrar çalıştır
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E K8S_VER="$K8S_VER" ETCD_TAG_PINNED="$ETCD_TAG_PINNED" PAUSE_TAG="$PAUSE_TAG" POD_CIDR="$POD_CIDR" bash "$0" "$@"
fi

echo
echo "================ Kubernetes Master Kurulumu ================"
echo "Kurulum modu seçin:"
echo "  [1] PINNED  (OFFLINE güvenli, önerilen)"
echo "  [2] DEFAULT (internet gerekir; kubeadm imajları pull eder)"
echo -n "Seçiminiz [1/2] (varsayılan 1): "
read -r REPLY
case "${REPLY:-1}" in
  1|"") MODE="PINNED" ;;
  2)     MODE="DEFAULT" ;;
  *)     echo "Geçersiz seçim. 1 (PINNED) kabul edildi."; MODE="PINNED" ;;
esac
echo "Seçilen mod: $MODE"
echo "============================================================"
echo

step() { printf "\033[36m==> %s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✔ %s\033[0m\n" "$*"; }
warn() { printf "\033[33m⚠ %s\033[0m\n" "$*"; }

step "0) OS ayarları (SELinux permissive, swap kapalı, modüller, sysctl)"
setenforce 0 || true
sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=permissive/' /etc/sysconfig/selinux || true
swapoff -a || true
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab || true

cat >/etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system
ok "OS hazır"

step "1) Gerekli paket kontrolü (kubeadm/kubelet/kubectl/containerd)"
need_pkgs=( kubeadm kubelet kubectl containerd )
miss=()
for p in "${need_pkgs[@]}"; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
if [ "${#miss[@]}" -gt 0 ]; then
  if ls "$ASSETS_RPMS"/*.rpm >/dev/null 2>&1; then
    dnf install -y "$ASSETS_RPMS"/*.rpm --setopt=install_weak_deps=False
  else
    echo "Gerekli RPM'ler eksik (assets/rpms bulunamadı). Çıkılıyor."; exit 1
  fi
fi
systemctl enable --now containerd kubelet
ok "Paketler tamam"

step "2) containerd ayarı (SystemdCgroup=true, pause:${PAUSE_TAG})"
mkdir -p /etc/containerd
[ -f /etc/containerd/config.toml ] || containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
if grep -q 'sandbox_image' /etc/containerd/config.toml; then
  sed -i "s#^\(\s*sandbox_image = \).*\$#\1\"registry.k8s.io/pause:${PAUSE_TAG}\"#g" /etc/containerd/config.toml
else
  warn "config.toml içinde sandbox_image bulunamadı, varsayılan kalacak."
fi
systemctl restart containerd
ok "containerd hazır"

step "3) İmaj arşivlerini (varsa) birleştir & import et"
shopt -s nullglob
for first in "$ASSETS_IMGS"/*.tar.part-*; do
  base="${first%.part-*}"
  [ -f "$base" ] || { echo "   -> rebuild: $(basename "$base")"; cat "$base".part-* > "$base"; }
done
found=0
for tarball in "$ASSETS_IMGS"/*.tar; do
  found=1
  echo "   -> import: $(basename "$tarball")"
  ctr -n k8s.io images import --all-platforms "$tarball"
done
[ "$found" -eq 1 ] && ok "İmajlar import edildi" || warn "assets/images altında .tar bulunamadı (DEFAULT moddaysanız sorun değil)."

step "4) kubeadm init (MODE=${MODE})"
CRI="--cri-socket unix:///run/containerd/containerd.sock"
if [ "$MODE" = "PINNED" ]; then
  cat >/root/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta5
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VER}
imageRepository: registry.k8s.io
etcd:
  local:
    imageRepository: registry.k8s.io/etcd
    imageTag: "${ETCD_TAG_PINNED}"
dns:
  type: CoreDNS
---
apiVersion: kubeadm.k8s.io/v1beta5
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
EOF
  kubeadm init --config /root/kubeadm-config.yaml
else
  kubeadm init --kubernetes-version "${K8S_VER}" --pod-network-cidr "${POD_CIDR}" ${CRI}
fi
ok "kubeadm init tamam"

step "5) kubeconfig ayarı"
INV="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$INV" | cut -d: -f6 2>/dev/null || echo "/home/$INV")"
mkdir -p "${HOME_DIR}/.kube"
cp /etc/kubernetes/admin.conf "${HOME_DIR}/.kube/config"
chown "$(id -u "$INV"):$(id -g "$INV")" "${HOME_DIR}/.kube/config"
ok "kubeconfig verildi: ${HOME_DIR}/.kube/config"

step "6) Flannel uygulaması"
if [ -f "$MANIFESTS/kube-flannel.yml" ]; then
  su - "$INV" -c "kubectl apply -f '$MANIFESTS/kube-flannel.yml'"
  ok "Flannel uygulandı"
else
  warn "manifests/kube-flannel.yml bulunamadı; ağı kendin uygulamalısın."
fi

step "7) Join komutu"
kubeadm token create --print-join-command || true

echo
ok "Master kurulum tamamlandı 🎉  'kubectl get nodes -w' ile Ready durumunu izleyebilirsin."

