# Paquete 1: seguridad y permisos

Estado: preparado localmente; no ejecutado en Supabase ni publicado en GitHub.

## Cambios

- El cambio de nombre de usuarios requiere SUPERADMIN activo; rechaza rol ausente o nulo.
- SUPERADMIN participa en revisión, aprobación/observación, transiciones de estado y las cuatro funciones base de importación.
- Se mantienen las validaciones existentes de calidad, versión de registro, propietario de lote y alcance territorial del supervisor.
- Importación disponible en interfaz sólo a ADMIN y SUPERADMIN, en línea con la autorización del servidor. No se amplían permisos de SUPERVISOR.
- Se revocan ejecuciones innecesarias de las dos funciones de trigger; los triggers siguen funcionando.
- `evidencias-v2` continúa privado con 10 MiB (10 × 1024 × 1024 bytes) y tipos JPG, PNG, WEBP y PDF. No modifica ni elimina archivos existentes. El servicio puede aplicar límites adicionales.
- Se actualiza la versión interna y la caché para distribuir los permisos del frontend.

No cambia pantallas, datos capturados, contactos, asignaciones de usuarios, contraseñas ni la función de invitaciones. Los otros puntos de la auditoría se atenderán en entregas posteriores, incluyendo SheetJS.

## Archivo que se ejecutará

`sql/v2/13_security_package_01.sql` desde la raíz del proyecto. Es una transacción con reemplazos completos de nueve funciones, permisos mínimos y configuración del bucket. No usa sustituciones dinámicas sobre las funciones instaladas.

Antes de modificar, comprueba huellas de las definiciones contra el diagnóstico entregado. Admite también la versión ya corregida para poder repetirse. Si detecta un cambio distinto, devuelve `VERSION_DISTINTA` y detiene la transacción: no eludir ese control. No altera la propiedad de las funciones existentes.

## Orden cuando se autorice aplicar

1. Conservar el CSV de diagnóstico y disponer de un respaldo de Supabase. Los datos son de prueba, pero siguen siendo útiles para verificar los flujos.
2. Abrir una consulta nueva en SQL Editor; pegar y ejecutar **todo** `sql/v2/13_security_package_01.sql`. No seleccionar ni ejecutar partes aisladas.
3. Esperar `PAQUETE_1_APLICADO`. Si hay error, detenerse y compartirlo; si la sesión quedó en transacción fallida, ejecutar `ROLLBACK;` antes de reintentar. No publicar el frontend antes de resolver el error.
4. Ejecutar completo `02_verificar.sql` de esta carpeta. Devuelve una fila JSON con `todos_correctos: true` y el detalle de los controles. Exportar como CSV para revisar.
5. Probar con cuentas ficticias SUPERADMIN, ADMIN, SUPERVISOR, CAPTURISTA, DIRECTIVO e inactiva: cambio de nombre, observación, validación, bloqueo por expediente incompleto, importación propia y acceso fuera de alcance. Si no existe supervisor, preparar una cuenta de prueba cuando se autorice.
6. Publicar los archivos locales mediante el flujo de GitHub Pages existente; recargar y comprobar permisos visibles, formularios y que las rutas retiradas ya no se sirven. La carpeta SQL no debe publicarse como recurso del sitio.
7. Verificar una carga permitida y el rechazo directo en Storage de un tipo no permitido y de un archivo mayor al límite. No usar archivos personales para comprobarlo.

La aplicación de este paquete puede hacerse con la interfaz actual; no depende de los archivos pendientes de Vinculación.

## Comprobaciones realizadas y límites

La suite local instala las definiciones anteriores auditadas y aplica el paquete en PostgreSQL en memoria. Comprueba rechazo de usuarios sin rol activo, permisos por rol, versiones, alcance territorial, calidad, importación de lotes, duplicados, repetición de la migración y detención ante cambios de versión. El esquema de pruebas es mínimo; el núcleo de captura usado por la confirmación de lotes es un sustituto sintético. No valida todo el modelo institucional ni reproduce las APIs HTTP de Supabase.

El verificador de lectura confirma definiciones, permisos y configuración; no representa una prueba de explotación ni una prueba completa de las pantallas. Pendiente ejecutar el paquete y pruebas de integración en Supabase.

## Si aparece un problema

Antes de COMMIT, un error deja la transacción sin aplicar; ejecutar ROLLBACK si la sesión lo requiere. Si el problema aparece después del COMMIT, detener la publicación y revisar el diagnóstico y respaldo antes de una corrección dirigida. No restaurar automáticamente las funciones antiguas: reintroduciría la comprobación insegura de roles. Conservar la versión de la interfaz previa permite aislar problemas del frontend sin deshacer las correcciones de base.

`definiciones.json` documenta huellas anteriores y corregidas. `scripts/preparar-paquete-seguridad.cjs` permite reproducir los entregables desde el CSV original; no hay que ejecutarlo para instalar. `tests/fixtures/` contiene código anterior sólo como referencia para las pruebas: nunca ejecutarlo en Supabase.
