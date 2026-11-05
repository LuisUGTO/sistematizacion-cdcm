# Contexto del proyecto — Sistematización de Vinculación Cultural

Fecha de corte: **31 de octubre de 2026**. Repositorio: `sistematizacion-cdcm`.
Este documento es el punto de entrada para continuar el desarrollo sin depender de chats locales. Describe el código disponible, no certifica la instalación en Supabase ni el sitio publicado.

## ESTADO DEL PROYECTO AL 31 DE OCTUBRE DE 2026

Aplicación institucional estática/PWA de la Secretaría de Cultura de Guanajuato, con captura, bitácora, validación, importación de actividades, administración e inteligencia territorial implementadas en código. Backend en Supabase: PostgreSQL, Auth, Storage, RPC y una Edge Function de invitaciones.

La base de revisión es `edee827` del 20 de octubre (`update v8.1`); al iniciar la auditoría no había modificaciones de trabajo. Hay 94 commits alcanzables en las referencias locales, desde `69d2d5e` del 14 de agosto. `main` y la referencia local `origin/main` apuntan a `edee827`; no se hizo fetch ni se comprobó GitHub en vivo. El paquete de seguridad 01 ya está versionado en ese commit. Su aplicación en Supabase y su publicación efectiva siguen **no verificadas**: las instrucciones del 20 de octubre las reportaban pendientes.

Prioridades: conservar el trabajo local antes del traslado; verificar instalación real del paquete 01 y permisos por rol; atender dependencias de importación y los restantes hallazgos de seguridad; definir una instalación SQL reproducible. No declarar el sistema listo para producción sólo por disponer de este contexto.

## 1. Identificación, objetivos y alcance

El sistema organiza actividades, programas, acciones, población beneficiaria, territorio, espacios, evidencias e indicadores de Vinculación Cultural, incluyendo CDCM y bibliotecas. Busca homologar catálogos, dar trazabilidad a la captura/revisión y facilitar seguimiento, evaluación y decisiones institucionales.

El antecedente institucional más amplio contempla diagnóstico de fuentes, modelo de información, homologación, flujos de actualización y diseño funcional del Sistema de Información Cultural. Es un marco de trabajo, no evidencia de aprobación contractual ni de que todos esos entregables estén concluidos. Este repositorio tampoco es el proyecto de Planeación basado en herramientas de Google.

## 2. Arquitectura y tecnologías

- HTML, CSS y JavaScript nativo con módulos ES; parte considerable de interfaz y lógica sigue incrustada en HTML. No hay compilación de frontend ni servidor Node de aplicación.
- Cliente único en `js/supabase-client.js`, configurado por `js/config.js`; consultas habituales al esquema `v2`, helpers internos en `v2_private`. Existen dependencias heredadas de `public`, por ejemplo `cat_docentes` en `js/admin.js`; no asumir independencia completa de V1.
- Supabase: Auth para sesiones, PostgREST/RPC para datos, PostgreSQL con restricciones/triggers/RLS, Storage para archivos; Edge Function Deno/TypeScript `invite-user`.
- GitHub Pages es el alojamiento documentado. `_config.yml` excluye documentación, SQL y herramientas de la publicación estándar Jekyll; no hay workflow de Actions rastreado. Ajustes reales de Pages no inspeccionados.
- Dependencias del navegador: Supabase JS `@2`, SweetAlert2 `@11` desde jsDelivr y fuentes Google; rangos remotos sin versión exacta. D3 7.9.0 y SheetJS 0.18.5 están incluidos en `assets/vendor/`, con licencias.
- Herramienta local de pruebas: Node.js, pnpm y `@electric-sql/pglite` **0.5.10**, fijada en `package.json` y lockfile. Versiones disponibles en esta auditoría: Node 24.22.1, pnpm 11.25.0; son referencia observada, no una matriz de compatibilidad certificada. No se declara `engines` ni `packageManager`.
- `package.json` y `APP_CONFIG` indican **2.1.4**; el mensaje Git dice **v8.1** y el paquete SQL usa **2.1.13-security-01**. Son identificadores distintos; no inferir una versión desplegada unificada.

## 3. Estructura y responsabilidades

