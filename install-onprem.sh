#!/usr/bin/env bash
set -Eeuo pipefail

PRODUCT='ICARIUS On-Premise'
INSTALL_ROOT='/srv/icarius/onprem'
PREPARER_ROOT='/srv/icarius/preparer-onprem'
SECRETS_ROOT='/srv/icarius/preparer-secrets/onprem'
OPERATOR='icarius'
NODE_ROOT='/opt/icarius/node-v16.14.0-linux-x64'
REGISTRY_USER='soporteicarius'
temporary=''

cleanup() {
  if [[ -n "${temporary:-}" && -d "$temporary" ]]; then
    rm -rf "$temporary"
  fi
  unset registry_token provisioning_code read_token bearer tags ICARIUS_PROVISIONING_CODE
}
trap cleanup EXIT

say() { printf '\n%s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
[[ "$REGISTRY_USER" =~ ^[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?$ && "$REGISTRY_USER" != *--* ]] || fail 'Usuario de registro invalido.'
ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then prompt="$prompt [$default]"; fi
  read -r -p "$prompt: " answer </dev/tty
  printf '%s' "${answer:-$default}"
}
ask_secret() {
  local prompt="$1" answer
  read -r -s -p "$prompt: " answer </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "$answer"
}
decode_provisioning_code() {
  local code="$1" destination="$2"
  ICARIUS_PROVISIONING_CODE="$code" python3 - "$destination" <<'PY'
import base64, hashlib, json, os, pathlib, re, sys
parts = os.environ.pop("ICARIUS_PROVISIONING_CODE", "").strip().split(".")
if len(parts) != 3 or parts[0] != "ICARIUS1" or not re.fullmatch(r"[a-f0-9]{64}", parts[2]):
    raise SystemExit("Codigo de aprovisionamiento invalido.")
payload = base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4))
if hashlib.sha256(payload).hexdigest() != parts[2]:
    raise SystemExit("El codigo esta incompleto o fue alterado.")
keys = json.loads(payload)
required = {
  "master": ["jwt_encryption_key", "jwt_encryption_salt", "jwt_sign_key"],
  "application": ["encryption_key", "encryption_salt", "hash_salt", "jwt_sign_key",
    "jwt_encryption_key", "jwt_encryption_salt", "visitor_signer_key",
    "fiscalization_key", "geocoding_key"]
}
for section, names in required.items():
    if not isinstance(keys.get(section), dict):
        raise SystemExit("El codigo no corresponde a claves ICARIUS.")
    for name in names:
        if not isinstance(keys[section].get(name), str) or not keys[section][name].strip():
            raise SystemExit("El codigo no corresponde a claves ICARIUS.")
