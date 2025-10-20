#!/usr/bin/env bash
set -euo pipefail

# Offline worker join script
# - RHEL/Rocky/Alma 9 tabanlı sistem için.
# - Repo içindeki assets/rpms ve assets/images kullanır.
# - Join komutunu ENV (KUBEADM_JOIN) veya repo kökünde join.txt'den alır.
#
# Kullanım ör:
#   sudo KUBEADM_JOIN="kubeadm join <MASTER_IP>:6443 --token ... --discovery-token-ca-cert-hash sha256:..." \
#        scripts/worker-offline-join.sh
#   # veya
#   echo 'kubeadm join <MASTER_IP>:6443 --token ... --discovery-token-ca-cert-hash sha256:...' > join.txt
#   sudo scripts/worker-offline-join.sh
#
# Opsiyonel: MASTER_IP ortam değişkeni NO_PROXY’ye eklenir.
#   sudo MASTER_IP=10.85.42.30 scripts/worker-offline-join.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_RPMS="$ROOT/assets/rpms"
ASSETS_IMGS="$ROOT/assets/images"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"  # flannel default
PAUSE_TAG="${PAUSE_TAG:-3.10}"

step() { printf "\033[36m==> %s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✔ %s\033[0m\n" "$*"; }
warn() { printf "\033[33m⚠ %s\033[0m\n" "$*"; }

# root değilse sudo ile tekrar çalıştır
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E MASTER_IP="${MASTER_IP:-}" POD_CIDR="$POD_CIDR" PAUSE_TAG="$PAUSE_TAG" bash "$0" "$@"
fi

step "0) Proxy ortam değişkenlerini ayarla (NO_PROXY dahil)"
# Shell için (kubectl vb. gerekmeyebilir ama iyi olur)
CLUSTER_NO_PROXY="127.0.0.1,localhost,*.svc,.cluster.local,10.96.0.0/12,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
if [ -n "${MASTER_IP:-}" ]; then
  CLUSTER_NO_PROXY="$CLUSTER_NO_PROXY,${MASTER_IP}"
fi
# oturum için
export NO_PROXY="${NO_PROXY:-$CLUSTER_NO_PROXY}"
export no_proxy="$NO_PROXY"
# kubelet & containerd servisleri için drop-in (proxy varsa etkilenmesin)
mkdir -p /etc/systemd/system/kubelet.service.d /etc/systemd/system/containerd.service.d
cat >/etc/systemd/system/kubelet.service.d/10-noproxy.conf <<EOF
[Service]
Environment=NO_PROXY=$NO_PROXY
Environment=no_proxy=$NO_PROXY
Environment=HTTP_PROXY=
Environment=http_proxy=
Environment=HTTPS_PROXY=
Environment=https_proxy=
EOF
cat >/etc/systemd/system/containerd.service.d/10-noproxy.conf <<EOF
[Service]
Environment=NO_PROXY=$NO_PROXY
Environment=no_proxy=$NO_PROXY
Environment=HTTP_PROXY=
Environment=http_proxy=
Environment=HTTPS_PROXY=
Environment=https_proxy=
EOF
systemctl daemon-reload

step "1) OS hazırlığı (SELinux permissive, swap kapalı, modüller, sysctl)"
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

step "2) Paketler (kubeadm/kubelet/kubectl/containerd) — offline kurulum"
need=(kubeadm kubelet kubectl containerd)
miss=()
for p in "${need[@]}"; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
if [ "${#miss[@]}" -gt 0 ]; then
  if ls "$ASSETS_RPMS"/*.rpm >/dev/null 2>&1; then
    dnf install -y "$ASSETS_RPMS"/*.rpm --setopt=install_weak_deps=False
  else
    echo "assets/rpms içinde rpm bulunamadı. Çıkılıyor."; exit 1
  fi
fi
systemctl enable --now containerd kubelet
ok "Paketler hazır"

step "3) containerd ayarı (SystemdCgroup=true, pause:${PAUSE_TAG})"
mkdir -p /etc/containerd
[ -f /etc/containerd/config.toml ] || containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
# sandbox_image satırını güncelle (varsa)
if grep -q 'sandbox_image' /etc/containerd/config.toml; then
  sed -i "s#^\(\s*sandbox_image = \).*\$#\1\"registry.k8s.io/pause:${PAUSE_TAG}\"#g" /etc/containerd/config.toml
fi
systemctl restart containerd
ok "containerd hazır"

step "4) İmaj arşivlerini birleştir ve import et (varsa)"
shopt -s nullglob
for first in "$ASSETS_IMGS"/*.tar.part-*; do
  base="${first%.part-*}"
  [ -f "$base" ] || { echo "   -> rebuild: $(basename "$base")"; cat "$base".part-* > "$base"; }
done
found=0
for t in "$ASSETS_IMGS"/*.tar; do
  found=1
  echo "   -> import: $(basename "$t")"
  ctr -n k8s.io images import --all-platforms "$t"
done
[ "$found" -eq 1 ] && ok "İmajlar import edildi" || warn "assets/images altında .tar yok; repository’yi eksiksiz çektiğinden emin ol."

step "5) (opsiyonel) firewalld kuralları"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=10250/tcp || true
  firewall-cmd --permanent --add-port=4789/udp || true     # flannel VXLAN
  firewall-cmd --permanent --add-port=30000-32767/tcp || true
  firewall-cmd --reload || true
fi

step "6) Join komutunu al"
JOIN_CMD=""
if [ -n "${KUBEADM_JOIN:-}" ]; then
  JOIN_CMD="$KUBEADM_JOIN"
elif [ -f "$ROOT/join.txt" ]; then
  JOIN_CMD="$(tr -d '\n' < "$ROOT/join.txt")"
fi
if [ -z "$JOIN_CMD" ]; then
  echo "Join komutu bulunamadı. ENV KUBEADM_JOIN ile veya repo köküne join.txt koyarak verin."; exit 1
fi
# containerd CRI eklenmemişse ekle
case "$JOIN_CMD" in
  *"--cri-socket "*) : ;;
  *) JOIN_CMD="$JOIN_CMD --cri-socket unix:///run/containerd/containerd.sock" ;;
esac
ok "Join: $JOIN_CMD"

step "7) Varsa eski kalan kurulum izlerini temizle (idempotent)"
kubeadm reset -f || true
systemctl restart kubelet containerd

step "8) Cluster’a join"
# shellcheck disable=SC2086
eval $JOIN_CMD

echo
ok "Worker join tamamlandı 🎉  Master’da 'kubectl get nodes' ile kontrol edebilirsin."
echo "Kubelet log (son 20 satır) için: journalctl -u kubelet --no-pager -n 20"

