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

legacy_site_compatible() {
  local source="$1" host="$2" port="$3" proxy_count
  [[ -f "$source" ]] || return 1
  ! grep -q '^# Managed by ICARIUS$' "$source" || return 1
  grep -Eiq "^[[:space:]]*server_name[[:space:]]+([^;[:space:]]+[[:space:]]+)*${host//./\\.}([[:space:]]+[^;[:space:]]+)*;[[:space:]]*$" "$source" || return 1
  proxy_count="$(grep -Ec '^[[:space:]]*proxy_pass[[:space:]]+' "$source" || true)"
  [[ "$proxy_count" -eq 1 ]] || return 1
  grep -Eq "^[[:space:]]*proxy_pass[[:space:]]+http://127\\.0\\.0\\.1:${port}/?;[[:space:]]*$" "$source"
}

if [[ "$command_name" == '--find-server-name-conflicts' ]]; then
  [[ $# -ge 5 ]] || { echo 'Uso interno invalido.' >&2; exit 1; }
  find_server_name_conflicts "$3" "$4" "${@:5}"
  exit 0
fi
if [[ "$command_name" == '--legacy-site-compatible' ]]; then
  [[ $# -eq 5 ]] || { echo 'Uso interno invalido.' >&2; exit 1; }
  legacy_site_compatible "$3" "$4" "$5"
  exit $?
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
  local legacy_available='' legacy_enabled='' legacy_backup_dir='' legacy_removed=0 conflict_count=0
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
  if [[ -e "$enabled" ]]; then
    enabled_target="$(readlink -f "$enabled" 2>/dev/null || true)"
    [[ "$enabled_target" == "$available" ]] || { echo "$enabled pertenece a otro sitio. No se modifico." >&2; exit 1; }
  fi
  conflicts="$(find_server_name_conflicts "$host" "$available" /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d)"
  if [[ -e "$available" ]] && ! grep -q '^# Managed by ICARIUS$' "$available"; then
    conflicts="$(printf '%s\n%s\n' "$available" "$conflicts" | sed '/^$/d')"
  fi
  if [[ -n "$conflicts" ]]; then
    conflict_count="$(printf '%s\n' "$conflicts" | sed '/^$/d' | wc -l)"
    legacy_available="$(printf '%s\n' "$conflicts" | sed '/^$/d' | head -1)"
    legacy_available="$(readlink -f "$legacy_available" 2>/dev/null || true)"
    if [[ "$conflict_count" -ne 1 || "$legacy_available" != /etc/nginx/sites-available/* ]] ||
       ! legacy_site_compatible "$legacy_available" "$host" "$edge_port"; then
      echo "El DNS $host ya esta declarado en otra configuracion Nginx que no puede adoptarse automaticamente:" >&2
      echo "$conflicts" >&2
      echo 'No se modifico ningun sitio.' >&2
      exit 1
    fi
    while IFS= read -r candidate; do
      if [[ "$(readlink -f "$candidate" 2>/dev/null || true)" == "$legacy_available" ]]; then
        [[ -z "$legacy_enabled" ]] || {
          echo 'La configuracion anterior tiene mas de un enlace habilitado y no puede adoptarse automaticamente.' >&2
          exit 1
        }
        legacy_enabled="$candidate"
      fi
    done < <(find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print)
    [[ -n "$legacy_enabled" ]] || {
      echo 'La configuracion anterior no tiene un unico sitio habilitado y no puede adoptarse automaticamente.' >&2
      exit 1
    }
    echo "Se encontro una publicacion anterior compatible: $legacy_available"
    echo 'Apunta al mismo ICARIUS local y se respaldara antes de reemplazarla.'
    confirm 'Adoptar esta publicacion bajo administracion de ICARIUS' || { echo 'No se modifico ningun sitio.'; exit 1; }
  fi

  if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1 || ! certbot plugins 2>/dev/null | grep -q nginx; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || { echo 'No se pudo actualizar el indice de paquetes.' >&2; exit 1; }
    apt-get install -y -qq nginx certbot python3-certbot-nginx >/dev/null
  fi
  systemctl enable --now nginx >/dev/null

  temporary="$(mktemp)"
  backup_dir="$(mktemp -d)"
  trap 'rm -f "$temporary"; rm -rf "$backup_dir"' RETURN
  if [[ -n "$legacy_available" ]]; then
    legacy_backup_dir="$install_root/backups/nginx-adoption-$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -m 0700 "$legacy_backup_dir"
    cp -a "$legacy_available" "$legacy_backup_dir/site.conf"
    printf 'source=%s\nenabled=%s\nhost=%s\n' "$legacy_available" "$legacy_enabled" "$host" > "$legacy_backup_dir/manifest.txt"
  elif [[ -e "$available" ]]; then
    cp -a "$available" "$backup_dir/available.conf"
  fi
  rollback_web_config() {
    rm -f "$enabled" "$available"
    if [[ -f "$backup_dir/available.conf" ]]; then
      install -m 0644 "$backup_dir/available.conf" "$available"
      ln -sfn "$available" "$enabled"
    fi
    if [[ "$legacy_removed" -eq 1 ]]; then
      install -m 0644 "$legacy_backup_dir/site.conf" "$legacy_available"
      ln -sfn "$legacy_available" "$legacy_enabled"
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
  if [[ -n "$legacy_available" ]]; then
    legacy_removed=1
    if [[ "$legacy_available" != "$available" ]]; then
      rm -f "$legacy_enabled" "$legacy_available"
    fi
  fi
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
  [[ -n "$legacy_backup_dir" ]] && echo "Configuracion anterior respaldada en: $legacy_backup_dir"
}
uninstall_icarius() {
  local mode="${3:-}" app_command preparer_command preparer_root preparer_project docker_config_root edition
  local site_name available enabled backup preparer_port='' confirmation expected reclaimed_kib audit_file
  local export_dir exporter importer gate export_output package passphrase checksum verification_workspace
  local preview_json storage_root
  case "$install_root" in
    /srv/icarius/onprem)
      app_command='icarius'
      preparer_command='icarius-preparer'
      preparer_root='/srv/icarius/preparer-onprem'
      preparer_project='icarius-preparer-onprem'
      docker_config_root='/home/icarius/.docker'
      edition='on-premise'
      ;;
    /srv/icarius/cloud)
      app_command='icarius-cloud'
      preparer_command='icarius-preparer-cloud'
      preparer_root='/srv/icarius/preparer-cloud'
      preparer_project='icarius-preparer-cloud'
      docker_config_root='/home/icarius/.docker-cloud'
      edition='central-cloud'
      ;;
    *) echo 'Raiz ICARIUS no autorizada para desinstalacion.' >&2; exit 1 ;;
  esac
  [[ -z "$mode" || "$mode" == --dry-run || "$mode" == --confirm ]] || {
    echo "Uso: sudo $app_command uninstall" >&2
    exit 1
  }
  [[ -x "$install_root/bin/icarius" ]] || {
    echo 'La instalacion no tiene runtime activo. Los datos persistentes no fueron modificados.' >&2
    exit 1
  }
  export PATH="/opt/icarius/node-v16.14.0-linux-x64/bin:$PATH"
  export DOCKER_CONFIG="$docker_config_root"
  preview_json="$("$install_root/bin/icarius" uninstall --dry-run)"
  storage_root="$(printf '%s' "$preview_json" | node -e 'let value="";process.stdin.on("data",chunk=>value+=chunk);process.stdin.on("end",()=>process.stdout.write(JSON.parse(value).storage.root));')"
  if [[ -z "$mode" ]]; then
    echo
    echo "Desinstalacion guiada - $edition"
    echo '1) Desinstalar la aplicacion y conservar toda la informacion persistente.'
    echo '2) Crear una migracion cifrada verificada y eliminar completamente esta edicion.'
    echo '3) Cancelar.'
    read -r -p 'Seleccione una opcion [1-3]: ' mode
    case "$mode" in
      1) mode='partial' ;;
      2) mode='complete' ;;
      3|'') echo 'Desinstalacion cancelada.'; return ;;
      *) echo 'Opcion invalida. No se modifico nada.' >&2; exit 1 ;;
    esac
  fi
  if [[ "$mode" == --dry-run ]]; then
    printf '%s\n' "$preview_json"
    echo
    echo 'Tambien se retiraran el Preparer y los comandos globales de esta edicion.'
    echo 'Se conservaran datos, configuracion, secretos, certificados, backups y auditoria.'
    return
  fi

  if [[ "$mode" == --confirm ]]; then
    mode='partial-internal'
  elif [[ "$mode" == partial ]]; then
    echo
    echo 'Se eliminaran contenedores, releases, runtime, comando y sitio Nginx administrado de esta edicion.'
    echo 'Se conservaran data, configuracion, secretos, certificados, backups y auditoria.'
    read -r -p 'Escriba DESINSTALAR para continuar: ' confirmation
    [[ "$confirmation" == DESINSTALAR ]] || { echo 'Desinstalacion cancelada.'; return; }
  elif [[ "$mode" == complete ]]; then
    export_dir="/srv/icarius-exports/$(basename "$install_root")"
    echo
    echo 'La desinstalacion completa crea y verifica una migracion cifrada antes de eliminar datos.'
    echo "Carpeta externa sugerida: $export_dir"
    read -r -p 'Carpeta de salida o Enter para usar la sugerida: ' confirmation
    [[ -n "$confirmation" ]] && export_dir="$confirmation"
    exporter="$install_root/bin/runtime/ops/prepared-migration-export.js"
    importer="$install_root/bin/runtime/ops/legacy-migration-import.js"
    gate="$install_root/bin/runtime/preparer/complete-uninstall-gate.js"
    [[ -f "$exporter" && -f "$importer" && -f "$gate" ]] || {
      echo 'La release activa no incluye exportacion y verificacion para desinstalacion completa.' >&2
      exit 1
    }
    export_dir="$(node "$gate" paths "$install_root" "$storage_root" "$export_dir" | node -e 'let value="";process.stdin.on("data",chunk=>value+=chunk);process.stdin.on("end",()=>process.stdout.write(JSON.parse(value).destination));')" || {
      echo 'La carpeta de salida no es segura. No se modifico la instalacion.' >&2
      exit 1
    }
    install -d -m 0700 "$export_dir"
    export_output="$(node "$exporter" --root "$install_root" --destination "$export_dir")" || {
      echo 'No se pudo crear la migracion. No se modifico la instalacion.' >&2
      exit 1
    }
    printf '%s\n' "$export_output"
    package="$(printf '%s\n' "$export_output" | sed -n 's/^Paquete: //p' | tail -1)"
    passphrase="$(printf '%s\n' "$export_output" | sed -n 's/^Passphrase separada: //p' | tail -1)"
    checksum="$(printf '%s\n' "$export_output" | sed -n 's/^Integridad SHA-256: //p' | tail -1)"
    [[ -f "$package" && -f "$passphrase" && -f "$checksum" ]] || {
      echo 'La migracion no genero sus tres archivos obligatorios. No se modifico la instalacion.' >&2
      exit 1
    }
    node "$gate" backup "$package" "$passphrase" "$checksum" >/dev/null || {
      echo 'Los archivos de migracion no pasaron la verificacion. No se modifico la instalacion.' >&2
      exit 1
    }
    verification_workspace="$(mktemp -d)"
    if ! node "$importer" --source "$package" --passphrase-file "$passphrase" --workspace "$verification_workspace" --dry-run --edition "$edition" >/dev/null; then
      rm -rf "$verification_workspace"
      echo 'La migracion no pudo abrirse y verificarse. No se modifico la instalacion.' >&2
      exit 1
    fi
    rm -rf "$verification_workspace"
    echo 'Migracion cifrada, checksum y lectura de recuperacion: OK.'
    echo "Paquete preservado fuera de ICARIUS: $package"
    expected="ELIMINAR $edition"
    read -r -p "Escriba exactamente '$expected' para borrar esta edicion: " confirmation
    [[ "$confirmation" == "$expected" ]] || { echo 'Desinstalacion cancelada. La migracion queda conservada.'; return; }
  fi

  if [[ "$mode" == complete ]]; then
    case "$storage_root/" in
      "$install_root/"*) reclaimed_kib="$(du -sk "$install_root" "$preparer_root" 2>/dev/null | awk '{total += $1} END {print total + 0}')" ;;
      *) reclaimed_kib="$(du -sk "$install_root" "$storage_root" "$preparer_root" 2>/dev/null | awk '{total += $1} END {print total + 0}')" ;;
    esac
  else
    reclaimed_kib="$(du -sk "$install_root/compose" "$install_root/releases" "$install_root/bin" "$preparer_root" 2>/dev/null | awk '{total += $1} END {print total + 0}')"
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
  if [[ "$mode" == complete ]]; then
    rm -rf "$install_root"
    case "$storage_root/" in "$install_root/"*) ;; *) rm -rf "$storage_root" ;; esac
    audit_file="$export_dir/uninstall-complete-$(date -u +%Y%m%dT%H%M%SZ).log"
    {
      echo "edition=$edition"
      echo "installation_root=$install_root"
      echo "migration_package=$package"
      echo "checksum_file=$checksum"
      echo "completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$audit_file"
    chmod 0600 "$audit_file"
    echo "ICARIUS $edition fue eliminado completamente."
    echo "Migracion recuperable: $package"
    echo "Passphrase separada: $passphrase"
    echo "Auditoria: $audit_file"
  else
    echo 'ICARIUS fue desinstalado sin borrar informacion persistente.'
    echo "Datos conservados: $install_root/data"
    echo "Configuracion conservada: $install_root/config"
    echo "Secretos y certificados conservados bajo: $install_root"
  fi
  echo "Espacio estimado liberado: $reclaimed_kib KiB"
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

export_client() {
  [[ -x $install_root/bin/icarius ]] || { echo 'Primero complete el configurador ICARIUS.'; exit 1; }
  export PATH=/opt/icarius/node-v16.14.0-linux-x64/bin:$PATH
  local exporter=$install_root/bin/runtime/ops/prepared-client-export.js
  [[ -f $exporter ]] || { echo 'La release instalada no incluye el exportador individual de clientes.'; exit 1; }
  if ! command -v zip; then
    apt-get update -qq
    apt-get install -y -qq zip
  fi
  echo 'Clientes disponibles:'
  node $exporter --root $install_root --list
  local code destination default_destination
  read -r -p 'Codigo de cliente a exportar: ' code
  default_destination=$install_root/backups/clients
  echo Carpeta de salida sugerida: $default_destination
  read -r -p 'Carpeta de salida o Enter para usar la sugerida: ' destination
  if [[ -z $destination ]]; then destination=$default_destination; fi
  node $exporter --root $install_root --code $code --destination $destination
  echo
  echo 'Suba este ZIP desde Clientes, Importar datos de un cliente.'
}

manage_version() {
  local edition preparer_package preparer_root secrets_root catalogs selected version application_version hrb_id current_application image uid_gid confirmation backup_reference confirmed_by
  [[ -x "$install_root/bin/icarius" ]] || { echo 'Primero complete el configurador ICARIUS.' >&2; exit 1; }
  edition="$(python3 - "$install_root/config/installation-state.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['edition'])
PY
)"
  case "$edition" in
    on-premise) preparer_package='icarius-preparer-onprem'; preparer_root='/srv/icarius/preparer-onprem'; secrets_root='/srv/icarius/preparer-secrets/onprem' ;;
    central-cloud) preparer_package='icarius-preparer-cloud'; preparer_root='/srv/icarius/preparer-cloud'; secrets_root='/srv/icarius/preparer-secrets/cloud' ;;
    *) echo 'La edicion instalada no es valida.' >&2; exit 1 ;;
  esac
  [[ -s "$secrets_root/ghcr_read_token" ]] || { echo 'Falta la credencial protegida de descarga GHCR.' >&2; exit 1; }
  [[ -s "$preparer_root/preparer.env" ]] || { echo 'Falta la configuracion del Preparador. Ejecute nuevamente el instalador de esta edicion.' >&2; exit 1; }
  image="$(sed -n 's/^ICARIUS_PREPARER_IMAGE=//p' "$preparer_root/preparer.env" | tail -1)"
  [[ "$image" =~ ^ghcr\.io/maxglomba/$preparer_package:[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'La imagen configurada del Preparador no es valida.' >&2; exit 1; }
  docker image inspect "$image" >/dev/null 2>&1 || { echo 'El Preparador actualizado no esta disponible localmente. Ejecute nuevamente el instalador de esta edicion.' >&2; exit 1; }
  uid_gid="$(stat -c '%u:%g' "$install_root")"
  catalogs="$(docker run --rm --pull never --user "$uid_gid" \
    -v "$install_root:/workspace" \
    -v "$secrets_root:/run/secrets:ro" \
    "$image" node docker/preparer/release-manager.js list \
      --root /workspace --token-file /run/secrets/ghcr_read_token --limit 3)" || exit 1
  [[ "$catalogs" != '[]' ]] || { echo 'No hay versiones autorizadas disponibles.' >&2; exit 1; }
  current_application="$(python3 - "$install_root" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
try:
    state = json.load(open(root / 'config/host-state.json', encoding='utf-8'))
    release = json.load(open(root / 'releases' / state['current'] / 'manifest.json', encoding='utf-8'))
    print(release.get('applicationVersion', release['version']))
except Exception:
    print('')
PY
)"
  if [[ "$command_name" == update ]]; then
    selected=1
  else
    echo 'Versiones autorizadas:'
    python3 - "$catalogs" <<'PY'
import json, sys
for index, item in enumerate(json.loads(sys.argv[1]), 1):
    state = ' (activa)' if item.get('current') else ''
    print(f"  {index}) ICARIUS {item['applicationVersion']} - release {item['version']}{state}")
PY
    read -r -p 'Seleccione una version o Enter para cancelar: ' selected </dev/tty
    [[ -n "$selected" ]] || { echo 'Cambio de version cancelado.'; return; }
  fi
  [[ "$selected" =~ ^[1-9][0-9]*$ ]] || { echo 'Seleccion invalida.' >&2; exit 1; }
  readarray -t release_values < <(python3 - "$catalogs" "$selected" <<'PY'
import json, sys
items=json.loads(sys.argv[1]); index=int(sys.argv[2])-1
if index < 0 or index >= len(items): raise SystemExit(2)
item=items[index]
print(item['version']); print(item['applicationVersion']); print(item['hrbId']); print('true' if item.get('current') else 'false')
PY
) || { echo 'La version seleccionada no existe.' >&2; exit 1; }
  version="${release_values[0]}"
  application_version="${release_values[1]}"
  hrb_id="${release_values[2]}"
  if [[ "${release_values[3]}" == true ]]; then
    echo "ICARIUS $application_version - release $version ya esta activa."
    return
  fi
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version autorizada invalida.' >&2; exit 1; }
  if [[ -n "$current_application" && "$current_application" != "$application_version" ]]; then
    echo "La version requiere $hrb_id aplicado y un backup verificable de la base."
    read -r -p "Escriba exactamente '$hrb_id' para confirmar el HRB: " confirmation </dev/tty
    [[ "$confirmation" == "$hrb_id" ]] || { echo 'Actualizacion cancelada; no se descargo ni preparo la nueva version.'; return; }
    read -r -p 'Referencia del backup de base de datos: ' backup_reference </dev/tty
    [[ -n "$backup_reference" ]] || { echo 'La referencia del backup es obligatoria.' >&2; exit 1; }
    read -r -p 'Usuario o tecnico que confirma: ' confirmed_by </dev/tty
    [[ -n "$confirmed_by" ]] || { echo 'El responsable de la confirmacion es obligatorio.' >&2; exit 1; }
  fi
  echo "Preparando ICARIUS $application_version - release $version"
  docker run --rm --pull never --user "$uid_gid" \
    -v "$install_root:/workspace" \
    -v "$secrets_root:/run/secrets:ro" \
    "$image" node docker/preparer/release-manager.js prepare \
      --root /workspace --host-root "$install_root" --version "$version" >/dev/null
  if [[ -n "$current_application" && "$current_application" != "$application_version" ]]; then
    "$install_root/bin/icarius" start --hrb-confirmed "$hrb_id" --db-backup-reference "$backup_reference" --confirmed-by "$confirmed_by"
  else
    "$install_root/bin/icarius" start
  fi
}

rollback_version() {
  [[ -x "$install_root/bin/icarius" ]] || { echo 'Primero complete el configurador ICARIUS.' >&2; exit 1; }
  local current_application previous_application current_hrb previous_hrb compatible
  local -a rollback_values
  readarray -t rollback_values < <(python3 - "$install_root" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]); state=json.load(open(root/'config/host-state.json', encoding='utf-8'))
if not state.get('previous'): raise SystemExit(2)
def manifest(release): return json.load(open(root/'releases'/release/'manifest.json', encoding='utf-8'))
current=manifest(state['current']); previous=manifest(state['previous'])
current_app=current.get('applicationVersion', current['version']); previous_app=previous.get('applicationVersion', previous['version'])
current_hrb=current.get('databasePrerequisite', {}).get('hrbId', 'HRB-' + current_app)
previous_hrb=previous.get('databasePrerequisite', {}).get('hrbId', 'HRB-' + previous_app)
compatible=previous.get('databasePrerequisite', {}).get('compatibleHrbs', [previous_hrb])
print(current_app); print(previous_app); print(current_hrb); print(previous_hrb); print('true' if current_hrb in compatible else 'false')
PY
) || true
  [[ "${#rollback_values[@]}" -eq 5 ]] || { echo 'No hay una version anterior disponible.' >&2; exit 1; }
  current_application="${rollback_values[0]}"
  previous_application="${rollback_values[1]}"
  current_hrb="${rollback_values[2]}"
  previous_hrb="${rollback_values[3]}"
  compatible="${rollback_values[4]}"
  if [[ "$compatible" != true ]]; then
    echo "Rollback bloqueado: ICARIUS $previous_application no declara compatibilidad con $current_hrb." >&2
    echo "La release anterior requiere $previous_hrb." >&2
    echo 'El codigo no se revierte automaticamente cuando la base puede ser incompatible.' >&2
    exit 1
  fi
  echo "Se volvera a la release anterior de ICARIUS $previous_application."
  confirm 'Continuar con rollback' || { echo 'Rollback cancelado.'; return; }
  "$install_root/bin/icarius" rollback
}

case "$command_name" in
  ssh-host) ssh_host ;;
  setup-web) setup_web ;;
  uninstall) uninstall_icarius "$@" ;;
  export-migration) export_migration "$@" ;;
  export-client) export_client "$@" ;;
  update|change-version) manage_version ;;
  rollback) rollback_version ;;
  *) echo 'Uso: icarius ssh-host | icarius setup-web | icarius update | icarius change-version | icarius rollback | icarius export-migration [directorio] | icarius export-client | icarius uninstall' >&2; exit 1 ;;
esac