| Ruta | Responsabilidad |
| --- | --- |
| `index.html` | Inicio, acceso y módulos operativos; estilos/scripts incrustados |
| `admin.html` | Usuarios, catálogos, bibliotecas, contenido y temas |
| `inteligencia.html` | Consulta directiva y territorial |
| `establecer-acceso.html` | Activación/restablecimiento de contraseña |
| `offline.html`, `sw.js`, `manifest.webmanifest` | Shell PWA y respuesta sin conexión |
| `js/auth.js`, `permissions.js`, `set-password.js` | Sesión, perfil/alcances y permisos de interfaz |
| `js/capture.js`, `catalogs.js`, `draft-editor.js`, `evidence.js` | Captura, selección de catálogos, borradores y archivos |
| `js/bitacora.js`, `validation.js` | Consulta, trazabilidad, retiro y revisión institucional |
| `js/importer.js`, `importer-smart.js` | Lectura/clasificación Excel, lotes e incidencias |
| `js/dashboard.js`, `inteligencia.js` | Resúmenes, filtros, cartografía y calidad |
| `js/admin.js`, `catalog-admin.js`, `library-admin.js` | Administración de cuentas, alcances y catálogos |
| `js/home-content*.js`, `inteligencia-theme*.js` | Consulta y administración de portada/temas |
| `assets/` | Identidad, estilos, fotos, iconos, bibliotecas y GeoJSON municipal |
| `plantillas/` | `Plantilla_Importacion_Actividades_V2.xlsx` |
| `sql/v2/` | Esquema, catálogos, semillas, migración heredada, parches y paquete 01 |
| `supabase/functions/invite-user/index.ts` | Invitación de usuarios desde servidor |
| `scripts/` | Inventario estático y generador del paquete desde diagnóstico CSV |
| `tests/` | Suite de seguridad con fixtures mínimos y cuentas ficticias |
| `docs/` | Blueprint, auditoría, paquetes y antecedentes históricos |

El inventario completo de archivos y huellas se conserva en `docs/auditoria/inventario-actual.json`. Excluye `.git`, `node_modules` y la propia carpeta `docs/auditoria`; no es un catálogo exhaustivo de esos directorios. Los binarios se inventarían sin validar su contenido semántico.

## 4. Modelo de datos y relaciones

Modelo confirmado en archivos SQL; **no se obtuvo una exportación actual del esquema instalado**. Consultar definiciones y parches posteriores antes de cambiar columnas o RPC.

| Grupo | Tablas principales y relaciones |
| --- | --- |
| Identidad/alcance | `profiles.user_id` referencia `auth.users`; `profile_unidades` y `profile_municipios` vinculan perfiles con unidades y municipios |
| Organización | `cat_unidades_operativas`, `cat_programas`, `cat_acciones`, `cat_tipos_registro`, `configuracion_acciones`; programas/acciones pertenecen a unidades y la configuración determina requisitos operativos |
| Territorio | `cat_regiones`, `cat_municipios`, `cat_municipio_alias`, `cat_tipos_asentamiento`, `cat_comunidades`; comunidad vinculada a municipio |
| Espacios/personas | `cat_tipos_espacio`, `cat_espacios`, `biblioteca_detalle`, `cat_personas`, `cat_funciones`, `persona_funciones`; biblioteca es detalle especializado de espacio |
| Núcleo | `registros`: tipo/configuración, unidad, programa, acción, municipio/comunidad/espacio, responsable, fechas, beneficiarios, estado, origen, versión y auditoría; claves compuestas protegen coherencia de unidad y territorio |
| Detalle operativo | `registro_territorios`, `registro_personas`, `registro_poblacion`; `registro_taller` y `taller_horarios`; `registro_proyecto`, `proyecto_objetivos`, `proyecto_actividades`; `registro_reunion`, `registro_intercambio`, todos dependientes del registro |
| Demografía | `cat_dimensiones_poblacion`, `cat_opciones_poblacion`, `cat_esquemas_demograficos`, `esquema_dimensiones_poblacion`, `esquema_opciones_poblacion` |
| Evidencias/revisión | `registro_evidencias` almacena metadatos vinculados al registro y a objetos Storage; `registro_validaciones` conserva decisiones/transiciones |
| Indicadores | `cat_unidades_medida`, `cat_indicadores`, `indicadores_version`, `metas_indicador`, `accion_indicador`, `registro_indicador_aportes`: versiones, metas y aportes de registros |
| Importación/auditoría | `import_jobs` → `import_staging`; `registros.import_job_id` permite rastrear origen; `audit_log`, `folio_sequences`, `schema_migrations` |
| Contenido/usuarios | `configuracion_inicio`, `auditoria_contenido_inicio`, `temas_inteligencia`, `auditoria_temas_inteligencia`, `invitaciones_usuarios` |

