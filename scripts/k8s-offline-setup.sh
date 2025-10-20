#!/usr/bin/env bash
set -euo pipefail

# Tek script ile OFFLINE Kubernetes kurulum (RHEL/Rocky/Alma 9)
# - Repo içeriği: assets/rpms, assets/images, manifests/kube-flannel.yml
# - Çalıştırınca MODE sorar: [1] Master (control-plane)  [2] Worker (node)
# - Worker modunda JOIN komutunu otomatik ÇALIŞTIRMAZ; sen manuel yapıştırırsın.

# ------- Varsayılanlar -------
K8S_VER="${K8S_VER:-v1.32.9}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
PAUSE_TAG="${PAUSE_TAG:-3.10}"
# kubeadm v1.32.9 tipik olarak etcd:3.5.16-0 bekliyor; elimizde 3.5.15-0 olabilir:
ETCD_EXPECT="${ETCD_EXPECT:-3.5.16-0}"
ETCD_HAVE_FALLBACK="${ETCD_HAVE_FALLBACK:-3.5.15-0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_RPMS="$ROOT/assets/rpms"
ASSETS_IMGS="$ROOT/assets/images"
MANIFESTS="$ROOT/manifests"

step() { printf "\033[36m==> %s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✔ %s\033[0m\n" "$*"; }
warn() { printf "\033[33m⚠ %s\033[0m\n" "$*"; }

# root değilse sudo ile tekrar çalıştır
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E \
    K8S_VER="$K8S_VER" POD_CIDR="$POD_CIDR" PAUSE_TAG="$PAUSE_TAG" \
    ETCD_EXPECT="$ETCD_EXPECT" ETCD_HAVE_FALLBACK="$ETCD_HAVE_FALLBACK" \
    bash "$0" "$@"
fi

echo
echo "================ Offline Kubernetes Kurulum ================"
echo "Mod seçin:"
echo "  [1] Master (control-plane) — kubeadm init + flannel"
echo "  [2] Worker (node)         — sadece hazırlık (join komutunu sen yapıştıracaksın)"
echo -n "Seçiminiz [1/2] (varsayılan 1): "
read -r REPLY
case "${REPLY:-1}" in
  1|"") MODE="MASTER" ;;
  2)     MODE="WORKER" ;;
  *)     echo "Geçersiz seçim. 1 (MASTER) seçildi."; MODE="MASTER" ;;
esac
echo "Seçilen mod: $MODE"
echo "============================================================"
echo

# ---------- 0) Proxy/NO_PROXY (proxy varsa 403 yememek için) ----------
step "0) Proxy ortam değişkenleri (NO_PROXY) uygula"
MASTER_IP_GUESS="$(ip -4 addr | awk '/state UP/{f=1} f && /inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
CLUSTER_NO_PROXY="127.0.0.1,localhost,*.svc,.cluster.local,10.96.0.0/12,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
[ -n "$MASTER_IP_GUESS" ] && CLUSTER_NO_PROXY="$CLUSTER_NO_PROXY,$MASTER_IP_GUESS"
export NO_PROXY="${NO_PROXY:-$CLUSTER_NO_PROXY}"
export no_proxy="$NO_PROXY"

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
ok "NO_PROXY uygulandı: $NO_PROXY"

# ---------- 1) OS hazırlıkları ----------
step "1) OS hazırlıkları (SELinux permissive, swap off, modüller, sysctl)"
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

