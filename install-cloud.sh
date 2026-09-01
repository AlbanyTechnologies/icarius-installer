#!/usr/bin/env bash
set -Eeuo pipefail

curl -fsSL \
  -H 'Cache-Control: no-cache' \
  -H 'Pragma: no-cache' \
  "https://raw.githubusercontent.com/AlbanyTechnologies/icarius-installer/main/install-onprem.sh?nocache=$(date +%s)" \
  | ICARIUS_BOOTSTRAP_EDITION=cloud bash
