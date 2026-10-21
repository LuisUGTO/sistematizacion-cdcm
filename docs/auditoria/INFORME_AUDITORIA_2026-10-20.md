# Auditoría técnica de Vinculación Cultural

Fecha: 20 de octubre de 2026. Revisión local: commit `49daad3` (update 7.7.9D).

## Dictamen

El proyecto tiene un modelo institucional aprovechable, pero su ampliación requiere primero estabilizar autorización, dependencias y despliegues. El riesgo técnico observado es ALTO. No hay evidencia de intrusión ni se afirma una exposición efectiva de producción. No aconsejo aprobar una ampliación de usuarios o una reestructura masiva sin cerrar los hallazgos altos y verificar la configuración desplegada.

La aplicación es una web estática/PWA con JavaScript modular, HTML con estilos y lógica incrustados, PostgreSQL/Supabase (Auth, RLS, Storage y RPC) y una función de invitaciones. El núcleo común de registros, catálogos y módulos especializados es una base razonable para evolucionar; los problemas encontrados no justifican por sí solos desecharlo.

## Alcance y límites

Se inventariaron los 123 archivos de trabajo, excluyendo los objetos internos de Git y los entregables de esta auditoría: 109 archivos de texto y 14 binarios; incluyen 57 SQL y 28 JavaScript. Se leyeron mediante herramientas todos los textos para inventario y análisis estático; la revisión manual se concentró en rutas de mayor riesgo. No equivale a revisión humana exhaustiva de cada línea, especialmente de bibliotecas minificadas. Los binarios (imágenes y plantilla Excel) se inventariaron con huella SHA-256; no se validaron visualmente ni se auditaron sus datos internos. No se auditó el historial completo de Git.

Se comprobó sintaxis de los 28 JavaScript y de los scripts incrustados en HTML, estructura JSON y referencias locales estáticas. Estos controles no prueban la corrección funcional. TypeScript/Deno y SQL no se ejecutaron. No se contó con sesión de producción, exportación del esquema instalado, logs, configuración Auth, cabeceras del servidor, copias de seguridad ni datos reales. No se realizaron ataques contra el servicio publicado ni modificaciones al sistema. Sólo se añadieron estos entregables.

Las rutas y líneas siguientes corresponden a esta copia. «Confirmado en código» significa que existe el defecto o configuración local; la explotación efectiva depende del estado desplegado y se debe verificar en pruebas.

## Hallazgos priorizados

### A01 — ALTO: comprobación de SUPERADMIN admite rol nulo

**Evidencia:** `sql/v2/12ah_superadmin_nombre_usuarios.sql:35-40,51-57,67-70`; `sql/v2/06_rls.sql:110-123`.

`current_role()` sólo devuelve perfiles activos. La RPC de cambio de nombre verifica `current_role() <> 'SUPERADMIN'`; si el perfil está inactivo o falta, el resultado es NULL y el IF no rechaza. A la vez, la función requiere sólo `auth.uid()` no nulo, se concede a authenticated y es SECURITY DEFINER. Un JWT aún válido de una cuenta desactivada puede alcanzar el UPDATE de nombres de otros perfiles y su devolución de correo, nombre e identificador, sujeto a privilegios y triggers desplegados. No implica promoción de rol ni toma de cuentas.

**Corrección:** comparación `IS DISTINCT FROM 'SUPERADMIN'`, comprobación explícita de usuario activo y revisión de todos los guardas que usan `<>`/`NOT IN`. No todos los otros usos son explotables: varios tienen helpers posteriores que rechazan correctamente.

**Aceptación:** probar sin sesión, perfil ausente, perfil inactivo y cada rol; sólo SUPERADMIN activo debe poder modificar nombres. Ejecutar en una base de pruebas con usuarios ficticios.

### A02 — ALTO: SheetJS 0.18.5 en importación de archivos

**Evidencia:** `assets/vendor/xlsx.full.min.js` declara versión 0.18.5; `index.html:28`; `js/importer.js`, funciones `readFile` y `updateSheet`.

La versión incluida está afectada por CVE-2023-30533 (contaminación de prototipos al leer archivos manipulados) y CVE-2024-22363 (denegación de servicio por expresiones regulares). La aplicación sí lee archivos seleccionados por usuarios. No se ejecutó una prueba maliciosa. El impacto esperable inmediato incluye bloqueo del navegador; el aviso de contaminación de prototipos por sí solo no demuestra ejecución de código en este sistema.

