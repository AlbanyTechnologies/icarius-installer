# Instalador ICARIUS

Bootstrap oficial para preparar una instalación **ICARIUS On-Premise** en un VPS Ubuntu.

El instalador de soporte debe conectarse por SSH y ejecutar:

```bash
curl -fsSL https://raw.githubusercontent.com/AlbanyTechnologies/icarius-installer/main/install-onprem.sh | sudo bash
```

El asistente instala los requisitos del host y solicita únicamente la IP o DNS,
el puerto temporal del configurador y una credencial confidencial `ICARIUS3`
entregada por soporte ICARIUS. La credencial es reutilizable y está separada por
edición: On-Premise nunca autoriza imágenes Central Cloud y viceversa.

## Plataformas

- Ubuntu Server 22.04 LTS x86_64
- Ubuntu Server 24.04 LTS x86_64

Este repositorio no contiene imágenes, claves, tokens ni código de la aplicación. Las imágenes privadas se descargan desde GHCR únicamente con credenciales autorizadas.

## Actualizar

Para el uso habitual sólo se actualiza la aplicación:

```bash
sudo icarius update
# Central Cloud:
sudo icarius-cloud update
```

El comando también puede repetirse si ya está instalada la última versión:
verifica los servicios y recupera los que no estén activos. Actualice el
Preparer únicamente cuando soporte ICARIUS lo indique.

## Túnel SSH: identidad del servidor

No busque, cree ni cargue un archivo `known_hosts`. Complete el DNS o IP y el
puerto SSH en el Preparer y presione **Validar** o **Preparar instalación**.

El Preparer consulta automáticamente la identidad del servidor y muestra sus
huellas. Pida a TI que confirme una por otro medio y acepte solamente si es
correcta. La identidad queda guardada y se reutiliza. Si cambia el servidor o su
puerto, el Preparer obtiene una identidad nueva y vuelve a pedir confirmación.

Los comandos `sudo icarius ssh-host` y `sudo icarius-cloud ssh-host` quedan
reservados para diagnóstico y deben usarse sólo si soporte ICARIUS lo indica.

## Desinstalación segura

El instalador incorpora una vista previa y una confirmación separada:

```bash
sudo icarius uninstall --dry-run
sudo icarius uninstall --confirm
```

Para Central Cloud se usa `icarius-cloud`. El flujo retira solamente servicios
y componentes reemplazables; conserva datos de clientes, configuracion,
secretos, certificados, backups y auditoria para una reinstalación o migracion.
Nunca ejecuta una limpieza Docker global ni elimina volumenes.

## Exportar una migracion

Una instalación Ubuntu puede generar el mismo paquete cifrado que el
exportador Windows, sin detener servicios ni seleccionar carpetas a mano:

```bash
sudo icarius export-migration
# Central Cloud:
sudo icarius-cloud export-migration
```

Se generan un archivo `.icarius-migration`, su passphrase separada y una suma
SHA-256. Los tres archivos deben copiarse fuera del servidor. No se incluyen
imagenes, releases, logs, runtime ni contraseñas operativas.

Copyright Albany Technologies. Todos los derechos reservados.