`01`–`08` establecen infraestructura; `09*` incorporan semillas y demografía; `10*` migración/clasificación heredada; `11_tests.sql` contiene comprobaciones históricas; `12*` amplían flujos y corrigen incidentes; `13_security_package_01.sql` corrige nueve funciones y permisos/configuración Storage. **El orden lexicográfico no es un procedimiento de instalación**: existen dos archivos `12w` y parches dependientes de definiciones previas. Clonar no requiere ejecutar SQL.

## 5. Flujos de trabajo

1. Auth obtiene sesión; `auth.js` carga perfil activo y asignaciones. La UI habilita funciones por permisos; el servidor debe autorizar cada operación.
2. Captura selecciona unidad/programa/acción y territorio; la configuración de acción y esquema demográfico determina campos. Existe recuperación de borrador en `localStorage` por usuario; guardar en servidor usa RPC y detalle especializado.
3. Bitácora consulta `vw_registros_operativos`, permite abrir/editar según estado y permisos, y consulta trazabilidad con `rpc_get_registro_trazabilidad`.
4. Validación consulta detalle y decide mediante `rpc_get_registro_validacion` / `rpc_decide_validacion`, con control de versión y calidad. Flujo documentado: `EN_REVISION → VALIDADO/OBSERVADO → CORREGIDO → EN_REVISION`. El esquema también admite `BORRADOR`, `CAPTURADO` y `ANULADO`; no todos los cambios entre estados están permitidos.
5. Importación clasifica hojas, previsualiza/mapea, prepara trabajo, carga lotes y confirma mediante `rpc_import_preparar`, `rpc_import_cargar_lote`, `rpc_import_confirmar`; historial, duplicados, incidencias y auditoría tienen RPC específicas. No equiparar concentrados con filas de actividades.
6. Dashboard e inteligencia consumen RPC/resúmenes, con filtros por periodo, unidad, programa y municipio, modos operativo/institucional y panel de calidad. Los cálculos institucionales se mantienen en PostgreSQL.
7. Administración gestiona cuentas/alcances, catálogos, bibliotecas, portada y temas. Invitación envía correo y después configura perfil/asignaciones: no es una transacción única entre Auth y datos.

## 6. Autenticación, permisos y seguridad

Matriz de **interfaz** en `js/permissions.js`; no constituye garantía de autorización real:

| Rol activo | Comportamiento de interfaz |
| --- | --- |
| SUPERADMIN / ADMIN | Todos los permisos enumerados; ciertas acciones adicionales comprueban SUPERADMIN en servidor, como invitaciones y cambio de nombre |
| SUPERVISOR | Bitácora/dashboard por alcance, revisión y aprobación, lectura de catálogos; sin creación ni importación |
| DIRECTIVO | Consulta de bitácora/dashboard por alcance y catálogos |
| CAPTURISTA | Crear, editar propios, bitácora propia y lectura de catálogos |
| Perfil ausente/inactivo | `can()` rechaza permisos |

RLS, RPC, triggers y privilegios SQL son la barrera efectiva. No relajar las comprobaciones de propietario, unidad/municipio, versión, calidad o perfil activo para resolver un error de pantalla. El paquete 01 alinea SUPERADMIN en revisión/importación y rechaza roles nulos; su efecto en el servicio está pendiente de verificación.

Bucket de evidencias `evidencias-v2`, privado; el paquete fija **10 MiB** y JPG/PNG/WEBP/PDF. Validación MIME no prueba el contenido real. `contenido-inicio` y `temas-inteligencia` sirven recursos públicos de presentación; nunca usarlos para expedientes.

Sesión persistente en almacenamiento del navegador con clave `vinculacion-cultural-v2-auth`. Los borradores locales no tienen cifrado/vencimiento demostrado. El service worker cachea recursos del mismo origen, no las llamadas a Supabase de otro origen; eso no elimina datos guardados por la aplicación en `localStorage`.

No poner service role, contraseñas, JWT, correos de usuarios ni diagnósticos con datos personales en Git/documentación. El cliente necesita configuración pública y sus permisos deben ser mínimos. No copiar sesiones del navegador a la Lenovo.

## 7. Integraciones y configuración

