#!/usr/bin/env bash
# install-docker.sh — Install Docker + add current user to docker group (multi-distro)
# Supports: Debian, Ubuntu, Fedora, Arch, AlmaLinux, Rocky Linux, openSUSE, Alpine
set -euo pipefail

DOCKER_USER="${1:-${DOCKER_USER:-${SUDO_USER:-$USER}}}"

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${ID,,}"
  else
    echo "unknown"
  fi
}

install_docker() {
  local distro
  distro=$(detect_distro)

  case "$distro" in
    ubuntu|debian|linuxmint|pop)
      apt-get update -qq
      apt-get install -y ca-certificates curl gnupg lsb-release
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${distro}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${distro} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    fedora)
      dnf -y install dnf-plugins-core
      dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
      dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    centos|almalinux|rocky|rhel)
      dnf -y install dnf-plugins-core
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    arch|manjaro|endeavouros)
      pacman -Sy --noconfirm docker docker-compose
      ;;
    opensuse*|sles)
      zypper install -y docker docker-compose
      ;;
    alpine)
      apk add --no-cache docker docker-cli-compose
      rc-update add docker default
      service docker start
      ;;
    *)
      echo "Distro '$distro' not recognized. Try installing Docker manually."
      exit 1
      ;;
  esac
}

[[ "$EUID" -ne 0 ]] && {
  echo "Usage:"
  echo "  sudo $0 [username]"
  echo "  curl -fsSL https://storescript.lenaca.workers.dev/install-docker.sh | sudo bash -s -- [username]"
  echo "  curl -fsSL https://storescript.lenaca.workers.dev/install-docker.sh | sudo bash"
  exit 1
}

echo "==> Installing Docker..."
install_docker

echo "==> Enabling & starting Docker service..."
if command -v systemctl &>/dev/null; then
  systemctl enable --now docker
fi

echo "==> Adding user '$DOCKER_USER' to docker group..."
if ! getent group docker &>/dev/null; then
  groupadd docker
fi
usermod -aG docker "$DOCKER_USER"

echo ""
echo "✓ Docker installed successfully."
echo "  Versi: $(docker --version)"
echo ""
echo "  User '$DOCKER_USER' has been added to the 'docker' group."
echo "  Logout and login again for the group changes to take effect,"
echo "  or run: newgrp docker"
