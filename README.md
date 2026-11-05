# Sistematización de Vinculación Cultural

Aplicación institucional de la Secretaría de Cultura de Guanajuato para captura, revisión e indicadores. Frontend estático en GitHub Pages; datos, autenticación y evidencias en Supabase.

## Estado actual

**Corte: 31 de octubre de 2026.** Consulta [CONTEXTO_PROYECTO.md](CONTEXTO_PROYECTO.md) para arquitectura, estado funcional, riesgos y traslado a la Lenovo, y [AGENTS.md](AGENTS.md) para instrucciones de desarrollo.

El **paquete de seguridad 01** está incluido en el commit local `edee827` y tiene pruebas previas documentadas en una base aislada. Su aplicación en Supabase y publicación efectiva no se han verificado al corte. La referencia local `origin/main` coincide con ese commit, pero no se consultó el remoto en vivo. La afirmación de datos de prueba procede del responsable según la documentación anterior; no se comprobó de nuevo.

Consulta las [instrucciones del paquete](docs/paquetes/seguridad-01/LEEME.md). No ejecutes toda la carpeta SQL: contiene migraciones históricas y parches con dependencias de orden.

## Dónde está cada cosa

| Ubicación | Contenido |
| --- | --- |
| `index.html`, `admin.html`, `inteligencia.html` | Pantallas de la aplicación |
| `establecer-acceso.html` | Activación y contraseña |
| `offline.html`, `sw.js`, `manifest.webmanifest` | Aplicación instalable y recursos sin conexión |
| `js/` | Lógica de la aplicación |
| `assets/` | Estilos, identidad, cartografía y bibliotecas |
| `plantillas/` | Plantillas de importación |
| `sql/v2/` | Historial SQL y nuevos paquetes para Supabase |
| `supabase/functions/` | Código de funciones del servidor |
| `docs/paquetes/` | Instrucciones y comprobaciones de cada actualización |
| `docs/auditoria/` | Informe y consultas de diagnóstico |
| `docs/historico/` | Documentación de etapas anteriores |
| `scripts/`, `tests/` | Herramientas y pruebas locales; no se usan al abrir el sistema |

## Publicación

GitHub Pages sirve los archivos de la aplicación desde la raíz. `_config.yml` excluye documentación, SQL, funciones del servidor y pruebas en la publicación estándar con Jekyll. Comprobar en la siguiente publicación que esa es la configuración usada; un workflow personalizado debe aplicar exclusiones equivalentes. El código del repositorio seguirá siendo visible si el repositorio es público.

Nunca añadir claves privadas a los archivos del cliente ni a Git. La configuración pública está en `js/config.js`. La seguridad de los datos depende de los permisos instalados en Supabase.

## Comprobaciones locales

Se requiere Node.js y pnpm. Ejecutar `pnpm install --frozen-lockfile` y después `pnpm test` cuando esté permitido ejecutar SQL en la base aislada. La suite aplica una migración en memoria; esta auditoría documental no la volvió a ejecutar por la restricción de no ejecutar migraciones SQL.

Las pruebas usan PostgreSQL local en memoria (PGlite) con datos ficticios; no se conectan a Supabase. Verifican autorización, migración, importación y límites configurados. No sustituyen pruebas del servicio Auth/Storage ni el recorrido de las pantallas publicadas.

Para actualizar el inventario: `node scripts/revisar-archivos.cjs`. El informe inicial permanece conservado; el inventario actual se genera en `docs/auditoria/inventario-actual.json`.

La limpieza realizada se explica en [LIMPIEZA.md](docs/LIMPIEZA.md).

Para uso local, servir la raíz mediante HTTP (no `file://`); no existe comando `pnpm dev` ni etapa de compilación. La copia local utiliza el Supabase configurado y puede escribir en él. La guía de traslado explica instalación, comprobaciones y conservación de borradores del navegador, que no viajan con Git.
