# Orden de la carpeta

Se revisaron referencias activas antes de retirar archivos. La aplicación conserva sus rutas públicas y sus recursos de identidad, cartografía, librerías y plantillas.

## Retirado

- `backup/v1/`: aplicación antigua ejecutable, duplicados de logos, manifiesto y motor offline V1. No se usa desde V2 y exponía una segunda interfaz si se publicaba la carpeta completa.
- `offline-db.js` de la raíz: motor antiguo para tablas y conexión V1; la aplicación actual guarda borradores desde `js/capture.js`.
- `manifest.json.json`: manifiesto antiguo sin referencias activas; se conserva `manifest.webmanifest`.
- `vista-previa-7-1.png`: captura de una entrega anterior, sin referencias en la aplicación.

Todos esos archivos estaban rastreados por Git y se pueden recuperar de la revisión `49daad3` si hiciera falta. No se borró el historial de Git ni se creó un commit durante esta tarea.

## Reubicado

- Informe, diagnósticos e inventario inicial: de `auditoria/` a `docs/auditoria/`.
- Herramienta de inventario: a `scripts/revisar-archivos.cjs`.
- Diagnóstico de Excel: a `docs/historico/DIAGNOSTICO_ARCHIVOS_EXCEL_ETAPA_6_4.md`.
- Instrucciones antiguas de la portada: a `docs/historico/LEEME_ETAPA_7_1.md`. Son referencia histórica; usar las instrucciones del paquete nuevo para actualizar.

## Conservado por necesidad

Las migraciones y seeds SQL no son basura: explican la evolución de la base y sus dependencias. También se conserva el blueprint como antecedente; no representa por sí solo el estado instalado. Las licencias de terceros y archivos de prueba se conservan porque respaldan la operación y verificación.

Se agregaron exclusiones para la publicación estándar de GitHub Pages y un `.gitignore` para dependencias locales, logs y archivos de entorno. El nuevo `node_modules/` contiene sólo herramientas de pruebas, no se publica ni se añade a Git.