| Configuración | Dónde vive / tratamiento |
| --- | --- |
| URL, `publishableKey`, `schema`, `evidenceBucket` | `APP_CONFIG.supabase` en `js/config.js`; configuración pública existente, sin reproducir valores aquí |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | Entorno de la Edge Function |
| `SUPABASE_SERVICE_ROLE_KEY` | Secreto exclusivo del servidor; nunca frontend, Git ni `.env` compartido |
| `APP_URL` | Entorno de `invite-user`; base pública para redirigir a `establecer-acceso.html` |
| URLs Auth permitidas, SMTP, exposición del esquema, permisos/buckets | Configuración del servicio, no recuperable íntegramente desde Git |

No hay cargador `.env` para el frontend ni `.env.example` rastreado; crear un `.env` no cambiará el cliente automáticamente. `.gitignore` excluye `.env` y variantes. Deno/CLI Supabase sólo son necesarios para trabajar sobre la función, no para servir HTML o ejecutar las herramientas de inventario. No se comprobó su instalación.

## 8. Estado funcional y avances confirmados

**Implementado en código:** captura y borradores, catálogos/demografía, bitácora, edición y envío, validación, evidencias, importación de actividades por lotes y seguimiento de incidencias, dashboard/inteligencia/calidad/trazabilidad, administración de usuarios/alcances/catálogos/bibliotecas y contenido, activación y PWA. Se confirma la existencia de frontend y SQL relacionados, no aceptación integral en producción.

**Parcial:** offline conserva shell/borrador local, sin motor completo de sincronización institucional; suite automatizada cubre seguridad 01 sobre esquema mínimo, sin todo el modelo ni HTTP Auth/Storage; biblioteca tiene catálogo/detalle y captura relacionada, sin demostrar cobertura de todas las estadísticas mensuales del blueprint; paquete 01 terminado como artefacto, con despliegue no confirmado.

**Planificado o pendiente de validar:** integración de concentrados mensuales, todas las familias de indicadores y archivos históricos, instalación limpia reproducible, cierre completo de la auditoría y pruebas de aceptación institucional. El diagnóstico histórico menciona diez Excel; sólo la plantilla está rastreada en `plantillas/`. No se recuperaron los diez originales ni se certificó una conciliación de sus cifras.

**No verificado:** estado actual de BD y datos reales, versión del sitio, Edge Function desplegada, SMTP, MFA, backups/restauración, configuración Pages, desempeño con volumen institucional y funcionamiento completo en navegador/Lenovo. La afirmación previa de datos de prueba procede del responsable según documentación del 20 de octubre; no se constató hoy.

## 9. Problemas conocidos y soluciones registradas

La auditoría original `docs/auditoria/INFORME_AUDITORIA_2026-10-20.md` conserva severidades y evidencias históricas. Seguimiento al corte:

| Hallazgo | Situación confirmada en repositorio |
| --- | --- |
| A01 roles nulos; A03 límites Storage; A06 SUPERADMIN | Correcciones en paquete 01 y alineación de importación en UI; pendientes de comprobar en servicio |
| A02 SheetJS | Sigue incluida 0.18.5; el informe previo registra avisos de seguridad. No se actualizaron ni revalidaron avisos externos en esta auditoría documental |
| A04 contactos globales; A05 alcances de administradores | No hay cierre documentado en paquete 01; requieren decisión de acceso y controles en servidor |
| A07 invitaciones parciales | Secuencia Auth/perfil/alcances puede quedar incompleta; resultado de insert de auditoría no se comprueba como las otras escrituras; logs incluyen correo |
| A08 objetos huérfanos | Subida de archivo y metadatos no son una sola transacción; requiere compensación/conciliación |
| A09 borradores; A10 CDN variables | Pendientes de vencimiento/protección local y fijación de dependencias |
| A11 migraciones | Sin receta de instalación completa probada; no reejecutar toda la carpeta |
| A12 pruebas | Mejorado con 14 casos de seguridad documentados; falta integración integral |
| A13 PWA | Continúan `skipWaiting`, `clients.claim` y consultas de caché con `ignoreSearch`; riesgo de mezclar versiones |
| A14 V1 publicable | Ejecutables de respaldo retirados en `edee827`; comprobar que dejaron de servirse en publicación real |
| A15 estructura | HTML grandes y reglas distribuidas; refactorización incremental pendiente |

Historial de parches conserva soluciones para folio, inserción/RLS, envío ambiguo, envío de importados, demografía importada, duplicados, espacios pendientes, permisos de invitación y visibilidad de bitácora SUPERADMIN. Son antecedentes de implementación, no constancias de ejecución. No deshacerlos ejecutando scripts base antiguos.

