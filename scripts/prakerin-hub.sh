#!/bin/bash
# CONTENT_TYPE: redirect
# CONTENT_URI_RAW: https://raw.githubusercontent.com/tkjskanesga/prakerin-hub/refs/heads/main/auto-installer.sh

if ! command -v curl &> /dev/null; then
  echo "[x] Need curl to running this script!"
  exit 1
fi

curl -fsSL https://raw.githubusercontent.com/tkjskanesga/prakerin-hub/refs/heads/main/auto-installer.sh | bash
