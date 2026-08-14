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
confirm() {
  local prompt="$1" answer
  read -r -p "$prompt [s/N]: " answer </dev/tty
  [[ "$answer" == s || "$answer" == S || "$answer" == si || "$answer" == SI ]]
}
confirm_recommended() {
  local prompt="$1" answer
  read -r -p "$prompt [S/n]: " answer </dev/tty
  [[ -z "$answer" || "$answer" == s || "$answer" == S || "$answer" == si || "$answer" == SI ]]
}
version_at_least() {
  local current="${1#v}" minimum="${2#v}"
  [[ "$(printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n 1)" == "$minimum" ]]
}
capacity_report() {
  local cpu="$1" memory_kib="$2" disk_kib="$3" inodes="$4" systemd="$5" cgroups="$6" virtualization="$7"
  local blocked=0
  if (( cpu < 2 )); then
    printf 'BLOQUEADO - CPU: %s vCPU; se requieren al menos 2.\n' "$cpu"
    blocked=1
  elif (( cpu < 4 )); then
    printf 'ADVERTENCIA - CPU: %s vCPU; compatible para instalaciones pequenas o validacion. Se recomiendan 4 o mas para produccion.\n' "$cpu"
  fi
  if (( memory_kib < 7864320 )); then printf 'BLOQUEADO - Memoria: se requieren 8 GiB nominales.\n'; blocked=1; fi
  if (( disk_kib < 20971520 )); then printf 'BLOQUEADO - Disco: se requieren 20 GiB libres.\n'; blocked=1; fi
  if (( inodes < 100000 )); then printf 'BLOQUEADO - Disco: no hay inodos suficientes.\n'; blocked=1; fi
  if [[ "$systemd" != yes ]]; then printf 'BLOQUEADO - El host debe usar systemd.\n'; blocked=1; fi
  if [[ "$cgroups" != yes ]]; then printf 'BLOQUEADO - El host no expone cgroups compatibles.\n'; blocked=1; fi
  case "$virtualization" in
    none|kvm|vmware|microsoft|xen|qemu|oracle|amazon) ;;
    *) printf 'BLOQUEADO - Virtualizacion no validada para Docker: %s.\n' "$virtualization"; blocked=1 ;;
  esac
  (( blocked == 0 )) || return 1
  printf 'APTO - Capacidad base compatible con ICARIUS.\n'
}
host_capacity_preflight() {
  local cpu memory_kib memory_available_kib swap_kib disk_kib disk_total_kib inodes systemd cgroups virtualization ntp
  cpu="$(nproc)"
  memory_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  memory_available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  swap_kib="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
  disk_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
  disk_total_kib="$(df -Pk / | awk 'NR == 2 {print $2}')"
  inodes="$(df -Pi / | awk 'NR == 2 {print $4}')"
  [[ "$(cat /proc/1/comm 2>/dev/null)" == systemd ]] && systemd=yes || systemd=no
  [[ -r /proc/self/cgroup && -d /sys/fs/cgroup ]] && cgroups=yes || cgroups=no
  virtualization="$(systemd-detect-virt 2>/dev/null || true)"
  virtualization="${virtualization:-none}"
  capacity_report "$cpu" "$memory_kib" "$disk_kib" "$inodes" "$systemd" "$cgroups" "$virtualization" || fail 'El servidor no cumple los requisitos minimos. Corrija los puntos BLOQUEADO y vuelva a ejecutar.'
  (( disk_total_kib >= 83886080 )) || printf 'ADVERTENCIA - Se recomiendan 80 GiB de disco total para imagenes, backups y actualizaciones.\n'
  (( memory_available_kib >= 4194304 )) || printf 'ADVERTENCIA - Hay menos de 4 GiB de memoria disponible; revise otros servicios del VPS.\n'
  (( swap_kib > 0 )) || printf 'ADVERTENCIA - El VPS no tiene swap configurada; el asistente puede crear una reserva segura.\n'
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  [[ "$ntp" == yes ]] || printf 'ADVERTENCIA - El reloj no informa sincronizacion NTP.\n'
}
offer_swap_reserve() {
  local swap_kib disk_kib swapfile='/swapfile' created=false activated=false
  swap_kib="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
  (( swap_kib == 0 )) || return 0
  printf 'La swap ayuda a evitar que Linux detenga contenedores ante un pico de memoria; no reemplaza la RAM.\n'
  if ! confirm_recommended 'Crear ahora una reserva persistente de 2 GiB'; then
    printf 'ADVERTENCIA - Swap omitida por decision del instalador. Puede configurarse mas adelante.\n'
    return 0
  fi
  disk_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
  (( disk_kib >= 23068672 )) || fail 'Se necesitan al menos 22 GiB libres para crear 2 GiB de swap y conservar el minimo operativo.'
  if [[ -e "$swapfile" ]]; then
    [[ -f "$swapfile" ]] || fail "$swapfile existe pero no es un archivo regular. TI debe revisarlo."
    chmod 0600 "$swapfile"
    swapon "$swapfile" || fail "$swapfile existe pero no pudo activarse. TI debe revisar su formato."
    activated=true
  else
    if ! fallocate -l 2G "$swapfile"; then
      dd if=/dev/zero of="$swapfile" bs=1M count=2048 status=none
    fi
    chmod 0600 "$swapfile"
    mkswap "$swapfile" >/dev/null
    if ! swapon "$swapfile"; then
      rm -f "$swapfile"
      fail 'No se pudo activar la reserva swap; el archivo incompleto fue retirado.'
    fi
    created=true
    activated=true
  fi
  if ! awk '$1 == "/swapfile" && $3 == "swap" { found = 1 } END { exit !found }' /etc/fstab; then
    temporary="${temporary:-$(mktemp -d)}"
    cp /etc/fstab "$temporary/fstab.before-swap"
    if ! printf '/swapfile none swap sw 0 0\n' >> /etc/fstab; then
      cp "$temporary/fstab.before-swap" /etc/fstab
      [[ "$activated" == true ]] && swapoff "$swapfile" || true
      [[ "$created" == true ]] && rm -f "$swapfile"
      fail 'No se pudo registrar la swap para el proximo reinicio; el cambio fue revertido.'
    fi
  fi
  printf 'APTO - Reserva swap de 2 GiB activa y persistente.\n'
}
check_outbound() {
  local label="$1" url="$2"
  curl -sSIL --connect-timeout 10 --max-time 20 "$url" >/dev/null || fail "Sin conectividad saliente hacia $label ($url). Revise DNS, firewall o proxy."
  printf 'APTO - Salida a %s.\n' "$label"
}
configure_docker_repository() {
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq || fail 'No se pudo actualizar el indice del repositorio oficial de Docker.'
}
install_official_docker() {
  configure_docker_repository
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
}
ensure_docker_runtime() {
  local docker_version compose_version existing_containers official_install=false
  if ! command -v docker >/dev/null 2>&1; then
    say 'Docker no esta instalado; se instalara Docker Engine oficial y Compose v2.'
    install_official_docker
  fi
  systemctl enable --now docker.service containerd.service >/dev/null || fail 'Docker no pudo iniciarse con systemd.'
  docker info >/dev/null 2>&1 || fail 'Docker esta instalado pero el daemon no responde. Corrija Docker antes de continuar.'
  docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  [[ -n "$docker_version" ]] || fail 'No se pudo determinar la version del servidor Docker.'
  dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'ok installed' && official_install=true
  existing_containers="$(docker ps -aq | wc -l | tr -d ' ')"
  if ! version_at_least "$docker_version" '24.0.0'; then
    (( existing_containers == 0 )) || fail "Docker $docker_version es antiguo y existen $existing_containers contenedores. Programe una ventana de mantenimiento; el instalador no reiniciara servicios ajenos."
    [[ "$official_install" == true ]] || fail "Docker $docker_version no proviene del repositorio oficial. Actualicelo manualmente a 24.0.0 o superior."
    confirm "Docker $docker_version debe actualizarse. Continuar ahora" || fail 'Actualizacion de Docker cancelada.'
    configure_docker_repository
    apt-get install -y -qq --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    systemctl restart docker.service containerd.service >/dev/null
  fi
  compose_version="$(docker compose version --short 2>/dev/null || true)"
  if [[ -z "$compose_version" ]] || ! version_at_least "$compose_version" '2.20.0'; then
    (( existing_containers == 0 )) || fail "Docker Compose ${compose_version:-ausente} no es compatible y existen servicios activos. Actualice el plugin en una ventana de mantenimiento."
    [[ "$official_install" == true ]] || fail 'Docker Compose v2.20.0 o superior es obligatorio.'
    configure_docker_repository
    apt-get install -y -qq --only-upgrade docker-compose-plugin >/dev/null
  fi
  temporary="${temporary:-$(mktemp -d)}"
  printf 'services:\n  smoke:\n    image: hello-world:latest\n' > "$temporary/compose-smoke.yaml"
  docker compose -f "$temporary/compose-smoke.yaml" config -q || fail 'Docker Compose no pudo validar una configuracion minima.'
  printf 'APTO - Docker %s y Compose %s; %s contenedor(es) existentes preservados.\n' "$docker_version" "$(docker compose version --short)" "$existing_containers"
}
if [[ "${1:-}" == '--evaluate-capacity' ]]; then
  [[ $# -eq 8 ]] || fail 'Uso: --evaluate-capacity CPU MEM_KIB DISK_KIB INODOS SYSTEMD CGROUPS VIRTUALIZACION'
  capacity_report "$2" "$3" "$4" "$5" "$6" "$7" "$8"
  exit $?
fi
if [[ "${1:-}" == '--version-at-least' ]]; then
  [[ $# -eq 3 ]] || fail 'Uso: --version-at-least VERSION MINIMA'
  version_at_least "$2" "$3"
  exit $?
fi
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
  local code="$1" destination="$2" sendgrid_destination="${3:-}" registry_destination="${4:-}" cloud_destination="${5:-}" expected_edition="${6:-}"
  ICARIUS_PROVISIONING_CODE="$code" python3 - "$destination" "$sendgrid_destination" "$registry_destination" "$cloud_destination" "$expected_edition" <<'PY'
import base64, hashlib, json, os, pathlib, re, sys
parts = os.environ.pop("ICARIUS_PROVISIONING_CODE", "").strip().split(".")
if len(parts) != 3 or parts[0] not in ("ICARIUS1", "ICARIUS2", "ICARIUS3") or not re.fullmatch(r"[a-f0-9]{64}", parts[2]):
    raise SystemExit("Codigo de aprovisionamiento invalido.")
payload = base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4))
if hashlib.sha256(payload).hexdigest() != parts[2]:
    raise SystemExit("El codigo esta incompleto o fue alterado.")
decoded = json.loads(payload)
registry_token = ""
cloud_url_key = ""
if parts[0] == "ICARIUS3":
    profiles = {
      "on-premise": {"registryUser": "soporteicarius", "packages": ["icarius-onprem-api", "icarius-onprem-release-catalog", "icarius-onprem-scheduler", "icarius-preparer-onprem", "icarius-ssh-tunnel"]},
      "central-cloud": {"registryUser": "adminicarius", "packages": ["icarius-cloud-api", "icarius-cloud-release-catalog", "icarius-cloud-scheduler", "icarius-preparer-cloud", "icarius-ssh-tunnel"]}
    }
    expected = {"onprem": "on-premise", "cloud": "central-cloud"}.get(sys.argv[5], sys.argv[5])
    profile = profiles.get(decoded.get("edition"))
    if decoded.get("schema") != 3 or not profile or decoded.get("edition") != expected:
        raise SystemExit("El codigo ICARIUS no corresponde a esta edicion.")
    if decoded.get("registry") != "ghcr.io" or decoded.get("registryUser") != profile["registryUser"] or decoded.get("packages") != profile["packages"]:
        raise SystemExit("El codigo ICARIUS no corresponde a un perfil autorizado.")
    keys = decoded.get("keys")
    sendgrid_key = str(decoded.get("sendgridKey", "")).strip()
    registry_token = str(decoded.get("registryToken", "")).strip()
    cloud_url_key = str(decoded.get("cloudUrlKey", "")).strip()
    if not registry_token or len(registry_token) > 4096 or any(character in registry_token for character in "\r\n\0"):
        raise SystemExit("El codigo ICARIUS no contiene una credencial de descarga valida.")
    if expected == "central-cloud" and (not cloud_url_key or len(cloud_url_key) > 4096 or any(character in cloud_url_key for character in "\r\n\0")):
        raise SystemExit("El codigo ICARIUS no contiene la clave privada de URL Cloud.")
    if expected == "on-premise" and cloud_url_key:
        raise SystemExit("El codigo ICARIUS On-Premise contiene material Cloud no autorizado.")
elif parts[0] == "ICARIUS2":
    if decoded.get("schema") != 2 or not isinstance(decoded.get("keys"), dict):
        raise SystemExit("El codigo de aprovisionamiento no corresponde a ICARIUS.")
    keys = decoded["keys"]
    sendgrid_key = decoded.get("sendgridKey", "").strip()
else:
    keys = decoded
    sendgrid_key = ""
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
if len(sys.argv) > 2 and sys.argv[2]:
    if not re.fullmatch(r"SG\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", sendgrid_key):
        raise SystemExit("El codigo es antiguo o no contiene la credencial oficial de SendGrid. Genere uno nuevo.")
    sendgrid_target = pathlib.Path(sys.argv[2])
    sendgrid_target.write_text(sendgrid_key + "\n", encoding="utf-8")
    sendgrid_target.chmod(0o600)
if len(sys.argv) > 3 and sys.argv[3]:
    if parts[0] != "ICARIUS3":
        raise SystemExit("El codigo ICARIUS2 no contiene la credencial de descarga. Genere ICARIUS3 o complete el flujo compatible.")
    registry_target = pathlib.Path(sys.argv[3])
    registry_target.write_text(registry_token + "\n", encoding="utf-8")
    registry_target.chmod(0o600)
if len(sys.argv) > 4 and sys.argv[4]:
    if parts[0] != "ICARIUS3" or not cloud_url_key:
        raise SystemExit("El codigo no contiene la clave privada de URL Cloud.")
    cloud_target = pathlib.Path(sys.argv[4])
    cloud_target.write_text(cloud_url_key + "\n", encoding="utf-8")
    cloud_target.chmod(0o600)
PY
}
if [[ "${1:-}" == '--decode-provisioning-code' ]]; then
  [[ $# -ge 3 && $# -le 7 ]] || fail 'Uso: --decode-provisioning-code CODIGO DESTINO [SENDGRID_DESTINO] [REGISTRY_DESTINO] [CLOUD_DESTINO] [EDICION]'
  decode_provisioning_code "$2" "$3" "${4:-}" "${5:-}" "${6:-}" "${7:-}"
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

say '0/5 - Verificando requisitos del servidor'
host_capacity_preflight
offer_swap_reserve

say "Asistente de instalacion - $PRODUCT"
printf '%s\n' 'Confirme el acceso al configurador. Los valores sugeridos se aceptan con Enter.'

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

provisioning_code=''
registry_token=''
cloud_url_key=''
needs_provisioning=false
for required_file in "$SECRETS_ROOT/ghcr_read_token" "$SECRETS_ROOT/$KEYS_NAME" "$SECRETS_ROOT/sendgrid_key"; do
  [[ -s "$required_file" ]] || needs_provisioning=true
done
if [[ "$EDITION" == cloud && ! -s "$SECRETS_ROOT/cloud_url_key" ]]; then
  needs_provisioning=true
fi

say '1/5 - Preparando el servidor'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || fail 'No se pudo actualizar el indice de paquetes. Revise DNS, firewall o proxy.'
apt-get install -y -qq ca-certificates curl gnupg iproute2 python3 xz-utils >/dev/null
check_outbound 'GitHub' "https://raw.githubusercontent.com/AlbanyTechnologies/icarius-installer/main/install-$EDITION.sh"
check_outbound 'GHCR' 'https://ghcr.io/v2/'
if [[ ! -x "$NODE_ROOT/bin/node" ]]; then
  check_outbound 'Node.js' 'https://nodejs.org/dist/v16.14.0/SHASUMS256.txt'
fi
if ! command -v docker >/dev/null 2>&1; then
  check_outbound 'Docker' 'https://download.docker.com/linux/ubuntu/gpg'
fi
if [[ "$EDITION" == onprem ]]; then
  check_outbound 'licencias ICARIUS' 'https://icarius.online/'
fi
ensure_docker_runtime
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
export PATH="$NODE_ROOT/bin:\$PATH"
if [[ "\${1:-}" == setup-web || "\${1:-}" == ssh-host || "\${1:-}" == export-migration || "\${1:-}" == uninstall ]]; then
  exec "$HOST_ASSISTANT" "\${1:-}" "$INSTALL_ROOT" "\${2:-}"
fi
test -x "$INSTALL_ROOT/bin/icarius" || { echo 'Primero complete el configurador ICARIUS.' >&2; exit 1; }
exec "$INSTALL_ROOT/bin/icarius" "\$@"
EOF
chmod 0755 "/usr/local/bin/$APP_COMMAND"

say '3/5 - Guardando credenciales protegidas'
if [[ "$needs_provisioning" == true ]]; then
  provisioning_code="$(ask_secret "Credencial ICARIUS3 $PRODUCT")"
  [[ -n "$provisioning_code" ]] || fail 'La credencial ICARIUS3 es obligatoria en la primera instalacion.'
fi
if [[ -n "$provisioning_code" ]]; then
  if [[ -z "$temporary" || ! -d "$temporary" ]]; then temporary="$(mktemp -d)"; fi
  decoded_keys="$temporary/$KEYS_NAME"
  decoded_sendgrid="$temporary/sendgrid_key"
  decoded_registry="$temporary/ghcr_read_token"
  decoded_cloud="$temporary/cloud_url_key"
  if [[ "$provisioning_code" == ICARIUS3.* ]]; then
    cloud_output=''
    [[ "$EDITION" == cloud ]] && cloud_output="$decoded_cloud"
    decode_provisioning_code "$provisioning_code" "$decoded_keys" "$decoded_sendgrid" "$decoded_registry" "$cloud_output" "$EDITION"
  elif [[ "$provisioning_code" == ICARIUS2.* ]]; then
    printf '%s\n' 'Compatibilidad ICARIUS2: complete solamente las credenciales que el codigo anterior no contiene.'
    decode_provisioning_code "$provisioning_code" "$decoded_keys" "$decoded_sendgrid"
    if [[ ! -s "$SECRETS_ROOT/ghcr_read_token" ]]; then
      registry_token="$(ask_secret 'Credencial de descarga de imagenes GHCR')"
      [[ -n "$registry_token" ]] || fail 'La credencial de descarga es obligatoria.'
      printf '%s' "$registry_token" > "$decoded_registry"
    fi
    if [[ "$EDITION" == cloud && ! -s "$SECRETS_ROOT/cloud_url_key" ]]; then
      cloud_url_key="$(ask_secret 'Clave privada de URL Cloud')"
      [[ -n "$cloud_url_key" ]] || fail 'La clave privada de URL Cloud es obligatoria.'
      printf '%s' "$cloud_url_key" > "$decoded_cloud"
    fi
  else
    fail 'Use una credencial ICARIUS3 o un codigo ICARIUS2 compatible.'
  fi
  if [[ -s "$SECRETS_ROOT/$KEYS_NAME" ]] && ! cmp -s "$SECRETS_ROOT/$KEYS_NAME" "$decoded_keys"; then
    fail 'El codigo usa claves ICARIUS distintas de esta instalacion. No se modifico ningun secreto.'
  fi
  [[ -s "$SECRETS_ROOT/$KEYS_NAME" ]] || install -m 0600 "$decoded_keys" "$SECRETS_ROOT/$KEYS_NAME"
  [[ -s "$SECRETS_ROOT/sendgrid_key" ]] || install -m 0600 "$decoded_sendgrid" "$SECRETS_ROOT/sendgrid_key"
  [[ -s "$SECRETS_ROOT/ghcr_read_token" ]] || install -m 0600 "$decoded_registry" "$SECRETS_ROOT/ghcr_read_token"
  if [[ "$EDITION" == cloud && ! -s "$SECRETS_ROOT/cloud_url_key" ]]; then
    install -m 0600 "$decoded_cloud" "$SECRETS_ROOT/cloud_url_key"
  fi
fi
chown "$OPERATOR:$OPERATOR" "$SECRETS_ROOT"/*
chmod 0600 "$SECRETS_ROOT"/*
install -d -o 1000 -g 1000 -m 0700 "$INSTALL_ROOT/secrets"
install -d -o 1000 -g 1000 -m 0750 "$INSTALL_ROOT/data/private/temp"
if [[ ! -s "$INSTALL_ROOT/secrets/$KEYS_NAME" ]]; then
  install -o 1000 -g 1000 -m 0600 "$SECRETS_ROOT/$KEYS_NAME" "$INSTALL_ROOT/secrets/$KEYS_NAME"
fi
install -o 1000 -g 1000 -m 0600 "$SECRETS_ROOT/sendgrid_key" "$INSTALL_ROOT/secrets/sendgrid_key"
if [[ "$EDITION" == cloud && ! -s "$INSTALL_ROOT/secrets/cloud_url_key" ]]; then
  install -o 1000 -g 1000 -m 0600 "$SECRETS_ROOT/cloud_url_key" "$INSTALL_ROOT/secrets/cloud_url_key"
fi
unset provisioning_code cloud_url_key registry_token

if [[ -z "$temporary" || ! -d "$temporary" ]]; then
  temporary="$(mktemp -d)"
fi
cat "$SECRETS_ROOT/ghcr_read_token" | runuser -u "$OPERATOR" -- env HOME="/home/$OPERATOR" DOCKER_CONFIG="$DOCKER_CONFIG_ROOT" docker login ghcr.io -u "$REGISTRY_USER" --password-stdin >/dev/null

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
