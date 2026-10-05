#!/usr/bin/env bash
set -Eeuo pipefail

curl -fsSL \
  -H 'Accept: application/vnd.github.raw+json' \
  -H 'Cache-Control: no-cache' \
  -H 'Pragma: no-cache' \
  "https://api.github.com/repos/AlbanyTechnologies/icarius-installer/contents/install-onprem.sh?ref=main&nocache=$(date +%s)" \
  | ICARIUS_BOOTSTRAP_EDITION=cloud bash