target = pathlib.Path(sys.argv[1])
target.write_text(json.dumps(keys, separators=(",", ":")) + "\n", encoding="utf-8")
target.chmod(0o600)
PY
}
if [[ "${1:-}" == '--decode-provisioning-code' ]]; then
  [[ $# -eq 3 ]] || fail 'Uso: --decode-provisioning-code CODIGO DESTINO'
  decode_provisioning_code "$2" "$3"
  exit 0
fi
if [[ "${1:-}" == '--help' ]]; then
  printf '%s\n' 'Uso: curl -fsSL URL_OFICIAL | sudo bash'
  exit 0
fi

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fail 'Ejecute el comando con sudo.'
[[ -r /etc/os-release ]] || fail 'No se pudo identificar el sistema operativo.'
. /etc/os-release
[[ "${ID:-}" == ubuntu && ("${VERSION_ID:-}" == '22.04' || "${VERSION_ID:-}" == '24.04') ]] || fail 'Se requiere Ubuntu Server 22.04 o 24.04.'
[[ "$(uname -m)" == x86_64 ]] || fail 'Se requiere arquitectura x86_64.'

say "Asistente de instalacion - $PRODUCT"
printf '%s\n' 'Responda cuatro datos. Los valores confidenciales no se muestran.'

public_guess="$(hostname -I 2>/dev/null | awk '{print $1}')"
public_host="$(ask 'IP o DNS para abrir el configurador' "${public_guess:-localhost}")"
[[ "$public_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail 'IP o DNS invalido. Use solo letras, numeros, puntos y guiones; no incluya protocolo, puerto ni ruta.'
preparer_port="$(ask 'Puerto temporal del configurador' '3500')"
[[ "$preparer_port" =~ ^[0-9]+$ && "$preparer_port" -ge 1 && "$preparer_port" -le 65535 ]] || fail 'Puerto invalido.'
if ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$preparer_port$"; then
  fail "El puerto $preparer_port ya esta ocupado. Vuelva a ejecutar y elija otro."
fi

registry_token=''
if [[ ! -s "$SECRETS_ROOT/ghcr_read_token" ]]; then
  registry_token="$(ask_secret 'Token de instalacion')"
  [[ -n "$registry_token" ]] || fail 'El token es obligatorio en la primera instalacion.'
fi
provisioning_code=''
if [[ ! -s "$SECRETS_ROOT/application_keys.json" ]]; then
  provisioning_code="$(ask_secret 'Codigo de aprovisionamiento ICARIUS')"
  [[ -n "$provisioning_code" ]] || fail 'El codigo de aprovisionamiento es obligatorio.'
fi

say '1/5 - Preparando el servidor'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg iproute2 python3 xz-utils >/dev/null
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
systemctl enable --now docker.service containerd.service >/dev/null
id "$OPERATOR" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$OPERATOR"
usermod -aG docker "$OPERATOR"
install -d -m 0750 -o "$OPERATOR" -g "$OPERATOR" "$INSTALL_ROOT" "$PREPARER_ROOT"
install -d -m 0700 -o "$OPERATOR" -g "$OPERATOR" "$SECRETS_ROOT"

say '2/5 - Instalando el comando ICARIUS'
if [[ ! -x "$NODE_ROOT/bin/node" ]]; then
  temporary="$(mktemp -d)"
  curl -fsSL https://nodejs.org/dist/v16.14.0/SHASUMS256.txt -o "$temporary/SHASUMS256.txt"
  curl -fsSL https://nodejs.org/dist/v16.14.0/node-v16.14.0-linux-x64.tar.xz -o "$temporary/node.tar.xz"
  expected_sha256="$(awk '$2 == "node-v16.14.0-linux-x64.tar.xz" {print $1}' "$temporary/SHASUMS256.txt")"
  [[ -n "$expected_sha256" ]] || fail 'No se encontro la suma SHA-256 oficial de Node.js.'
  actual_sha256="$(sha256sum "$temporary/node.tar.xz" | awk '{print $1}')"
  [[ "$actual_sha256" == "$expected_sha256" ]] || fail 'La suma SHA-256 del archivo de Node.js no coincide.'
  install -d -m 0755 /opt/icarius
  tar -xJf "$temporary/node.tar.xz" -C /opt/icarius
fi
cat > /usr/local/bin/icarius <<EOF
#!/usr/bin/env bash
set -e
test -x "$INSTALL_ROOT/bin/icarius" || { echo 'Primero complete el configurador ICARIUS.' >&2; exit 1; }
export PATH="$NODE_ROOT/bin:\$PATH"
exec runuser -u "$OPERATOR" -- "$INSTALL_ROOT/bin/icarius" "\$@"
EOF
chmod 0755 /usr/local/bin/icarius

say '3/5 - Guardando credenciales protegidas'
if [[ -n "$registry_token" ]]; then
  printf '%s' "$registry_token" > "$SECRETS_ROOT/ghcr_read_token"
fi
if [[ -n "$provisioning_code" ]]; then
  decode_provisioning_code "$provisioning_code" "$SECRETS_ROOT/application_keys.json"
fi
chown "$OPERATOR:$OPERATOR" "$SECRETS_ROOT"/*
chmod 0600 "$SECRETS_ROOT"/*
unset provisioning_code

if [[ -z "$temporary" || ! -d "$temporary" ]]; then
  temporary="$(mktemp -d)"
fi
if [[ -n "$registry_token" ]]; then
  printf '%s' "$registry_token" | runuser -u "$OPERATOR" -- env HOME="/home/$OPERATOR" docker login ghcr.io -u "$REGISTRY_USER" --password-stdin >/dev/null
fi
unset registry_token

say '4/5 - Buscando la version autorizada'
read_token="$(cat "$SECRETS_ROOT/ghcr_read_token")"
netrc_file="$temporary/ghcr.netrc"
printf 'machine ghcr.io\nlogin %s\npassword %s\n' "$REGISTRY_USER" "$read_token" > "$netrc_file"
chmod 0600 "$netrc_file"
bearer="$(curl -fsSL --netrc-file "$netrc_file" 'https://ghcr.io/token?service=ghcr.io&scope=repository:maxglomba/icarius-preparer-onprem:pull' | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
authorization_header_file="$temporary/ghcr-authorization.header"
printf 'Authorization: Bearer %s\n' "$bearer" > "$authorization_header_file"
chmod 0600 "$authorization_header_file"
tags="$(curl -fsSL -H @"$authorization_header_file" 'https://ghcr.io/v2/maxglomba/icarius-preparer-onprem/tags/list')"
version="$(TAGS_JSON="$tags" python3 - <<'PY'
import json, os, re
tags = json.loads(os.environ["TAGS_JSON"]).get("tags") or []
versions = [tag for tag in tags if re.fullmatch(r"\d+(?:\.\d+)+", tag)]
if not versions: raise SystemExit("No hay versiones autorizadas.")
print(max(versions, key=lambda value: tuple(int(part) for part in value.split("."))))
PY
)"
unset read_token bearer tags
image="ghcr.io/maxglomba/icarius-preparer-onprem:$version"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail 'Version autorizada invalida.'
[[ "$image" =~ ^ghcr\.io/maxglomba/icarius-preparer-onprem:[0-9]+(\.[0-9]+)+$ ]] || fail 'Imagen autorizada invalida.'

cat > "$PREPARER_ROOT/preparer.env" <<EOF
ICARIUS_PREPARER_IMAGE=$image
ICARIUS_PREPARER_BIND_ADDRESS=0.0.0.0
ICARIUS_PREPARER_HOST_PORT=$preparer_port
ICARIUS_PREPARER_PUBLIC_HOST=$public_host
ICARIUS_INSTALLATION_ROOT=$INSTALL_ROOT
ICARIUS_PREPARER_SECRETS_ROOT=$SECRETS_ROOT
ICARIUS_HOST_UID=$(id -u "$OPERATOR")
ICARIUS_HOST_GID=$(id -g "$OPERATOR")
EOF
cat > "$PREPARER_ROOT/compose.yaml" <<'YAML'
name: icarius-preparer-onprem
services:
  preparer:
    image: ${ICARIUS_PREPARER_IMAGE}
    user: "${ICARIUS_HOST_UID}:${ICARIUS_HOST_GID}"
    ports:
      - "${ICARIUS_PREPARER_BIND_ADDRESS}:${ICARIUS_PREPARER_HOST_PORT}:3210"
    environment:
      ICARIUS_PREPARER_BIND: 0.0.0.0
      ICARIUS_PREPARER_PORT: 3210
      ICARIUS_PREPARER_WORKSPACE: /workspace
      ICARIUS_PREPARER_TLS: "true"
      ICARIUS_PREPARER_PUBLIC_HOST: ${ICARIUS_PREPARER_PUBLIC_HOST}
    volumes:
      - "${ICARIUS_INSTALLATION_ROOT}:/workspace"
      - "${ICARIUS_PREPARER_SECRETS_ROOT}:/run/secrets:ro"
    read_only: true
    tmpfs: ["/tmp:mode=1777"]
    security_opt: ["no-new-privileges:true"]
    cap_drop: [ALL]
    restart: unless-stopped
YAML
chown -R "$OPERATOR:$OPERATOR" "$PREPARER_ROOT"
chmod 0600 "$PREPARER_ROOT/preparer.env"

cat > /usr/local/bin/icarius-preparer <<EOF
#!/usr/bin/env bash
set -e
cd "$PREPARER_ROOT"
case "\${1:-status}" in
  start) exec runuser -u "$OPERATOR" -- docker compose --env-file preparer.env up -d ;;
  stop) exec runuser -u "$OPERATOR" -- docker compose --env-file preparer.env down ;;
  status) exec runuser -u "$OPERATOR" -- docker compose --env-file preparer.env ps ;;
  logs) exec runuser -u "$OPERATOR" -- docker compose --env-file preparer.env logs --tail 100 ;;
  *) echo 'Uso: icarius-preparer start|stop|status|logs' >&2; exit 1 ;;
esac
EOF
chmod 0755 /usr/local/bin/icarius-preparer

say '5/5 - Iniciando el configurador'
runuser -u "$OPERATOR" -- docker compose --env-file "$PREPARER_ROOT/preparer.env" -f "$PREPARER_ROOT/compose.yaml" pull
runuser -u "$OPERATOR" -- docker compose --env-file "$PREPARER_ROOT/preparer.env" -f "$PREPARER_ROOT/compose.yaml" up -d
for _ in $(seq 1 30); do
  [[ -s "$INSTALL_ROOT/config/preparer-bootstrap-token.txt" ]] && break
  sleep 1
done
[[ -s "$INSTALL_ROOT/config/preparer-bootstrap-token.txt" ]] || fail 'El configurador no inicio. Ejecute: icarius-preparer logs'

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "$preparer_port/tcp" comment 'ICARIUS Preparer temporal' >/dev/null
fi

say 'INSTALACION GUIADA LISTA'
printf 'Abra: https://%s:%s\n' "$public_host" "$preparer_port"
printf 'Token inicial: %s\n' "$(cat "$INSTALL_ROOT/config/preparer-bootstrap-token.txt")"
printf '%s\n' 'Despues de preparar visualmente ejecute:'
printf '%s\n' '  sudo icarius start'
printf '%s\n' 'Cuando ICARIUS funcione cierre el configurador:'
printf '%s\n' '  sudo icarius-preparer stop'
printf '%s\n' "TI debe habilitar temporalmente TCP $preparer_port en el firewall del proveedor."
