#!/usr/bin/env bash
set -Eeuo pipefail

command_name="${1:-}"
install_root="${2:-}"
find_server_name_conflicts() {
  local host="$1" own="$2"
  shift 2
  python3 - "$host" "$own" "$@" <<'PY'
import pathlib, re, sys
host = sys.argv[1].lower()
own = pathlib.Path(sys.argv[2]).resolve(strict=False)
seen = set()
for root_name in sys.argv[3:]:
    root = pathlib.Path(root_name)
    candidates = root.rglob('*') if root.is_dir() else [root]
    for candidate in candidates:
        try:
            resolved = candidate.resolve(strict=False)
            if not candidate.is_file() or resolved == own or resolved in seen:
                continue
            seen.add(resolved)
            text = candidate.read_text(encoding='utf-8', errors='ignore')
        except OSError:
            continue
        for line in text.splitlines():
            line = line.split('#', 1)[0].strip()
            match = re.match(r'^server_name\s+(.+?);?$', line)
            if match and host in [item.rstrip(';').lower() for item in match.group(1).split()]:
                print(candidate)
                break
PY
}

if [[ "$command_name" == '--find-server-name-conflicts' ]]; then
  [[ $# -ge 5 ]] || { echo 'Uso interno invalido.' >&2; exit 1; }
  find_server_name_conflicts "$3" "$4" "${@:5}"
  exit 0
fi
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo 'Ejecute con sudo.' >&2; exit 1; }
[[ "$install_root" == /srv/icarius/* ]] || { echo 'Raiz ICARIUS invalida.' >&2; exit 1; }

ask() {
  local prompt="$1" default="${2:-}" answer
  [[ -n "$default" ]] && prompt="$prompt [$default]"
  read -r -p "$prompt: " answer </dev/tty
  printf '%s' "${answer:-$default}"
}

confirm() {
  local answer
  read -r -p "$1 [s/N]: " answer </dev/tty
  [[ "$answer" == s || "$answer" == S ]]
}

require_value() {
  [[ -n "$2" ]] || { echo "Falta $1." >&2; exit 1; }
}

env_value() {
  python3 - "$install_root/config/installation.env" "$1" <<'PY'
import json, pathlib, re, sys
source = pathlib.Path(sys.argv[1])
if not source.is_file():
    raise SystemExit("Primero prepare la instalacion desde el configurador.")
name = sys.argv[2]
match = re.search(r"^" + re.escape(name) + r"=(.+)$", source.read_text(encoding="utf-8"), re.M)
if not match:
    raise SystemExit("Falta " + name + " en la instalacion preparada.")
try:
    print(json.loads(match.group(1)))
except json.JSONDecodeError:
    print(match.group(1))
PY
}

ssh_host() {
  command -v ssh-keyscan >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq openssh-client >/dev/null
  }
  local host port temporary target
  host="$(ask 'DNS o IP del servidor SSH')"
  port="$(ask 'Puerto SSH' '22')"
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo 'Host SSH invalido.' >&2; exit 1; }
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || { echo 'Puerto SSH invalido.' >&2; exit 1; }
  temporary="$(mktemp)"
  trap 'rm -f "$temporary"' RETURN
  echo 'Consultando la identidad publica del servidor...'
  ssh-keyscan -T 10 -p "$port" -H "$host" 2>/dev/null > "$temporary"
  [[ -s "$temporary" ]] || { echo 'No se pudo obtener la identidad SSH. Revise host, puerto y firewall.' >&2; exit 1; }
  echo
  echo 'Huellas encontradas:'
  ssh-keygen -lf "$temporary"
  echo
  echo 'Estas huellas deben coincidir con las informadas por TI por otro canal.'
  confirm 'TI confirmo que alguna de estas huellas es correcta' || { echo 'No se guardo ningun cambio.'; exit 1; }
  target="$install_root/secrets/ssh_known_hosts"
  install -d -m 0755 -o 1000 -g 1000 "$install_root/secrets"
  install -m 0644 -o 1000 -g 1000 "$temporary" "$target"
  echo "Identidad SSH guardada para esta instalacion."
  echo 'Vuelva al Preparer: no necesita seleccionar un archivo known_hosts.'
}

setup_web() {
  local public_origin tls_mode edge_port host email site_name available enabled temporary backup_dir
  local enabled_target='' conflicts='' port_listener='' dns_addresses=''
  public_origin="$(env_value ICARIUS_PUBLIC_ORIGIN)"
  tls_mode="$(env_value ICARIUS_TLS_MODE)"
  edge_port="$(env_value ICARIUS_EDGE_HOST_PORT)"
  [[ "$tls_mode" == proxy ]] || {
    echo "Esta instalacion usa TLS $tls_mode. Nginx y Certbot no son necesarios y no se modificaron."
    return 0
  }
  host="$(python3 - "$public_origin" <<'PY'
import sys, urllib.parse
url = urllib.parse.urlparse(sys.argv[1])
if url.scheme != "https" or not url.hostname or url.port or url.path not in ("", "/"):
    raise SystemExit("El origen publico debe ser https://DNS sin puerto ni ruta.")
print(url.hostname)
PY
)"
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$host" == *.* ]] || {
    echo 'El origen publico no contiene un DNS valido para Certbot.' >&2
    exit 1
  }
  [[ "$edge_port" =~ ^[0-9]+$ && "$edge_port" -ge 1 && "$edge_port" -le 65535 ]] || {
    echo 'Puerto interno ICARIUS invalido.' >&2
    exit 1
  }
  curl -fsS --max-time 10 "http://127.0.0.1:$edge_port/health" >/dev/null || {
    echo 'ICARIUS no responde localmente. Ejecute primero el comando start y vuelva a intentar.' >&2
    exit 1
  }
  dns_addresses="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)"
  [[ -n "$dns_addresses" ]] || { echo "El DNS $host no resuelve desde el VPS." >&2; exit 1; }
  for port in 80 443; do
    port_listener="$(ss -ltnp 2>/dev/null | awk -v port=":$port" '$4 ~ port "$" {print}')"
    if [[ -n "$port_listener" && "$port_listener" != *nginx* ]]; then
      echo "El puerto $port esta ocupado por otro servicio. No se modifico Nginx." >&2
      echo "$port_listener" >&2
      exit 1
    fi
  done
  echo "DNS detectado: $host -> $dns_addresses"
  echo "ICARIUS local: http://127.0.0.1:$edge_port"
  echo 'TI debe permitir entrada TCP 80 y 443 hacia este VPS durante la emision y operacion HTTPS.'
  confirm 'Configurar o actualizar Nginx y Certbot con estos datos' || { echo 'No se guardo ningun cambio.'; exit 1; }
  email="$(ask 'Email para avisos de renovacion de certificado')"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo 'Email invalido. No se guardo ningun cambio.' >&2; exit 1; }

  site_name="icarius-$(basename "$install_root")"
  available="/etc/nginx/sites-available/$site_name.conf"
  enabled="/etc/nginx/sites-enabled/$site_name.conf"
  if [[ -e "$available" ]] && ! grep -q '^# Managed by ICARIUS$' "$available"; then
    echo "Ya existe $available y no fue generado por ICARIUS. No se modifico." >&2
    exit 1
  fi
  if [[ -e "$enabled" ]]; then
    enabled_target="$(readlink -f "$enabled" 2>/dev/null || true)"
    [[ "$enabled_target" == "$available" ]] || { echo "$enabled pertenece a otro sitio. No se modifico." >&2; exit 1; }
  fi
  conflicts="$(find_server_name_conflicts "$host" "$available" /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d)"
  [[ -z "$conflicts" ]] || {
    echo "El DNS $host ya esta declarado en otra configuracion Nginx:" >&2
    echo "$conflicts" >&2
    echo 'Retire el server_name duplicado en una ventana controlada y vuelva a ejecutar.' >&2
    exit 1
  }

  if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1 || ! certbot plugins 2>/dev/null | grep -q nginx; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || { echo 'No se pudo actualizar el indice de paquetes.' >&2; exit 1; }
    apt-get install -y -qq nginx certbot python3-certbot-nginx >/dev/null
  fi
  systemctl enable --now nginx >/dev/null

  temporary="$(mktemp)"
  backup_dir="$(mktemp -d)"
  trap 'rm -f "$temporary"; rm -rf "$backup_dir"' RETURN
  [[ -e "$available" ]] && cp -a "$available" "$backup_dir/available.conf"
  rollback_web_config() {
    rm -f "$enabled" "$available"
    if [[ -f "$backup_dir/available.conf" ]]; then
      install -m 0644 "$backup_dir/available.conf" "$available"
      ln -sfn "$available" "$enabled"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  }
  {
    echo '# Managed by ICARIUS'
    echo 'server {'
    echo '    listen 80;'
    echo '    listen [::]:80;'
    printf '    server_name %s;\n' "$host"
    echo '    location / {'
    printf '        proxy_pass http://127.0.0.1:%s;\n' "$edge_port"
    echo '        proxy_http_version 1.1;'
    echo '        proxy_set_header Host $host;'
    echo '        proxy_set_header X-Real-IP $remote_addr;'
    echo '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
    echo '        proxy_set_header X-Forwarded-Proto $scheme;'
    echo '        proxy_set_header Upgrade $http_upgrade;'
    echo '        proxy_set_header Connection upgrade;'
    echo '        proxy_read_timeout 600s;'
    echo '    }'
    echo '}'
  } > "$temporary"
  install -m 0644 "$temporary" "$available"
  ln -sfn "$available" "$enabled"
  if ! nginx -t; then
    rollback_web_config
    echo 'La configuracion Nginx no fue aplicada porque la validacion fallo.' >&2
    exit 1
  fi
  systemctl reload nginx
  command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active' && ufw allow 'Nginx Full' >/dev/null || true
  if ! curl -fsS --max-time 15 "http://$host/health" >/dev/null; then
    rollback_web_config
    echo "El DNS no alcanza este VPS por HTTP. TI debe habilitar TCP 80 para $host antes de Certbot." >&2
    exit 1
  fi
  if ! certbot --nginx --redirect --non-interactive --agree-tos --keep-until-expiring --email "$email" -d "$host"; then
    rollback_web_config
    echo 'Certbot no pudo emitir o renovar el certificado; se restauro el sitio anterior.' >&2
    exit 1
  fi
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  if ! nginx -t || ! curl -fsS --max-time 15 "https://$host/health" >/dev/null; then
    rollback_web_config
    echo 'La publicacion HTTPS no paso health; se restauro el sitio anterior.' >&2
    exit 1
  fi
  systemctl reload nginx
  echo "ICARIUS publicado correctamente en https://$host"
  echo 'La renovacion automatica de Certbot quedo habilitada.'
}
uninstall_icarius() {
  local mode="${3:---dry-run}" app_command preparer_command preparer_root preparer_project docker_config_root
  local site_name available enabled backup preparer_port=''
  case "$install_root" in
    /srv/icarius/onprem)
      app_command='icarius'
      preparer_command='icarius-preparer'
      preparer_root='/srv/icarius/preparer-onprem'
      preparer_project='icarius-preparer-onprem'
      docker_config_root='/home/icarius/.docker'
      ;;
    /srv/icarius/cloud)
      app_command='icarius-cloud'
      preparer_command='icarius-preparer-cloud'
      preparer_root='/srv/icarius/preparer-cloud'
      preparer_project='icarius-preparer-cloud'
      docker_config_root='/home/icarius/.docker-cloud'
      ;;
    *) echo 'Raiz ICARIUS no autorizada para desinstalacion.' >&2; exit 1 ;;
  esac
  [[ "$mode" == --dry-run || "$mode" == --confirm ]] || {
    echo "Uso: $app_command uninstall --dry-run|--confirm" >&2
    exit 1
  }
  [[ -x "$install_root/bin/icarius" ]] || {
    echo 'La instalacion no tiene runtime activo. Los datos persistentes no fueron modificados.' >&2
    exit 1
  }
  export PATH="/opt/icarius/node-v16.14.0-linux-x64/bin:$PATH"
  export DOCKER_CONFIG="$docker_config_root"
  if [[ "$mode" == --dry-run ]]; then
    "$install_root/bin/icarius" uninstall --dry-run
    echo
    echo 'Tambien se retiraran el Preparer y los comandos globales de esta edicion.'
    echo 'Se conservaran datos, configuracion, secretos, certificados, backups y auditoria.'
    echo "Para aplicar: sudo $app_command uninstall --confirm"
    return
  fi

  if [[ -f "$preparer_root/preparer.env" ]]; then
    preparer_port="$(sed -n 's/^ICARIUS_PREPARER_HOST_PORT=//p' "$preparer_root/preparer.env" | tail -1)"
  fi
  if [[ -f "$preparer_root/compose.yaml" && -f "$preparer_root/preparer.env" ]]; then
    docker compose --project-name "$preparer_project" --project-directory "$preparer_root" \
      --env-file "$preparer_root/preparer.env" -f "$preparer_root/compose.yaml" down --remove-orphans --timeout 25
  fi

  "$install_root/bin/icarius" uninstall --confirm

  site_name="icarius-$(basename "$install_root")"
  available="/etc/nginx/sites-available/$site_name.conf"
  enabled="/etc/nginx/sites-enabled/$site_name.conf"
  if [[ -f "$available" ]] && grep -q '^# Managed by ICARIUS$' "$available"; then
    backup="$(mktemp)"
    cp -a "$available" "$backup"
    rm -f "$enabled" "$available"
    if command -v nginx >/dev/null 2>&1 && ! nginx -t; then
      install -m 0644 "$backup" "$available"
      ln -sfn "$available" "$enabled"
      rm -f "$backup"
      echo 'No se retiro el sitio Nginx porque la configuracion restante no es valida.' >&2
      exit 1
    fi
    rm -f "$backup"
    systemctl reload nginx >/dev/null 2>&1 || true
  fi

  rm -rf "$preparer_root"
  rm -f "/usr/local/bin/$preparer_command" "/usr/local/bin/$app_command"
  echo 'ICARIUS fue desinstalado sin borrar informacion persistente.'
  echo "Datos conservados: $install_root/data"
  echo "Configuracion conservada: $install_root/config"
  echo "Secretos y certificados conservados bajo: $install_root"
  [[ -n "$preparer_port" ]] && echo "El puerto temporal $preparer_port ya no es utilizado por el Preparer."
  echo 'Para reinstalar, ejecute nuevamente el instalador de esta edicion.'
}

export_migration() {
  local destination="${3:-}"
  [[ -x "$install_root/bin/icarius" ]] || { echo 'Primero complete el configurador ICARIUS.' >&2; exit 1; }
  export PATH="/opt/icarius/node-v16.14.0-linux-x64/bin:$PATH"
  local exporter="$install_root/bin/runtime/ops/prepared-migration-export.js"
  [[ -f "$exporter" ]] || { echo 'La release instalada no incluye el exportador de migracion Ubuntu.' >&2; exit 1; }
  if [[ -n "$destination" ]]; then
    node "$exporter" --root "$install_root" --destination "$destination"
  else
    node "$exporter" --root "$install_root"
  fi
  echo
  echo 'Copie fuera del servidor los tres archivos generados.'
  echo 'El paquete y la passphrase deben conservarse separados hasta el momento de importar.'
}

case "$command_name" in
  ssh-host) ssh_host ;;
  setup-web) setup_web ;;
  uninstall) uninstall_icarius "$@" ;;
  export-migration) export_migration "$@" ;;
  *) echo 'Uso: icarius ssh-host | icarius setup-web | icarius export-migration [directorio] | icarius uninstall --dry-run|--confirm' >&2; exit 1 ;;
esac
