#!/usr/bin/env bash
set -Eeuo pipefail

OPERATOR='icarius'
NODE_ROOT='/opt/icarius/node-v16.14.0-linux-x64'
temporary=''

EDITION=${ICARIUS_BOOTSTRAP_EDITION:-onprem}
case $EDITION in
  onprem)
    PRODUCT='ICARIUS On-Premise'
    INSTALL_ROOT='/srv/icarius/onprem'
    PREPARER_ROOT='/srv/icarius/preparer-onprem'
    SECRETS_ROOT='/srv/icarius/preparer-secrets/onprem'
    REGISTRY_USER='soporteicarius'
    PREPARER_PACKAGE='icarius-preparer-onprem'
    PREPARER_PROJECT='icarius-preparer-onprem'
    PREPARER_PORT_DEFAULT='3500'
    KEYS_NAME='application_keys.json'
    APP_COMMAND='icarius'
    PREPARER_COMMAND='icarius-preparer'
    DOCKER_CONFIG_ROOT='/home/icarius/.docker'
    ;;
  cloud)
    PRODUCT='ICARIUS Central Cloud'
    INSTALL_ROOT='/srv/icarius/cloud'
    PREPARER_ROOT='/srv/icarius/preparer-cloud'
    SECRETS_ROOT='/srv/icarius/preparer-secrets/cloud'
    REGISTRY_USER='adminicarius'
    PREPARER_PACKAGE='icarius-preparer-cloud'
    PREPARER_PROJECT='icarius-preparer-cloud'
    PREPARER_PORT_DEFAULT='3600'
    KEYS_NAME='prod_keys.json'
    APP_COMMAND='icarius-cloud'
    PREPARER_COMMAND='icarius-preparer-cloud'
    DOCKER_CONFIG_ROOT='/home/icarius/.docker-cloud'
    ;;
  *) printf 'ERROR: Edicion de bootstrap invalida.\n' >&2; exit 1 ;;
esac