# ---------- 2) RPM kurulum ----------
step "2) RPM'ler (kubeadm/kubelet/kubectl/containerd) offline kurulum"
need=(kubeadm kubelet kubectl containerd)
miss=()
for p in "${need[@]}"; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
if [ "${#miss[@]}" -gt 0 ]; then
  if ls "$ASSETS_RPMS"/*.rpm >/dev/null 2>&1; then
    dnf install -y "$ASSETS_RPMS"/*.rpm --setopt=install_weak_deps=False
  else
    echo "assets/rpms içinde RPM bulunamadı. Çıkılıyor."; exit 1
  fi
fi
systemctl enable --now containerd kubelet
ok "Paketler kurulu"

# ---------- 3) containerd ayarı ----------
step "3) containerd ayarı (SystemdCgroup=true, pause:${PAUSE_TAG})"
mkdir -p /etc/containerd
[ -f /etc/containerd/config.toml ] || containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
if grep -q 'sandbox_image' /etc/containerd/config.toml; then
  sed -i "s#^\(\s*sandbox_image = \).*\$#\1\"registry.k8s.io/pause:${PAUSE_TAG}\"#g" /etc/containerd/config.toml
fi
systemctl restart containerd
ok "containerd hazır"

# ---------- 4) İmaj import ----------
step "4) İmaj arşivlerini birleştir ve import et"
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

# ---------- 4.1) Etcd tag fix (3.5.15-0 -> 3.5.16-0) ----------
if ! ctr -n k8s.io images ls | grep -q "registry.k8s.io/etcd:${ETCD_EXPECT}"; then
  if ctr -n k8s.io images ls | grep -q "registry.k8s.io/etcd:${ETCD_HAVE_FALLBACK}"; then
    step "Etcd tag düzeltme: ${ETCD_HAVE_FALLBACK} -> ${ETCD_EXPECT}"
    ctr -n k8s.io images tag "registry.k8s.io/etcd:${ETCD_HAVE_FALLBACK}" "registry.k8s.io/etcd:${ETCD_EXPECT}"
    ok "Etcd retag yapıldı"
  fi
fi

# ---------- 4.2) Flannel imaj adı uyumu ----------
# Manifest bazen ghcr.io/flannel-io/flannel:v0.27.4 isteyebilir; elimizde docker.io/flannel/flannel:v0.27.4 varsa retagla
if ctr -n k8s.io images ls | grep -q 'docker.io/flannel/flannel:v0.27.4'; then
  if ! ctr -n k8s.io images ls | grep -q 'ghcr.io/flannel-io/flannel:v0.27.4'; then
    step "Flannel retag: docker.io/flannel/flannel:v0.27.4 -> ghcr.io/flannel-io/flannel:v0.27.4"
    ctr -n k8s.io images tag docker.io/flannel/flannel:v0.27.4 ghcr.io/flannel-io/flannel:v0.27.4 || true
  fi
fi

# ---------- 5) (opsiyonel) Firewalld ----------
step "5) (Opsiyonel) firewalld kuralları"
if systemctl is-active --quiet firewalld; then
  # kubelet
  firewall-cmd --permanent --add-port=10250/tcp || true
  # Flannel VXLAN
  firewall-cmd --permanent --add-port=4789/udp || true
  # Control-plane ek portlar master için (aşağıda tekrar ele alınacak)
  if [ "$MODE" = "MASTER" ]; then
    firewall-cmd --permanent --add-port=6443/tcp || true
    firewall-cmd --permanent --add-port=2379-2380/tcp || true
    firewall-cmd --permanent --add-port=10257/tcp || true
    firewall-cmd --permanent --add-port=10259/tcp || true
  fi
  # NodePort aralığı (ihtiyacına göre)
  firewall-cmd --permanent --add-port=30000-32767/tcp || true
  firewall-cmd --reload || true
fi
ok "Firewall kuralları uygulandı (varsa)"

# ---------- 6) MASTER ----------
if [ "$MODE" = "MASTER" ]; then
  step "6) kubeadm init"
  # önce güvenli temizlik (idempotent)
  kubeadm reset -f || true
  systemctl restart kubelet containerd

  kubeadm init \
    --kubernetes-version "${K8S_VER}" \
    --pod-network-cidr "${POD_CIDR}" \
    --cri-socket unix:///run/containerd/containerd.sock

  step "7) kubeconfig kullanıcıya ver"
  INV="${SUDO_USER:-$USER}"
  HOME_DIR="$(getent passwd "$INV" | cut -d: -f6 2>/dev/null || echo "/home/$INV")"
  mkdir -p "${HOME_DIR}/.kube"
  cp -i /etc/kubernetes/admin.conf "${HOME_DIR}/.kube/config"
  chown "$(id -u "$INV"):$(id -g "$INV")" "${HOME_DIR}/.kube/config"

  step "8) Flannel uygula"
  if [ -f "$MANIFESTS/kube-flannel.yml" ]; then
    su - "$INV" -c "kubectl apply -f '$MANIFESTS/kube-flannel.yml'"
  else
    warn "manifests/kube-flannel.yml bulunamadı; ağı kendin uygulamalısın."
  fi

  step "9) Join komutu"
  kubeadm token create --print-join-command || true
  ok "Master kurulum tamamlandı 🎉  'kubectl get nodes -w' ile izleyebilirsin."
  exit 0
fi

# ---------- 6) WORKER ----------
if [ "$MODE" = "WORKER" ]; then
  step "6) Worker hazır — join komutunu MANUEL olarak çalıştıracaksın."
  echo
  echo "Örnek:"
  echo "  kubeadm join <MASTER_IP>:6443 --token <TOKEN> \\"
  echo "    --discovery-token-ca-cert-hash sha256:<HASH> \\"
  echo "    --cri-socket unix:///run/containerd/containerd.sock"
  echo
  ok "Worker hazırlıkları bitti. Join komutunu master’dan alıp bu node’da yapıştır."
  exit 0
fi

