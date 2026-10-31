#!/bin/sh

curl -fsSL https://tailscale.com/install.sh | sh
if command -v sudo >/dev/null 2>&1; then
  sudo tailscale up --advertise-exit-node
else
  tailscale up --advertise-exit-node
fi