## 10. Decisiones técnicas y documentación vigente

- Mantener núcleo común y detalles especializados, catálogos con IDs estables y configuración institucional en BD; respetar integridad territorial y de unidad.
- Mantener cómputos institucionales en vistas/RPC, distinción entre datos operativos e institucionales y trazabilidad del origen. No sumar detalle y concentrados como si fueran equivalentes.
- Conservar SQL y documentos históricos; la limpieza de `edee827` eliminó duplicados ejecutables y reubicó documentación, según `docs/LIMPIEZA.md`. Esta auditoría no elimina archivos.
- Paquete 01 usa reemplazos completos, transacción y huellas de definiciones; ante `VERSION_DISTINTA` se detiene, sin eludir control. `tests/fixtures` nunca se instala en Supabase.
- Jerarquía práctica: este contexto para estado al corte; código para comportamiento; instrucciones del paquete para su cambio específico; informe del 20 de octubre para hallazgos originales; blueprint para intención/alcance futuro. Si discrepan con el servicio, obtener evidencia antes de modificar.

El blueprint se titula «Definitivo», pero incluye estructura recomendada, releases y siguientes pasos de etapas iniciales que ya tienen código. No tratar esas listas como backlog vigente ni como certificación de cierre. `docs/historico/LEEME_ETAPA_7_1.md` conserva una instalación por ZIP en `D:\Proyectos\sistematizacion-cdcm` y presenta el gestor de portada como futuro; ese gestor ya existe en `home-content-admin.js` y `12x_home_content.sql`. Su receta ZIP no es el procedimiento actual de traslado.

## 11. Continuar desde la Lenovo ThinkPad

Destino: **`C:\Proyectos\sistematizacion-cdcm`**. No se encontraron rutas absolutas de la ASUS en código operativo revisado; la ruta `D:\...` está en instrucciones históricas y no requiere reemplazo funcional. Scripts locales resuelven la raíz desde `__dirname`. Los inventarios son relativos.

### Antes de dejar la ASUS

1. Revisar `git status` y diferencias. Esta entrega no hace commit/push: sus documentos deben guardarse y sincronizarse por el usuario mediante GitHub Desktop antes de clonar en Lenovo. Verificar que el commit que los contiene esté en el remoto; las referencias locales no bastan.
2. Revisar borradores no enviados del navegador. Guardarlos por el flujo institucional existente antes del traslado, cuando corresponda. `localStorage`, preferencias, sesiones y cachés no viajan con Git. No eliminar el perfil antiguo hasta comprobar recuperación del trabajo.
3. Conservar fuera del repositorio, por canal seguro, originales Excel necesarios, diagnóstico CSV usado para generar paquete 01, accesos autorizados y respaldo de datos/archivos. No se encontró ese CSV original rastreado; el paquete y sus huellas sí están incluidos y no requieren regeneración.
4. Identificar cuenta con acceso a GitHub, Supabase y publicación. Git no exporta la BD, objetos Storage, secretos, Auth ni configuración del servicio.

### Preparar y ejecutar en Lenovo

1. Instalar GitHub Desktop, Git disponible en terminal, Node.js y pnpm; utilizar como referencia las versiones observadas arriba. Instalar/iniciar Codex y conceder acceso a esta carpeta con la cuenta habitual. No es necesario copiar la configuración privada de la ASUS para entender el proyecto.
2. En GitHub Desktop, clonar el repositorio existente en `C:\Proyectos\sistematizacion-cdcm`. Comprobar rama/commit y presencia de `CONTEXTO_PROYECTO.md` y `AGENTS.md`. Abrir esa carpeta como proyecto en Codex y leer ambos archivos.
3. En PowerShell:

   ```powershell
   Set-Location C:\Proyectos\sistematizacion-cdcm
   git status --short
   node --version
   pnpm --version
   pnpm install --frozen-lockfile
   node scripts/revisar-archivos.cjs
   ```

   El inventario actual se reescribe; revisar su diferencia. No copiar `node_modules` entre equipos. La instalación descarga dependencias; no ejecuta cambios en Supabase.