cleanup() {
  if [[ -n "${temporary:-}" && -d "$temporary" ]]; then
    rm -rf "$temporary"
  fi
  unset registry_token provisioning_code cloud_url_key read_token bearer tags ICARIUS_PROVISIONING_CODE
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
managed_preparer_owns_port() {
  local requested_port="$1" container_id bindings
  command -v docker >/dev/null 2>&1 || return 1
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    bindings="$(docker inspect --format '{{range $bindings := .NetworkSettings.Ports}}{{range $binding := $bindings}}{{$binding.HostIp}} {{$binding.HostPort}}{{println}}{{end}}{{end}}' "$container_id" 2>/dev/null)" || continue
    if printf '%s\n' "$bindings" | awk -v requested_port="$requested_port" '"x" $2 == "x" requested_port { found = 1 } END { exit !found }'; then
      return 0
    fi
  done < <(docker ps -q \
    --filter "label=com.docker.compose.project=$PREPARER_PROJECT" \
    --filter 'label=com.docker.compose.service=preparer' 2>/dev/null)
  return 1
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
  printf 'Uso: curl -fsSL https://raw.githubusercontent.com/AlbanyTechnologies/icarius-installer/main/install-%s.sh | sudo bash\n' "$EDITION"
  exit 0
fi

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fail 'Ejecute el comando con sudo.'
[[ -r /etc/os-release ]] || fail 'No se pudo identificar el sistema operativo.'
. /etc/os-release
[[ "${ID:-}" == ubuntu && ("${VERSION_ID:-}" == '22.04' || "${VERSION_ID:-}" == '24.04') ]] || fail 'Se requiere Ubuntu Server 22.04 o 24.04.'
[[ "$(uname -m)" == x86_64 ]] || fail 'Se requiere arquitectura x86_64.'

say "Asistente de instalacion - $PRODUCT"
if [[ "$EDITION" == cloud ]]; then
  printf '%s\n' 'Responda cinco datos. Los valores confidenciales no se muestran.'
else
  printf '%s\n' 'Responda cuatro datos. Los valores confidenciales no se muestran.'
fi

public_guess="$(hostname -I 2>/dev/null | awk '{print $1}')"
public_host="$(ask 'IP o DNS para abrir el configurador' "${public_guess:-localhost}")"
[[ "$public_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail 'IP o DNS invalido. Use solo letras, numeros, puntos y guiones; no incluya protocolo, puerto ni ruta.'
preparer_host="$public_host"
preparer_port="$(ask 'Puerto temporal del configurador' "$PREPARER_PORT_DEFAULT")"
[[ "$preparer_port" =~ ^[0-9]+$ && "$preparer_port" -ge 1 && "$preparer_port" -le 65535 ]] || fail 'Puerto invalido.'
if ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$preparer_port$"; then
  if managed_preparer_owns_port "$preparer_port"; then
    say 'El Preparador existente se actualizara en el mismo puerto.'
  else
    fail "El puerto $preparer_port ya esta ocupado. Vuelva a ejecutar y elija otro."
  fi
fi

registry_token=''
if [[ ! -s "$SECRETS_ROOT/ghcr_read_token" ]]; then
  registry_token="$(ask_secret 'Token de instalacion')"
  [[ -n "$registry_token" ]] || fail 'El token es obligatorio en la primera instalacion.'
fi
provisioning_code=''
if [[ ! -s "$SECRETS_ROOT/$KEYS_NAME" ]]; then
  provisioning_code="$(ask_secret 'Codigo de aprovisionamiento ICARIUS')"
  [[ -n "$provisioning_code" ]] || fail 'El codigo de aprovisionamiento es obligatorio.'
fi
cloud_url_key=''
if [[ "$EDITION" == cloud && ! -s "$SECRETS_ROOT/cloud_url_key" ]]; then
  cloud_url_key="$(ask_secret 'Clave de URL Cloud')"
  [[ -n "$cloud_url_key" ]] || fail 'La clave de URL Cloud es obligatoria.'
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
install -d -m 0700 -o "$OPERATOR" -g "$OPERATOR" "$DOCKER_CONFIG_ROOT"

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
HOST_ASSISTANT='/opt/icarius/icarius-host-assistant.sh'
curl -fsSL https://raw.githubusercontent.com/AlbanyTechnologies/icarius-installer/main/icarius-host-assistant.sh -o "$HOST_ASSISTANT"
chmod 0755 "$HOST_ASSISTANT"
cat > "/usr/local/bin/$APP_COMMAND" <<EOF
#!/usr/bin/env bash
set -e
export DOCKER_CONFIG="$DOCKER_CONFIG_ROOT"
if [[ "\${1:-}" == setup-web || "\${1:-}" == ssh-host ]]; then
  exec "$HOST_ASSISTANT" "\${1:-}" "$INSTALL_ROOT"
fi
test -x "$INSTALL_ROOT/bin/icarius" || { echo 'Primero complete el configurador ICARIUS.' >&2; exit 1; }
export PATH="$NODE_ROOT/bin:\$PATH"
exec "$INSTALL_ROOT/bin/icarius" "\$@"
EOF
chmod 0755 "/usr/local/bin/$APP_COMMAND"

say '3/5 - Guardando credenciales protegidas'
if [[ -n "$registry_token" ]]; then
  printf '%s' "$registry_token" > "$SECRETS_ROOT/ghcr_read_token"
fi
if [[ -n "$provisioning_code" ]]; then
  decode_provisioning_code "$provisioning_code" "$SECRETS_ROOT/$KEYS_NAME"
fi
if [[ -n "$cloud_url_key" ]]; then
  printf '%s' "$cloud_url_key" > "$SECRETS_ROOT/cloud_url_key"
fi
chown "$OPERATOR:$OPERATOR" "$SECRETS_ROOT"/*
chmod 0600 "$SECRETS_ROOT"/*
unset provisioning_code cloud_url_key

if [[ -z "$temporary" || ! -d "$temporary" ]]; then
  temporary="$(mktemp -d)"
fi
if [[ -n "$registry_token" ]]; then
  printf '%s' "$registry_token" | runuser -u "$OPERATOR" -- env HOME="/home/$OPERATOR" DOCKER_CONFIG="$DOCKER_CONFIG_ROOT" docker login ghcr.io -u "$REGISTRY_USER" --password-stdin >/dev/null
fi
unset registry_token

say '4/5 - Buscando la version autorizada'
read_token="$(cat "$SECRETS_ROOT/ghcr_read_token")"
netrc_file="$temporary/ghcr.netrc"
printf 'machine ghcr.io\nlogin %s\npassword %s\n' "$REGISTRY_USER" "$read_token" > "$netrc_file"
chmod 0600 "$netrc_file"
bearer="$(curl -fsSL --netrc-file "$netrc_file" "https://ghcr.io/token?service=ghcr.io&scope=repository:maxglomba/$PREPARER_PACKAGE:pull" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
authorization_header_file="$temporary/ghcr-authorization.header"
printf 'Authorization: Bearer %s\n' "$bearer" > "$authorization_header_file"
chmod 0600 "$authorization_header_file"
tags="$(curl -fsSL -H @"$authorization_header_file" "https://ghcr.io/v2/maxglomba/$PREPARER_PACKAGE/tags/list")"
version="$(TAGS_JSON="$tags" python3 - <<'PY'
import json, os, re
tags = json.loads(os.environ["TAGS_JSON"]).get("tags") or []
versions = [tag for tag in tags if re.fullmatch(r"\d+(?:\.\d+)+", tag)]
if not versions: raise SystemExit("No hay versiones autorizadas.")
print(max(versions, key=lambda value: tuple(int(part) for part in value.split("."))))
PY
)"
unset read_token bearer tags
image="ghcr.io/maxglomba/$PREPARER_PACKAGE:$version"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail 'Version autorizada invalida.'
[[ "$image" == "ghcr.io/maxglomba/$PREPARER_PACKAGE:"* ]] || fail 'Imagen autorizada invalida.'

cat > "$PREPARER_ROOT/preparer.env" <<EOF
ICARIUS_PREPARER_IMAGE=$image
ICARIUS_PREPARER_PROJECT=$PREPARER_PROJECT
ICARIUS_PREPARER_BIND_ADDRESS=0.0.0.0
ICARIUS_PREPARER_HOST_PORT=$preparer_port
ICARIUS_PREPARER_PUBLIC_HOST=$public_host
ICARIUS_INSTALLATION_ROOT=$INSTALL_ROOT
ICARIUS_PREPARER_SECRETS_ROOT=$SECRETS_ROOT
ICARIUS_HOST_UID=$(id -u "$OPERATOR")
ICARIUS_HOST_GID=$(id -g "$OPERATOR")
EOF
cat > "$PREPARER_ROOT/compose.yaml" <<'YAML'
name: ${ICARIUS_PREPARER_PROJECT}
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
      ICARIUS_PREPARER_HOST_MODE: vps
      ICARIUS_PREPARER_HOST_ROOT: ${ICARIUS_INSTALLATION_ROOT}
    volumes:
      - "${ICARIUS_INSTALLATION_ROOT}:/workspace"
      - "${ICARIUS_PREPARER_SECRETS_ROOT}:/run/secrets:ro"
    read_only: true
    tmpfs: ["/tmp:mode=1777"]
    security_opt: ["no-new-privileges:true"]
    cap_drop: [ALL]
    restart: unless-stopped
YAML
printf '\nICARIUS_HOST_UID=1000\nICARIUS_HOST_GID=1000\n' >> $PREPARER_ROOT/preparer.env
chown -R 1000:1000 $INSTALL_ROOT $SECRETS_ROOT
chown -R "$OPERATOR:$OPERATOR" "$PREPARER_ROOT"
chmod 0600 "$PREPARER_ROOT/preparer.env"

cat > "/usr/local/bin/$PREPARER_COMMAND" <<EOF
#!/usr/bin/env bash
set -e
export DOCKER_CONFIG="$DOCKER_CONFIG_ROOT"
cd "$PREPARER_ROOT"
case "\${1:-status}" in
  start) exec runuser -u "$OPERATOR" -- docker compose --env-file preparer.env up -d ;;
  stop) exec runuser -u "$OPERATOR" -- docker compose --env-file preparer.env down ;;
  status) exec runuser -u "$OPERATOR" -- docker compose --env-file preparer.env ps ;;
  logs) exec runuser -u "$OPERATOR" -- docker compose --env-file preparer.env logs --tail 100 ;;
  reset-auth)
    runuser -u "$OPERATOR" -- docker compose --env-file preparer.env stop preparer
    if ! runuser -u "$OPERATOR" -- docker compose --env-file preparer.env run --rm --no-deps preparer node docker/preparer/app/reset-auth.js --root /workspace; then
      runuser -u "$OPERATOR" -- docker compose --env-file preparer.env up -d preparer || true
      echo 'No se pudo reiniciar el acceso. El configurador anterior volvio a iniciarse.' >&2
      exit 1
    fi
    runuser -u "$OPERATOR" -- docker compose --env-file preparer.env up -d preparer
    echo 'Acceso reiniciado. Abra este enlace privado antes de 30 minutos:'
    exec "\$0" activation
    ;;
  activation)
    public_host=\$(sed -n 's/^ICARIUS_PREPARER_PUBLIC_HOST=//p' preparer.env)
    public_port=\$(sed -n 's/^ICARIUS_PREPARER_HOST_PORT=//p' preparer.env)
    [[ "\$public_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\$ ]] || { echo 'Host publico invalido en preparer.env.' >&2; exit 1; }
    [[ "\$public_port" =~ ^[0-9]+\$ && "\$public_port" -ge 1 && "\$public_port" -le 65535 ]] || { echo 'Puerto publico invalido en preparer.env.' >&2; exit 1; }
    token_file="$INSTALL_ROOT/config/preparer-bootstrap-token.txt"
    [[ -s "\$token_file" ]] || { echo 'El enlace de activacion ya no esta disponible porque el administrador inicial ya fue creado.' >&2; exit 1; }
    activation=\$(cat "\$token_file")
    [[ "\$activation" =~ ^[A-Za-z0-9_-]+\$ ]] || { echo 'El token de activacion almacenado no es valido.' >&2; exit 1; }
    printf 'https://%s:%s/#activation=%s\n' "\$public_host" "\$public_port" "\$activation"
    ;;
  *) echo 'Uso: $PREPARER_COMMAND start|stop|status|logs|activation|reset-auth' >&2; exit 1 ;;
esac
EOF
chmod 0755 "/usr/local/bin/$PREPARER_COMMAND"

say '5/5 - Iniciando el configurador'
(
  cd "$PREPARER_ROOT"
  runuser -u "$OPERATOR" -- env DOCKER_CONFIG="$DOCKER_CONFIG_ROOT" docker compose --env-file preparer.env -f compose.yaml pull
  runuser -u "$OPERATOR" -- env DOCKER_CONFIG="$DOCKER_CONFIG_ROOT" docker compose --env-file preparer.env -f compose.yaml up -d
)
bootstrap_token_file="$INSTALL_ROOT/config/preparer-bootstrap-token.txt"
preparer_auth_file="$INSTALL_ROOT/config/preparer-auth.json"
bootstrap_state=''
preparer_is_enrolled() {
  python3 - "$preparer_auth_file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as source:
        state = json.load(source)
except (OSError, ValueError):
    raise SystemExit(1)
# Accept only the exact JSON state bootstrap.used === true.
bootstrap = state.get("bootstrap") if isinstance(state, dict) else None
raise SystemExit(0 if isinstance(bootstrap, dict) and bootstrap.get("used") is True else 1)
PY
}
for _ in $(seq 1 30); do
  if [[ -s "$bootstrap_token_file" ]]; then
    bootstrap_state='token'
    break
  fi
  if preparer_is_enrolled; then
    bootstrap_state='enrolled'
    break
  fi
  sleep 1
done
if [[ -s "$bootstrap_token_file" ]]; then
  bootstrap_state='token'
elif preparer_is_enrolled; then
  bootstrap_state='enrolled'
else
  fail "El configurador no inicio. Ejecute: $PREPARER_COMMAND logs"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "$preparer_port/tcp" comment 'ICARIUS Preparer temporal' >/dev/null
fi

say 'INSTALACION GUIADA LISTA'
if [[ "$bootstrap_state" == 'token' ]]; then
  printf '%s\n' 'Abra este enlace privado para crear el administrador:'
  "/usr/local/bin/$PREPARER_COMMAND" activation
  printf '%s\n' 'No comparta este enlace: permite crear el administrador inicial.'
else
  printf '%s\n' 'Configurador actualizado. El administrador existente fue conservado.'
  printf 'Abra el configurador: https://%s:%s/\n' "$preparer_host" "$preparer_port"
fi
printf '%s\n' 'Despues de preparar visualmente ejecute:'
printf '  sudo %s start\n' "$APP_COMMAND"
printf '%s\n' 'Cuando ICARIUS funcione cierre el configurador:'
printf '  sudo %s stop\n' "$PREPARER_COMMAND"
printf '%s\n' "TI debe habilitar temporalmente TCP $preparer_port en el firewall del proveedor."
