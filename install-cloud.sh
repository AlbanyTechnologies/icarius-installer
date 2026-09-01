#!/usr/bin/env bash
set -Eeuo pipefail

curl -fsSL \
  -H 'Accept: application/vnd.github.raw+json' \
  "https://api.github.com/repos/AlbanyTechnologies/icarius-installer/contents/install-onprem.sh?ref=main" \
  | ICARIUS_BOOTSTRAP_EDITION=cloud bash