4. Servir la raíz por HTTP local, sin abrir `index.html` como `file://`. Si Python ya está instalado, una opción sin nuevas dependencias es `python -m http.server 8080 --bind 127.0.0.1`, y abrir `http://localhost:8080/`. Python no es dependencia obligatoria del proyecto: también sirve un servidor estático local disponible. Detener con Ctrl+C. No hay script `pnpm dev` ni `pnpm start`.
5. La copia local usa por defecto el Supabase configurado en `js/config.js`: operar captura/importación/admin puede afectar el servicio real. Primero comprobar sólo recursos y acceso; usar cuentas ficticias y entorno de pruebas para recorridos de escritura. No cambiar URL/clave ni desplegar la Edge Function por el mero cambio de computadora.
6. La suite `pnpm test` se conecta sólo a PGlite local, pero ejecuta el paquete SQL en memoria; reservarla para una sesión donde esté permitido ejecutar esas migraciones de prueba. No se ejecutó en esta auditoría por la restricción expresa de no ejecutar migraciones SQL. No requiere instalar PostgreSQL ni descargar/copiar una base real.
7. Si se necesita probar invitaciones/redirecciones locales, revisar previamente URLs permitidas en Auth y `APP_URL`; no apuntar el entorno compartido a localhost para solucionar una prueba individual. El correo y la función requieren configuración externa existente.

### Publicación y aceptación del traslado

Publicar sigue siendo una acción separada del traslado. Cuando se autorice: seguir las precondiciones de `docs/paquetes/seguridad-01/LEEME.md`, verificar backend y después interfaz. Revisar Settings de Pages (rama/carpeta y Jekyll); `_config.yml` no protege un workflow personalizado. Los nuevos Markdown de raíz podrían ser publicados por Jekyll: si se desea excluirlos, hacer un cambio operativo explícito y revisado antes de publicar. No contienen secretos; exclusión de Pages tampoco oculta archivos en un repositorio público.

El traslado se considerará comprobado cuando la Lenovo tenga el commit documental, instale el lockfile, sirva los recursos locales, permita iniciar sesión con cuenta autorizada y se haya reconciliado el trabajo del navegador anterior. **Preparación documental lista; migración efectiva y backend aún pendientes de comprobación.**

## 12. Próximas actividades recomendadas

1. Revisar/sincronizar esta documentación y realizar la comprobación de traslado anterior.
2. Obtener evidencia actual de Supabase y Pages sin modificar datos; confirmar paquete 01, buckets, permisos y versión de frontend. Conservar diagnósticos seguros fuera de Git si contienen información sensible.
3. Con autorización específica, completar el procedimiento del paquete 01 y aceptación con cuentas ficticias; no aplicar automáticamente durante la migración de equipo.
4. Planificar actualización de SheetJS y límites de procesamiento Excel con pruebas de plantilla/archivos representativos; revisar avisos oficiales al elegir versión.
5. Resolver contactos/alcances, invitaciones parciales, huérfanos y retención local; definir responsables, backups y restauración.
6. Consolidar orden reproducible de SQL y ampliar pruebas de integración/roles antes de ampliar usuarios o introducir módulos de concentrados.

## 13. Evidencia, conversaciones y límites de la auditoría

Se revisaron árbol de archivos rastreados y directorios locales, todos los documentos Markdown existentes, configuración, responsabilidades y accesos de módulos, DDL/relaciones y evolución de parches; historial local completo de mensajes de commits y diferencias de la última entrega. No se revisó línea por línea cada versión de los 94 commits ni semánticamente bibliotecas minificadas, imágenes y Excel. La verificación estática reproducible se registra en el inventario actualizado y en `docs/paquetes/seguridad-01/VALIDACION.md`.

Se consultó el listado de chats disponibles y una selección de turnos de «Secretaria de Cultura» y «Propuesta formal de servicios». En el primero, el usuario reportó que las validaciones de etapa 5 funcionaron; el siguiente alcance acordado fue dashboard/indicadores manteniendo cálculos en PostgreSQL. Es evidencia histórica declarada, no una prueba actual. El segundo aporta objetivos de sistematización y diseño funcional institucional, sin acreditar implementación ni aprobación contractual. El informe del 20 de octubre cita además «Crear propuesta de servicios PULSO Q» como antecedente recuperado entonces.

No se recuperaron todos los turnos antiguos, chats de Work/entregas ZIP, adjuntos originales, aprobaciones institucionales, resultados actuales de diagnóstico ni configuración externa. No se incorporaron datos personales o asuntos ajenos al proyecto encontrados en conversaciones. Las decisiones recuperables necesarias para continuar quedan resumidas aquí; cualquier compromiso adicional debe verificarse con su fuente.

No se modificó código funcional, configuración operativa, SQL ni servicios externos. No se ejecutaron migraciones, ni la suite que las aplica en memoria, ni commits/pushes.
