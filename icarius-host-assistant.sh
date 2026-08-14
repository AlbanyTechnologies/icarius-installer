#!/usr/bin/env bash
set -Eeuo pipefail

command_name="${1:-}"
install_root="${2:-}"
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
  local public_origin tls_mode edge_port host email site_name available enabled temporary backup=''
  public_origin="$(env_value ICARIUS_PUBLIC_ORIGIN)"
  tls_mode="$(env_value ICARIUS_TLS_MODE)"
  edge_port="$(env_value ICARIUS_EDGE_HOST_PORT)"
  [[ "$tls_mode" == proxy ]] || {
    echo "Esta instalacion usa TLS $tls_mode. El asistente Nginx/Certbot se utiliza solamente con TLS externo."
    exit 1
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
  echo "DNS detectado: $host"
  echo "ICARIUS local: http://127.0.0.1:$edge_port"
  confirm 'Configurar o actualizar Nginx y Certbot con estos datos' || { echo 'No se guardo ningun cambio.'; exit 1; }
  curl -fsS --max-time 10 "http://127.0.0.1:$edge_port/health" >/dev/null || {
    echo 'ICARIUS no responde localmente. Ejecute primero el comando start y vuelva a intentar.' >&2
    exit 1
  }
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq nginx certbot python3-certbot-nginx >/dev/null
  site_name="icarius-$(basename "$install_root")"
  available="/etc/nginx/sites-available/$site_name.conf"
  enabled="/etc/nginx/sites-enabled/$site_name.conf"
  if [[ -e "$available" ]] && ! grep -q '^# Managed by ICARIUS$' "$available"; then
    echo "Ya existe $available y no fue generado por ICARIUS. No se modifico." >&2
    exit 1
  fi
  temporary="$(mktemp)"
  trap 'rm -f "$temporary"' RETURN
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
  [[ -e "$available" ]] && { backup="$available.before-icarius"; cp -a "$available" "$backup"; }
  install -m 0644 "$temporary" "$available"
  ln -sfn "$available" "$enabled"
  if ! nginx -t; then
    [[ -n "$backup" ]] && mv -f "$backup" "$available" || rm -f "$available" "$enabled"
    echo 'La configuracion Nginx no fue aplicada porque la validacion fallo.' >&2
    exit 1
  fi
  rm -f "$backup"
  systemctl enable --now nginx
  systemctl reload nginx
  command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active' && ufw allow 'Nginx Full' >/dev/null || true
  email="$(ask 'Email para avisos de renovacion de certificado')"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo 'Email invalido.' >&2; exit 1; }
  certbot --nginx --redirect --non-interactive --agree-tos --keep-until-expiring --email "$email" -d "$host"
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  curl -fsS --max-time 15 "https://$host/health" >/dev/null
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
