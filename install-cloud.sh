#!/usr/bin/env bash
set -Eeuo pipefail

curl -fsSL \
  https://raw.githubusercontent.com/AlbanyTechnologies/icarius-installer/main/install-onprem.sh \
  | ICARIUS_BOOTSTRAP_EDITION=cloud bash
