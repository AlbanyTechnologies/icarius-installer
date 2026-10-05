#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="$root/install-onprem.sh"
bash -n "$installer"
bash -n "$root/install-cloud.sh"
bash -n "$root/icarius-host-assistant.sh"
tags='{"tags":["0.0.1","0.0.250","latest","sha-deadbeef","sha256-signature"]}'
selected="$(bash "$installer" --select-preparer-version "$tags")"
[[ "$selected" == 0.0.250 ]] || { echo "Version incorrecta: $selected" >&2; exit 1; }
if bash "$installer" --select-preparer-version '{"tags":["latest","sha-deadbeef"]}' >/dev/null 2>&1; then
  echo 'Se acepto una lista sin versiones numericas.' >&2
  exit 1
fi
grep -Fq "PREPARER_MIN_VERSION='0.0.101'" "$installer"
grep -Fq 'tags/list?n=10000' "$installer"
grep -Fq 'prune_unused_images_preserving_preparers()' "$installer"
grep -Fq 'ensure_preparer_image()' "$root/icarius-host-assistant.sh"
grep -Fq 'preflight_release_images()' "$root/icarius-host-assistant.sh"
grep -Fq 'APTO - Credencial GHCR e imagenes inmutables verificadas antes del backup.' "$root/icarius-host-assistant.sh"
echo 'OK installer: seleccion semantica, bootstrap y preflight GHCR'
