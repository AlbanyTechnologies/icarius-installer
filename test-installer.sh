#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="$root/install-onprem.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
bash -n "$installer"
bash -n "$root/install-cloud.sh"
python3 - "$temporary/tags.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as target:
    tags = [f"0.0.{number}" for number in range(1, 251)] + ["latest", "sha-deadbeef", "sha256-signature"]
    for start in range(0, len(tags), 37):
        target.write(json.dumps({"tags": tags[start:start + 37]}) + "\n")
PY
selected="$(bash "$installer" --select-latest-tags "$temporary/tags.jsonl")"
[[ "$selected" == 0.0.250 ]] || { echo "Version incorrecta: $selected" >&2; exit 1; }
printf '{"tags":["latest","sha-deadbeef"]}\n' > "$temporary/no-versions.jsonl"
if bash "$installer" --select-latest-tags "$temporary/no-versions.jsonl" >/dev/null 2>&1; then
  echo 'Se acepto una lista sin versiones numericas.' >&2
  exit 1
fi
grep -Fq "PREPARER_MIN_VERSION='0.0.102'" "$installer"
grep -Fq 'tags/list?n=1000' "$installer"
grep -Fq 'pagina completa sin indicar la siguiente' "$installer"
echo 'OK installer: seleccion paginada, minimo seguro y fallo cerrado'
