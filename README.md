# Instalador ICARIUS

Bootstrap oficial para preparar una instalación **ICARIUS On-Premise** en un VPS Ubuntu.

El instalador de soporte debe conectarse por SSH y ejecutar:

```bash
curl -fsSL https://raw.githubusercontent.com/AlbanyTechnologies/icarius-installer/main/install-onprem.sh | sudo bash
```

El asistente instala los requisitos del host y solicita únicamente la IP o DNS, el puerto temporal del configurador y las dos credenciales confidenciales entregadas por soporte ICARIUS.

## Plataformas

- Ubuntu Server 22.04 LTS x86_64
- Ubuntu Server 24.04 LTS x86_64

Este repositorio no contiene imágenes, claves, tokens ni código de la aplicación. Las imágenes privadas se descargan desde GHCR únicamente con credenciales autorizadas.

Copyright Albany Technologies. Todos los derechos reservados.