**Corrección:** sustituir por una distribución oficial mantenida que corrija ambos avisos, como mínimo 0.20.2 para esos dos defectos, y comprobar avisos adicionales de la versión elegida. Documentar procedencia, versión y hash. El límite de 20 MB comprimidos no limita el tamaño descomprimido; añadir límites de filas/celdas, tiempo de análisis y procesamiento en un Worker cancelable.

**Aceptación:** importar plantilla y ejemplos representativos; comprobar rechazo de entradas excesivas y cancelación sin bloquear la interfaz.

Fuentes primarias: [aviso SheetJS CVE-2023-30533](https://cdn.sheetjs.com/advisories/CVE-2023-30533), [aviso SheetJS CVE-2024-22363](https://cdn.sheetjs.com/advisories/CVE-2024-22363).

### A03 — ALTO: límites de evidencia aplicados sólo en el cliente

**Evidencia:** `js/evidence.js:18-26,53-85`; `sql/v2/07_storage.sql:79-101,391-400`. El SQL declara expresamente que no impone tamaño ni MIME en el bucket de evidencias. Las policies autorizan escritura por registro, sin reproducir esas restricciones.

Una cuenta con permiso de edición puede eludir los 10 MB y tipos permitidos del formulario llamando directamente a Storage, dentro de los límites globales del servicio. Esto permite uso indebido del almacenamiento y archivos distintos de los esperados. Los buckets públicos de portada y temas sí tienen restricciones y no deben confundirse con evidencias.

**Corrección:** configurar `file_size_limit` y `allowed_mime_types` en `evidencias-v2`; validar contenido real cuando el riesgo lo requiera y establecer cuotas. MIME declarado no certifica el contenido.

**Aceptación:** comprobar límites consultando el bucket desplegado y rechazando cargas directas no permitidas con cuenta de prueba.

### A04 — ALTO: catálogos de personas legibles globalmente por usuarios activos

**Evidencia:** `sql/v2/02_catalogs.sql:446-468` (nombre, correo y teléfono); `sql/v2/06_rls.sql:890-943` incluye `cat_personas` en SELECT de catálogos activos para todo usuario activo.

La política no filtra por municipio ni unidad y SELECT se concede sobre la tabla. Una cuenta activa puede consultar los contactos de personas activas de otros ámbitos. La interfaz no necesita mostrar esos campos para que sean consultables. Es un control más amplio que el alcance territorial del resto de la operación; su legitimidad institucional necesita una decisión explícita.

**Corrección:** separar directorio operativo de datos de contacto; restringir columnas y/o filas según la necesidad del rol. Definir quién debe consultar contactos globales.

**Aceptación:** un capturista sólo obtiene contactos autorizados; un directorio global, si se aprueba, expone únicamente sus campos mínimos.

### A05 — MEDIO: protección de administradores no cubre sus tablas de alcance

**Evidencia:** `sql/v2/12w_superadmin_invitations.sql:41-61` protege cambios en `profiles`; `sql/v2/06_rls.sql:982-1010` permite a ADMIN insertar/actualizar asignaciones en `profile_unidades` y `profile_municipios` sin restringir el usuario objetivo.

Un ADMIN puede cambiar directamente asignaciones de otro ADMIN o SUPERADMIN aunque el panel limite la gestión de administradores. Hoy su acceso global depende del rol, por lo que esto no constituye una escalada inmediata de privilegios; sí rompe la protección anunciada sobre su configuración y puede tener efectos en cambios futuros de rol.

**Corrección:** establecer controles equivalentes sobre las tablas de alcance o revocar escrituras directas y canalizarlas por una RPC que compruebe también el rol objetivo.

**Aceptación:** ADMIN no modifica configuraciones protegidas ni por formulario ni por llamadas directas.

### A06 — ALTO funcional: SUPERADMIN ofrecido por interfaz y rechazado por validación/importación

**Evidencia:** `js/permissions.js:44-47` concede todos los permisos; `sql/v2/12f_validation_workflow.sql:175,499` acepta sólo ADMIN/SUPERVISOR; `sql/v2/12j_bulk_excel_import.sql` exige `p.rol = 'ADMIN'` en operaciones e historial. `12aa_hotfix_superadmin_capture.sql` modifica creación y cinco helpers, no esas comprobaciones. El trigger `authorize_status_transition` de `06_rls.sql:631-687` tampoco reconoce SUPERADMIN.

Con las definiciones locales, una cuenta con el rol más alto encuentra funciones visibles que no puede ejecutar. Esto puede bloquear la validación institucional; no es una vulnerabilidad de acceso excesivo. Algunos procesos de lotes usan `is_admin()` y sí admiten SUPERADMIN, aumentando la inconsistencia.

**Corrección:** matriz única de permisos y reemplazo explícito de las funciones afectadas, incluyendo triggers. Decidir si SUPERVISOR realmente puede importar: la interfaz lo permite y el flujo masivo SQL revisado lo restringe a ADMIN.

**Aceptación:** matriz de pruebas por rol y operación, con evidencia de creación, edición, envío, observación, aprobación e importación.

### A07 — ALTO operativo: invitaciones con estados parciales y auditoría sin comprobar

**Evidencia:** `supabase/functions/invite-user/index.ts:66-107`. Primero se envía invitación, después se escribe perfil, unidades, municipios y auditoría en solicitudes separadas. El `await` final no inspecciona el campo `error` devuelto por el cliente de Supabase. `within` usa Promise.race y no cancela la operación que vence por tiempo.

Puede enviarse correo y quedar la configuración incompleta, incluso con acceso parcial (sólo una dimensión de alcance asignada). Un error de auditoría puede devolver éxito al usuario. Tras un timeout, una escritura puede concluir después del mensaje de fallo, complicando los reintentos.

**Corrección:** validar todos los identificadores antes de invitar, flujo persistente e idempotente, perfil pendiente/inactivo hasta completar configuración, transacción para las asignaciones, comprobación de errores y reconciliación. La invitación por correo y la base no pueden hacerse una sola transacción sin diseñar ese flujo.

**Aceptación:** simular fallo en cada paso y reintento; no quedan accesos activos incompletos ni correos duplicados por reintentos del sistema; toda invitación tiene estado trazable.

### A08 — MEDIO: archivos huérfanos al fallar metadatos

**Evidencia:** `js/evidence.js:108-164`. La subida precede al INSERT de `registro_evidencias`; ante fallo de metadatos se lanza una excepción y no se compensa la carga.

Quedan archivos sin vínculo formal de evidencia, aunque bajo una ruta de registro válida. Retirar metadatos con `activo=false` tampoco elimina físicamente el objeto ni cambia por sí solo las policies de lectura, que dependen del registro.

**Corrección:** flujo pendiente/confirmado, reintentos seguros y tarea de reconciliación; definir si «desactivar evidencia» debe impedir también abrir su ruta y cómo tratar enlaces firmados aún vigentes.

**Aceptación:** fallo inducido entre carga e INSERT no deja objetos sin gestionar; política de retención y eliminación verificable.

### A09 — MEDIO: borradores locales sin vencimiento y mensaje de protección inexacto

**Evidencia:** `js/capture.js:833-887,924-957`; `js/auth.js`, `signOut`. El borrador se guarda automáticamente en localStorage, separado por usuario, pero no hay caducidad ni limpieza en el cierre de sesión. Si falla el guardado local, sólo aparece un aviso en consola; `protectDraftWhileOffline` puede seguir afirmando que quedó protegido.

Un equipo compartido conserva descripciones y datos del formulario; la separación de claves por usuario ayuda, pero no equivale a cifrado ni control de acceso del dispositivo. Si falta espacio, el mensaje puede inducir a cerrar la página y perder trabajo.

**Corrección:** retornar resultado real del guardado, informar fallos, retención explícita y opción de limpiar este dispositivo; acordar qué contenido puede persistir localmente. No borrar automáticamente trabajo pendiente sin aviso.

**Aceptación:** probar almacenamiento bloqueado/lleno, restauración por usuario, cierre de sesión y caducidad.

### A10 — MEDIO: dependencias remotas variables en pantallas sensibles

**Evidencia:** `index.html:25-26`, `admin.html:13-14`, `establecer-acceso.html:12-13`; import remoto de la función de invitaciones. Se usan rangos mayores como `@2` y `@11` sin integridad en HTML.

El código de autenticación depende de lo que el proveedor entregue en cada carga. No se observó una CSP en HTML ni configuración de cabeceras en el repositorio; eso no demuestra que el servidor publicado carezca de ella.

**Corrección:** versiones exactas y dependencias reproducibles, integridad o distribución local controlada; comprobar cabeceras reales y desplegar CSP compatible con el código existente. La clave publishable del cliente es pública por diseño: no es una filtración de un secreto.

**Aceptación:** una instalación limpia reproduce las mismas dependencias; CSP y cabeceras verificadas en el alojamiento; funcionamiento ante fallo de CDN documentado.

### A11 — MEDIO: migraciones sin orden de instalación reproducible

**Evidencia:** 57 SQL; nombres `12a...12z` y `12aa...12ah`; dos archivos `12w`; parches que reescriben definiciones usando expresiones regulares en `12aa_hotfix_superadmin_capture.sql`; historial `schema_migrations` con inserciones `ON CONFLICT DO NOTHING`.

Ordenar alfabéticamente no produce necesariamente el orden histórico correcto. Registrar una versión no demuestra que el SQL desplegado sea idéntico al archivo. El repositorio carece de un ejecutor y manifiesto completo de dependencias de instalación; `LEEME_PRIMERO.md` describe una etapa anterior.

**Corrección:** congelar y documentar una secuencia comprobada, adoptar migraciones numeradas únicas e inmutables con checksum y reemplazos completos de funciones, y generar un esquema de referencia. No reaplicar toda la carpeta sobre producción.

**Aceptación:** construir una base vacía y actualizar una copia de la versión actual de forma repetible, con comparación del esquema final.

### A12 — MEDIO: falta de pruebas ejecutables de permisos y operación actual

**Evidencia:** existe `sql/v2/11_tests.sql` con 1,925 líneas de verificaciones de estructura, datos y migración V2.1. No se encontró configuración de CI, gestor de dependencias ni una batería automatizada de navegador o pruebas de autorización con sesiones por rol. El archivo de pruebas no incorpora como requisito toda la serie posterior `12...`.

No equivale a «no existen pruebas»: las consultas existentes aportan valor, pero no demuestran el comportamiento de las cuentas ante llamadas directas ni cubren todos los parches.

**Corrección:** pruebas mínimas por rol, territorio, usuario inactivo, concurrencia, reintentos y operaciones parciales; ejecutar en entorno de pruebas antes de publicar.

**Aceptación:** un cambio que abra acceso entre municipios o rompa SUPERADMIN falla automáticamente antes del despliegue.

### A13 — MEDIO: actualización PWA puede combinar versiones

**Evidencia:** `sw.js:26-42,44-50,74-101`. `skipWaiting` y `clients.claim` activan inmediatamente; caché ignora query de versión; HTML y recursos usan estrategias diferentes. Una página antigua puede recibir módulos nuevos; el shell tampoco contiene todas las dependencias externas necesarias para iniciar sin red.

**Corrección:** publicación atómica de recursos con hash, aviso de actualización cuando sea seguro y contrato explícito del modo sin conexión. El código actual sí evita cachear llamadas a Supabase por su origen distinto.

**Aceptación:** probar actualización con formulario abierto, dos pestañas y pérdida de red; no perder ni reinterpretar una captura.

### A14 — MEDIO condicionado: V1 ejecutable dentro del árbol publicable

**Evidencia:** `backup/v1/index.html`, `admin.html`, `offline-db.js` y `sw.js` conservan código de otra versión y referencia al mismo proyecto Supabase. La página V1 interpola datos en `innerHTML` sin escape en varios puntos; falta su `manifest.json` referenciado.

Si el alojamiento publica el árbol completo, esas páginas pueden visitarse directamente. Su seguridad depende además de permisos y policies V1, expresamente fuera del alcance de las migraciones V2. Tener una copia V1 no demuestra exposición de datos actual.

**Corrección:** excluir respaldos del artefacto público y revisar el retiro efectivo de permisos/endpoints V1; conservarlos en almacenamiento de respaldo controlado.

**Aceptación:** las rutas V1 no son accesibles en producción y su API no acepta accesos retirados.

### A15 — MEDIO: deuda estructural y reglas institucionales repartidas

**Evidencia:** `index.html` 7,950 líneas; formularios de captura y edición de más de 1,600 líneas cada uno; configuraciones `2.1.3`, `7.2.3` y etapas `7.7.9D` en distintos lugares; reglas y candidatos de clasificación en `js/importer-smart.js` y `js/importer.js`; blueprint y LEEME con estados distintos del código.

No es un defecto de seguridad por sí solo. Eleva el costo y riesgo de cambios de estructura, ejercicios fiscales y nuevas áreas. La clasificación automática necesita trazabilidad de cómo se interpretó el Excel; una importación técnicamente exitosa no garantiza indicadores institucionales correctos.

**Corrección:** separar presentación, lógica de dominio y acceso a datos; registrar versión del clasificador, revisar mapeos con el área y mantener un diccionario institucional de variables y fórmulas. Distinguir personas únicas, participaciones, accesos y beneficiarios: sumarlos sin reglas puede producir dobles conteos. Esto es un riesgo semántico a validar, no un error cuantificado con datos reales.

**Aceptación:** ejemplos aprobados por Vinculación permiten reproducir los totales y explicar cada cifra hasta sus registros fuente.

## Controles que conviene conservar

- Permisos en base de datos mediante RLS, además de ocultar botones.
- Vistas `security_invoker` y numerosos helpers con `search_path` vacío.
- Evidencias privadas con enlaces temporales y comprobación de registro/unidad.
- Captura integral transaccional en el servidor; no confundirla con la invitación y la carga de archivos, que sí tienen pasos separados.
- Catálogos normalizados, borradores, historial de validación, auditoría y controles de versión en flujos de edición.
- Separación entre cifras operativas y oficiales en inteligencia; falta validarla con criterios institucionales y datos de referencia.
- Clave pública Supabase identificada como publishable; no se detectó una clave `service_role` privada en el código actual revisado. Esto no certifica el historial Git ni el alojamiento.

## Ruta de mejora propuesta

1. **Antes de ampliar el uso:** verificar definiciones instaladas; corregir A01; actualizar SheetJS; restringir evidencias; resolver SUPERADMIN y revisar acceso a contactos. Responsables: desarrollo, administrador Supabase y dueño de la información.
2. **Estabilizar operación:** invitaciones pendientes/idempotentes, auditoría comprobada, reconciliación de evidencias, borradores fiables, despliegues reproducibles y pruebas por rol. Medir éxito por pruebas aprobadas, no por número de parches.
3. **Preparar la reestructura:** levantar procesos reales con Vinculación, mapa de fuentes y responsables, diccionario de datos, matriz de acceso y criterios oficiales de validación. Definir qué requiere otra área de la Secretaría y qué es exclusivo de Vinculación.
4. **Evolucionar por módulos:** preservar identificadores y datos históricos, crear contratos de datos versionados y migrar progresivamente cada flujo. No cambiar simultáneamente permisos, indicadores, modelo y pantallas sin una reconciliación verificable.

Arquitectura sugerida: núcleo institucional (identidad, territorio, periodos, programas, acciones), módulos operativos por área, flujo de validación centralizado y capa de indicadores con definiciones versionadas. Supabase puede seguir siendo adecuado; no hay evidencia que obligue a cambiar de plataforma o introducir microservicios.

## Evidencia pendiente para cerrar la auditoría

- Resultados de `comprobaciones-supabase.sql` y versión de PostgreSQL; comparar definiciones reales con archivos. El script es de lectura y no extrae registros personales.
- URL y configuración del alojamiento para rutas públicas, HTTPS, cabeceras y publicación de respaldos.
- Configuración Auth: registro de usuarios, redirecciones permitidas, MFA administrativo, vigencia de sesiones y medidas de acceso. Su ausencia en el repositorio no prueba que estén deshabilitadas.
- Cuenta ficticia por rol y una instancia de pruebas con datos anonimizados; casos de acceso cruzado entre territorios.
- Evidencia de restauración de respaldos de BD y archivos, responsables, retención y objetivos de recuperación. No se puede inferir la existencia o ausencia de respaldos del servicio sólo por este repositorio.
- Volumen y crecimiento de registros para medir rendimiento; políticas de conservación y eliminación de datos personales aprobadas por la institución.
- Criterios de indicadores y ejemplos reconciliados por el área. No se emite opinión jurídica de cumplimiento ni certificación formal de seguridad.

## Contexto de chats recuperado

Se encontró y leyó el chat «Crear propuesta de servicios PULSO Q», vinculado a «Propuesta formal de servicios». El antecedente abarca diagnóstico, homologación, modelo institucional y diseño funcional para la Secretaría de Cultura. Es consistente con una futura ampliación, pero no constituye una especificación aprobada del código actual. No se afirma haber recuperado todo el historial ni todas las conversaciones anteriores del proyecto.

## Entregables y reproducción

- `inventario.json`: archivo, tamaño, hash SHA-256, alcance de revisión y resultados estáticos.
- `revisar-archivos.cjs`: genera el inventario; ejecutar con `node auditoria/revisar-archivos.cjs` desde el proyecto. No instala dependencias ni contacta servicios.
- `comprobaciones-supabase.sql`: comprobación complementaria de lectura; no ejecutada durante esta revisión.

Las verificaciones locales aprobaron sintaxis JavaScript y JSON. Las referencias ausentes quedaron limitadas al manifiesto V1. No se hicieron pruebas de explotación, de integración, de carga ni de restauración. Pasar sintaxis no elimina los hallazgos anteriores.

Referencias técnicas: [PostgreSQL: condiciones IF y NULL](https://www.postgresql.org/docs/14/plpgsql-control-structures.html), [Supabase: RLS](https://supabase.com/docs/guides/database/postgres/row-level-security), [Supabase: claves públicas y secretas](https://supabase.com/docs/guides/api/api-keys).
