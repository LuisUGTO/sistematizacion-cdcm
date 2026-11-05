# Instrucciones para trabajar en este repositorio

- Leer `CONTEXTO_PROYECTO.md` antes de modificaciones importantes y revisar documentación del módulo/paquete afectado. El blueprint y los documentos históricos describen también planes: contrastarlos con código y evidencia del servicio.
- Respetar frontend estático con módulos ES, cliente único Supabase, esquema `v2`, helpers `v2_private`, catálogos/configuración y núcleo común con módulos especializados. Conservar contratos RPC, rutas y compatibilidad de funciones actuales.
- Evitar cambios innecesarios, reescrituras amplias y duplicados documentales. No actualizar dependencias sin verificar versión fijada, procedencia, licencias, compatibilidad y efecto en importaciones/PWA.
- Priorizar seguridad, integridad de datos y mantenibilidad: preservar RLS, perfil activo, alcances, propietario, control de versión, reglas demográficas y calidad. La UI no sustituye autorización del servidor. No mezclar concentrados con detalle operativo.
- No exponer credenciales, tokens, claves privadas, claves service role, sesiones ni datos personales en código, documentación, logs o Git. La configuración pública del cliente no autoriza eludir permisos.
- Antes de pruebas con interfaz local, recordar que `js/config.js` puede apuntar al servicio compartido. Utilizar entorno y cuentas de prueba para escrituras; no alterar servicios externos sin autorización.
- Solicitar confirmación antes de migraciones destructivas o cambios irreversibles. No ejecutar toda `sql/v2` ni deducir orden por nombre. Respetar precondiciones/huellas del paquete; detenerse ante `VERSION_DISTINTA`.
- Nunca instalar `tests/fixtures` en Supabase. `pnpm test` ejecuta SQL/migración en PGlite aislado: si la tarea prohíbe ejecutar migraciones SQL, limitarse a controles estáticos y declarar la prueba omitida.
- Validar de acuerdo con el cambio: inventario estático (`node scripts/revisar-archivos.cjs`, reescribe inventario), suite existente cuando proceda y pruebas de integración autorizadas si se afectan contratos/seguridad. No confundir sintaxis o fixtures mínimos con aceptación en producción.
- Documentar cambios relevantes, pendientes y límites en el contexto y documentación existente. Distinguir implementado en código, parcial, planificado y no verificado; no declarar desplegado sin evidencia.
- Conservar historial y decisiones. No eliminar archivos ni realizar commits/pushes por iniciativa propia; seguir el alcance autorizado de cada tarea. El traslado de equipo no requiere reejecutar SQL ni desplegar funciones.
