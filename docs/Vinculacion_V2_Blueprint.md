# VINCULACIÓN CULTURAL 2.0
## Blueprint Técnico Definitivo — Secretaría de Cultura de Guanajuato

**Versión:** 2.0  
**Estado:** Arquitectura aprobada para construcción  
**Documento rector:** Sí  
**Código ejecutable:** No  
**Ubicación recomendada:** `/docs/Vinculacion_V2_Blueprint.md`

---

# 1. PROPÓSITO

Vinculación Cultural 2.0 será una plataforma institucional única para captura, normalización, seguimiento, validación, consolidación e indicadores de las distintas unidades operativas de Vinculación Cultural.

La plataforma sustituirá gradualmente procesos dispersos en archivos Excel y evitará que cada municipio, biblioteca, casa de cultura u otra unidad capture la misma información con criterios distintos.

El principio central será:

> **Una sola plataforma institucional, múltiples flujos operativos, un único modelo normalizado de información.**

No se construirá un formulario idéntico para todos. Se utilizará un **núcleo común** y módulos especializados configurados mediante catálogos.

---

# 2. OBJETIVOS DE V2

1. Unificar la operación de CDCM, Bibliotecas y futuras unidades.
2. Normalizar municipios, comunidades, espacios, personas y clasificaciones.
3. Eliminar la dependencia de archivos y catálogos escritos dentro del HTML.
4. Permitir que personal no programador administre catálogos.
5. Permitir cargas masivas mediante Excel con plantilla, prevalidación y reporte de errores.
6. Relacionar cada captura con acciones, indicadores y metas institucionales.
7. Generar concentrados automáticamente desde los registros operativos.
8. Mantener evidencias privadas y trazables.
9. Tener validación institucional y observaciones.
10. Tener auditoría de cambios.
11. Evitar duplicados de sincronización e importación.
12. Soportar trabajo offline.
13. Permitir evolución anual de indicadores sin reconstruir la plataforma.
14. Preparar el sistema para integrar posteriormente Museos, Teatros u otras unidades sin rediseñar la base.

---

# 3. PRINCIPIOS DE ARQUITECTURA

## 3.1 Catálogo antes que texto libre

Cuando un valor pueda normalizarse mediante catálogo, el usuario no deberá escribirlo manualmente.

Ejemplos:

- Municipio
- Comunidad
- Unidad operativa
- Tipo de espacio
- Espacio cultural
- Acción institucional
- Tipo de registro
- Persona responsable
- Indicador
- Unidad de medida

El texto libre quedará para:

- Nombre o descripción de actividad/proyecto
- Objetivos
- Justificación
- Resultados
- Observaciones
- Acuerdos
- Narrativas técnicas

---

## 3.2 IDs estables en la base

La aplicación mostrará nombres, pero las relaciones se guardarán mediante IDs.

Ejemplo:

```text
Pantalla:
Municipio = "Santiago Maravatío"

Base:
municipio_id = <UUID/ID>
```

Esto impedirá variaciones como:

- Santiago Maravatío
- Stgo Mtío
- Santiago Maravatio

---

## 3.3 Núcleo común + módulos especializados

Todos los registros comparten información institucional.

Después, cada tipo de operación agrega sus campos propios.

Ejemplo:

```text
REGISTRO BASE
├── Unidad operativa
├── Acción
├── Tipo de registro
├── Territorio
├── Espacio
├── Periodo
├── Usuario
├── Estatus
└── Evidencia
```

y posteriormente:

```text
TALLER
├── Disciplina
├── Docente
├── Programación
├── Días
└── Horario
```

o:

```text
PROYECTO SOCIOCULTURAL
├── Justificación
├── Objetivo general
├── Objetivos específicos
├── Cronograma
└── Resultados
```

---

## 3.4 Configuración en base de datos, no en HTML

El HTML no deberá contener listas institucionales extensas.

La base definirá:

- Unidades operativas
- Programas
- Acciones
- Tipos de registro
- Reglas de captura
- Indicadores
- Metas
- Catálogos territoriales
- Personas
- Espacios

El frontend solamente consume esa configuración.

---

# 4. ARQUITECTURA GENERAL

```text
USUARIO
  │
  ▼
PWA VINCULACIÓN 2.0
  │
  ├── Captura
  ├── Bitácora
  ├── Dashboard
  ├── Administración
  └── Offline
  │
  ▼
SUPABASE
  │
  ├── Auth
  ├── PostgreSQL
  ├── RLS
  ├── Storage privado
  ├── Views / RPC
  ├── Auditoría
  └── Triggers
```

Offline:

```text
Formulario
   ↓
IndexedDB
   ↓
UUID local estable
   ↓
Sincronización
   ↓
PostgreSQL
   ↓
Folio institucional definitivo
```

---

# 5. ESTRUCTURA ORGANIZACIONAL

## 5.1 Unidad operativa

Término técnico provisional para diferenciar los grandes ámbitos de operación.

Ejemplos iniciales:

- CDCM
- Bibliotecas

Futuros:

- Museos
- Teatros
- Patrimonio
- Otras áreas que determine la Secretaría

Tabla:

```text
cat_unidades_operativas
```

Campos conceptuales:

```text
id
clave
nombre
descripcion
activo
created_at
updated_at
```

---

## 5.2 Programas

Una unidad operativa puede contener uno o varios programas.

```text
cat_programas
```

Relación:

```text
unidad_operativa 1 ─── N programas
```

---

## 5.3 Acciones institucionales

La acción será una de las selecciones más importantes del sistema.

```text
cat_acciones
```

Ejemplos:

- Taller en Casa de Cultura
- Curso de verano
- Capacitación
- Reunión de colaboración
- Intercambio cultural
- Proyecto sociocultural
- Proyecto de circuito
- Proyecto regional
- Evento municipal
- Estadística mensual de biblioteca

La acción determinará automáticamente:

- Unidad operativa
- Programa
- Tipo de registro
- Formulario
- Indicador relacionado
- Unidad de medida
- Reglas de evidencia
- Reglas de población
- GPS
- Validación

---

# 6. TERRITORIO

## 6.1 Municipios

```text
cat_municipios
```

Campos conceptuales:

```text
id
clave_inegi
nombre_oficial
region_id
activo
created_at
updated_at
```

La V2 deberá cargar los 46 municipios oficiales.

Los usuarios no escribirán municipios manualmente.

---

## 6.2 Alias de municipios

Para importación de históricos:

```text
cat_municipio_alias
```

Ejemplo:

```text
alias                 municipio_oficial
------------------------------------------------
Stgo Mtío             Santiago Maravatío
Cueramaro             Cuerámaro
```

Los alias no se mostrarán en captura normal.

Se utilizarán en importaciones y migración.

---

## 6.3 Comunidades / localidades

```text
cat_comunidades
```

Relación:

```text
municipio 1 ─── N comunidades
```

Campos:

```text
id
municipio_id
clave
nombre
tipo_asentamiento_id
activo
created_at
updated_at
```

El catálogo podrá administrarse manualmente o importarse mediante Excel.

---

## 6.4 Regiones

```text
cat_regiones
```

Permitirá análisis territorial y metas regionales cuando corresponda.

---

# 7. ESPACIOS CULTURALES

## 7.1 Tipos de espacio

```text
cat_tipos_espacio
```

Ejemplos:

- Biblioteca
- Casa de Cultura
- Teatro
- Museo
- Centro Cultural
- Sala
- Espacio comunitario
- Otro

---

## 7.2 Espacios concretos

```text
cat_espacios
```

Ejemplo:

```text
Tipo: Biblioteca
Nombre: Biblioteca X
Municipio: Abasolo
Comunidad: Cabecera
```

Campos conceptuales:

```text
id
tipo_espacio_id
unidad_operativa_id
municipio_id
comunidad_id
nombre
direccion
latitud
longitud
activo
created_at
updated_at
```

---

## 7.3 Datos especializados de biblioteca

Una biblioteca será un espacio cultural con información adicional.

```text
biblioteca_detalle
```

Ejemplos de campos:

```text
espacio_id
numero_dgb
responsable_id
telefono
correo
horario
datos_extra_controlados
```

Esto evita duplicar municipio/nombre/sede en varias tablas.

---

# 8. PERSONAS Y RESPONSABLES

En lugar de mantener listas independientes sin relación, V2 utilizará:

```text
cat_personas
```

Campos:

```text
id
nombre
correo
telefono
activo
created_at
updated_at
```

y:

```text
persona_funciones
```

Funciones posibles:

- DOCENTE
- TALLERISTA
- BIBLIOTECARIO
- ENLACE_MUNICIPAL
- RESPONSABLE
- OTRO

Una misma persona podrá tener más de una función.

---

# 9. TIPOS DE REGISTRO

```text
cat_tipos_registro
```

Tipos iniciales previstos:

```text
TALLER
CURSO_VERANO
CAPACITACION
REUNION
INTERCAMBIO
PROYECTO_SOCIOCULTURAL
PROYECTO_CIRCUITO
PROYECTO_REGIONAL
EVENTO
EXPOSICION
ESTADISTICA_BIBLIOTECA
OTRO
```

No significa necesariamente una tabla por cada tipo.

El tipo define qué plantilla funcional utilizará la aplicación.

---

# 10. MATRIZ DE CONFIGURACIÓN

Pieza central de Vinculación 2.0.

```text
configuracion_acciones
```

Cada acción definirá:

```text
accion_id
tipo_registro_id
tipo_formulario
requiere_municipio
requiere_comunidad
requiere_espacio
requiere_responsable
requiere_beneficiarios
requiere_demografia
requiere_gps
requiere_evidencia
requiere_validacion
activo
vigente_desde
vigente_hasta
```

Ejemplo:

```text
Acción:
Proyecto Sociocultural

Formulario:
PROYECTO_SOCIOCULTURAL

Requiere:
Municipio      Sí
Comunidad      Sí
Espacio        Opcional
Beneficiarios  Sí
GPS            Sí
Evidencia      Sí
Validación     Sí
```

La administración podrá cambiar catálogos y asociaciones sin modificar HTML.

La creación de un **tipo de formulario completamente nuevo** sí será una tarea de desarrollo controlado.

---

# 11. NÚCLEO OPERATIVO

La tabla principal será:

```text
registros
```

No utilizará el antiguo folio aleatorio como clave primaria.

Campos conceptuales:

```text
id UUID PRIMARY KEY
folio TEXT UNIQUE
unidad_operativa_id
programa_id
accion_id
tipo_registro_id

municipio_id
comunidad_id
espacio_id

nombre
descripcion
fecha_inicio
fecha_fin
periodo_anio
periodo_mes

total_beneficiarios

estatus
origen

created_by
created_at
updated_by
updated_at

deleted_at
deleted_by
```

---

# 12. FOLIO INSTITUCIONAL

El UUID será la identidad técnica.

El folio será la identidad humana.

Formato recomendado:

```text
SC-V-2026-000001
SC-V-2026-000002
...
```

El folio se generará en PostgreSQL mediante mecanismo atómico.

Nunca mediante:

```javascript
Math.random()
```

Esto evita colisiones.

---

# 13. POBLACIÓN BENEFICIARIA

El total oficial se almacenará separado:

```text
registros.total_beneficiarios
```

Las desagregaciones NO se sumarán entre dimensiones distintas.

Modelo:

```text
cat_dimensiones_poblacion
```

Ejemplos:

- GENERO
- GRUPO_ETARIO
- GRUPO_PRIORITARIO

```text
cat_opciones_poblacion
```

Ejemplos:

```text
GENERO
 ├── Mujeres
 └── Hombres

GRUPO_ETARIO
 ├── Niñez
 ├── Adolescencia
 ├── Juventudes
 └── Adultos mayores

GRUPO_PRIORITARIO
 ├── Discapacidad
 ├── Pueblos indígenas
 ├── Afromexicanas
 └── LGBTQ+
```

Valores:

```text
registro_poblacion
```

Campos:

```text
registro_id
opcion_poblacion_id
cantidad
```

Regla:

> Las categorías de una dimensión pueden validarse contra el total; nunca se sumarán entre dimensiones diferentes para calcular beneficiarios.

---

# 14. DETALLES ESPECIALIZADOS

## 14.1 Taller

```text
registro_taller
```

Campos:

```text
registro_id
disciplina
docente_id
programacion
modalidad_cuota
horario_resumen
```

Los días/horarios podrán tener tabla hija cuando se requiera más de un bloque.

---

## 14.2 Proyecto

```text
registro_proyecto
```

Campos:

```text
registro_id
justificacion
objetivo_general
fecha_inicio
fecha_fin
resultado_general
```

Objetivos:

```text
proyecto_objetivos
```

Actividades:

```text
proyecto_actividades
```

---

## 14.3 Reunión

```text
registro_reunion
```

Campos:

```text
registro_id
tema
acuerdos
numero_participantes
```

---

## 14.4 Intercambio

```text
registro_intercambio
```

Permitirá distinguir:

- enviado
- recibido
- origen
- destino
- participantes

---

## 14.5 Estadística de Bibliotecas

Por la amplitud y posible cambio anual de sus variables, se utilizará un modelo de métricas controladas.

```text
biblioteca_estadistica
```

Cabecera:

```text
registro_id
biblioteca_id
anio
mes
```

Catálogo de métricas:

```text
cat_metricas_biblioteca
```

Ejemplos:

```text
clave
nombre
grupo
unidad
ejercicio
activo
```

Valores:

```text
biblioteca_estadistica_valores
```

Campos:

```text
estadistica_id
metrica_id
valor
```

Esto permite que cambien variables en 2027 sin agregar decenas de columnas nuevas.

---

# 15. INDICADORES

Los indicadores tendrán identidad y versión por ejercicio.

```text
cat_indicadores
```

Define el indicador conceptual.

```text
indicadores_version
```

Define su versión anual.

Campos conceptuales:

```text
id
indicador_id
ejercicio
clave
nombre
unidad_medida_id
descripcion
activo
vigente_desde
vigente_hasta
```

---

# 16. METAS

```text
metas_indicador
```

Permitirá metas por:

- ejercicio
- indicador
- unidad operativa
- región
- municipio, cuando corresponda

Campos:

```text
indicador_version_id
ejercicio
meta
unidad_operativa_id
region_id
municipio_id
```

Los campos de alcance territorial podrán ser nulos cuando la meta sea estatal.

---

# 17. RELACIÓN ACCIÓN → INDICADOR

```text
accion_indicador
```

La captura no obligará al usuario a escoger manualmente el indicador si la configuración ya lo determina.

Ejemplo:

```text
Acción: Reunión de colaboración
   ↓
Indicador versión 2026: XXXXX
   ↓
Regla de aporte: 1 por registro VALIDADO
```

Tipos iniciales de regla:

```text
UNO_POR_REGISTRO
TOTAL_BENEFICIARIOS
VALOR_METRICA
VALOR_MANUAL_VALIDADO
```

Las reglas complejas deberán implementarse de forma controlada.

---

# 18. VISTAS DE AVANCE

El dashboard no descargará todos los registros para calcular indicadores.

PostgreSQL proporcionará:

```text
vw_avance_indicadores
vw_resumen_municipios
vw_resumen_unidades
vw_calidad_datos
vw_pendientes_validacion
```

El frontend recibirá agregados.

---

# 19. VALIDACIÓN INSTITUCIONAL

Estados:

```text
BORRADOR
CAPTURADO
EN_REVISION
OBSERVADO
CORREGIDO
VALIDADO
ANULADO
```

Flujo:

```text
CAPTURADO
    ↓
EN_REVISION
 ┌──┴───────────┐
 ↓              ↓
VALIDADO     OBSERVADO
                 ↓
             CORREGIDO
                 ↓
             EN_REVISION
```

El registro conservará su estatus actual.

El historial se almacenará en:

```text
registro_validaciones
```

Campos:

```text
id
registro_id
estatus_anterior
estatus_nuevo
observacion
usuario_id
created_at
```

---

# 20. EVIDENCIAS

Bucket:

```text
evidencias
```

Siempre privado.

Metadatos:

```text
registro_evidencias
```

Campos:

```text
id
registro_id
tipo_evidencia
storage_path
nombre_original
mime_type
size_bytes
uploaded_by
created_at
activo
```

Ruta recomendada:

```text
evidencias/{unidad_operativa}/{registro_uuid}/{archivo_uuid.ext}
```

La aplicación obtendrá Signed URLs.

Nunca se almacenará una URL pública permanente como fuente canónica.

---

# 21. IMPORTACIONES

Todas las importaciones pasarán por staging.

## 21.1 Trabajo de importación

```text
import_jobs
```

Campos:

```text
id
tipo_importacion
archivo
usuario_id
estatus
total_filas
validas
errores
duplicadas
created_at
completed_at
```

## 21.2 Filas temporales

```text
import_staging
```

Campos:

```text
id
import_job_id
numero_fila
raw_data JSONB
normalized_data JSONB
estatus
errores JSONB
```

Flujo:

```text
Excel
  ↓
Lectura
  ↓
Normalización
  ↓
Alias
  ↓
Validación
  ↓
Preview
  ↓
Confirmación
  ↓
Carga definitiva
```

Nunca:

```text
Excel → INSERT directo
```

---

# 22. PLANTILLAS EXCEL

Cada catálogo administrable podrá generar su propia plantilla.

Ejemplos:

## Comunidades

```text
Municipio | Comunidad | Tipo_Asentamiento
```

## Espacios

```text
Unidad | Municipio | Comunidad | Tipo_Espacio | Nombre_Espacio
```

## Personas

```text
Nombre | Funcion | Municipio | Correo | Telefono
```

## Acciones

```text
Unidad | Programa | Accion | Tipo_Registro | Tipo_Formulario
```

## Indicadores

```text
Ejercicio | Clave | Indicador | Unidad_Medida | Meta
```

---

# 23. PANEL DE ADMINISTRACIÓN V2

Navegación:

```text
Administración
├── Resumen
├── Catálogos
├── Configuración
├── Usuarios
├── Importaciones
└── Auditoría
```

Catálogos:

```text
ORGANIZACIÓN
- Unidades operativas
- Programas
- Acciones

TERRITORIO
- Regiones
- Municipios
- Comunidades

ESPACIOS
- Tipos de espacio
- Espacios culturales

PERSONAS
- Personas
- Funciones

SEGUIMIENTO
- Tipos de registro
- Indicadores
- Metas
- Matriz de configuración
- Métricas de bibliotecas
```

Cada gestor utilizará el mismo patrón:

```text
Buscar
Filtrar

+ Nuevo
Importar Excel
Descargar plantilla

Tabla:
Nombre | Relación | Estatus | Editar | Desactivar
```

No habrá DELETE físico normal desde la interfaz.

---

# 24. ROLES

Roles:

```text
ADMIN
SUPERVISOR
DIRECTIVO
CAPTURISTA
```

## ADMIN

- Configuración completa
- Usuarios
- Roles
- Catálogos
- Importaciones
- Auditoría
- Todos los registros

## SUPERVISOR

- Consulta dentro de su alcance
- Revisión
- Observación
- Validación
- Importaciones autorizadas
- Sin cambio de roles

## DIRECTIVO

- Consulta
- Dashboard
- Indicadores
- Reportes
- Sin modificación operativa

## CAPTURISTA

- Crear registros dentro de su alcance
- Consultar sus registros
- Corregir observados
- Sin validar
- Sin administrar catálogos críticos

---

# 25. ALCANCE DE USUARIO

No se asumirá que un usuario pertenece a un solo municipio o unidad.

Se utilizarán relaciones:

```text
usuario_unidades
usuario_municipios
```

Esto permitirá:

- Capturista municipal
- Supervisor regional
- Supervisor de CDCM
- Directivo estatal
- Administrador global

---

# 26. SEGURIDAD

Reglas obligatorias:

1. RLS habilitado en todas las tablas expuestas.
2. `anon` no tendrá acceso a información operativa.
3. `authenticated` tendrá acceso según rol y alcance.
4. El frontend nunca otorgará roles.
5. El frontend nunca se considerará mecanismo de autorización.
6. `service_role` nunca estará en navegador.
7. El publishable/anon key podrá existir en frontend.
8. Storage permanecerá privado.
9. Las funciones sensibles usarán permisos mínimos.
10. Functions `SECURITY DEFINER`, si son necesarias, fijarán `search_path`.
11. Cambios de roles deberán auditarse.
12. RLS impedirá auto-promoción.
13. El primer ADMIN se creará mediante bootstrap controlado y separado.

---

# 27. AUDITORÍA

Tabla:

```text
audit_log
```

Eventos mínimos:

```text
INSERT
UPDATE
STATUS_CHANGE
VALIDATE
OBSERVE
ANNUL
IMPORT
ROLE_CHANGE
CATALOG_CHANGE
EVIDENCE_CHANGE
```

Campos:

```text
id
tabla
registro_id
accion
usuario_id
valor_anterior JSONB
valor_nuevo JSONB
created_at
```

La auditoría no dependerá del HTML.

---

# 28. SOFT DELETE

Catálogos:

```text
activo = false
```

Registros:

```text
estatus = ANULADO
deleted_at
deleted_by
```

No se utilizará DELETE físico como operación normal de usuario.

---

# 29. OFFLINE

IndexedDB utilizará como llave un UUID estable, no folio aleatorio.

Datos locales:

```text
local_id UUID
registro_uuid UUID
payload
foto_blob
created_by_uid
sync_status
sync_attempts
last_sync_error
last_sync_at
created_at
```

Estados:

```text
PENDING
SYNCING
SYNCED
ERROR
```

La sincronización será idempotente.

---

# 30. SERVICE WORKER

Estrategias:

```text
Assets estáticos       cache-first
HTML                    network-first
Supabase REST           network-only
Supabase Auth           network-only
Storage privado         network-only
Signed URLs             no-cache
```

No se almacenarán indiscriminadamente respuestas autenticadas.

---

# 31. ARQUITECTURA FRONTEND V2

Evolución gradual desde HTML monolítico.

Estructura objetivo:

```text
/
├── index.html
├── admin.html
├── manifest.json
├── sw.js
│
├── assets/
│   ├── logos/
│   └── icons/
│
├── css/
│   ├── app.css
│   └── admin.css
│
├── js/
│   ├── config.js
│   ├── supabase-client.js
│   ├── auth.js
│   ├── permissions.js
│   ├── catalogs.js
│   ├── capture.js
│   ├── bitacora.js
│   ├── dashboard.js
│   ├── evidence.js
│   ├── imports.js
│   ├── validation.js
│   ├── offline-db.js
│   │
│   ├── forms/
│   │   ├── taller.js
│   │   ├── proyecto.js
│   │   ├── reunion.js
│   │   └── biblioteca.js
│   │
│   └── admin/
│       ├── catalog-manager.js
│       ├── users.js
│       ├── imports.js
│       └── audit.js
│
├── sql/
│   └── v2/
│
├── docs/
│
└── backup/
    └── v1/
```

La modularización podrá hacerse progresivamente.

---

# 32. ESTRUCTURA SQL V2

La fuente técnica deberá dividirse en archivos mantenibles:

```text
/sql/v2/

00_preflight.sql
01_core_schema.sql
02_catalogs.sql
03_operation_modules.sql
04_indicators.sql
05_functions_triggers.sql
06_rls.sql
07_storage.sql
08_views_rpc.sql
09_seed_base.sql
10_legacy_migration.sql
11_tests.sql

99_vinculacion_v2_super.sql
```

`99_vinculacion_v2_super.sql` será la versión consolidada para ejecución controlada.

Los archivos 00–11 serán la fuente mantenible.

---

# 33. MIGRACIÓN DE V1

Nunca se reconstruirá V2 destruyendo V1 sin respaldo.

Flujo:

```text
1. Exportar V1
2. Congelar respaldo
3. Crear V2
4. Cargar catálogos base
5. Migrar históricos a staging
6. Normalizar alias
7. Detectar inconsistencias
8. Migrar registros válidos
9. Marcar registros pendientes
10. Verificar totales
11. Cambiar frontend a V2
```

Los registros históricos problemáticos no se borrarán silenciosamente.

---

# 34. DATOS HISTÓRICOS

Origen de datos posible:

```text
MANUAL
OFFLINE
IMPORTACION_EXCEL
MIGRACION_V1
API
```

Cada registro deberá indicar su origen.

Los importados podrán conservar:

```text
archivo_origen
fila_origen
import_job_id
```

---

# 35. CONCENTRADOS

Los concentrados no serán una captura adicional cuando puedan derivarse de registros operativos.

Modelo:

```text
Captura normalizada
        ↓
PostgreSQL
        ↓
Views / RPC
        ↓
Concentrado mensual
Concentrado semestral
Concentrado anual
Numeralia
```

Se evitará duplicar el mismo hecho mediante captura individual + captura de concentrado.

---

# 36. DASHBOARD

Capas:

## Operativa

- Registros capturados
- Pendientes
- Observados
- Evidencia
- Cobertura

## Territorial

- Municipios
- Comunidades
- Espacios
- Cobertura

## Directiva

- Indicadores
- Metas
- Avance
- Brecha
- Tendencia
- Unidades operativas

## Calidad

- Completitud
- Registros sin evidencia
- Registros sin territorio válido
- Inconsistencias
- Observados
- Pendientes de validación

---

# 37. ÍNDICE DE CALIDAD DEL REGISTRO

V2 podrá calcular un ICR basado en componentes:

```text
Completitud
Consistencia
Territorio
Evidencia
Georreferenciación
Validación
```

El ICR no sustituye la validación institucional.

Sirve para detectar registros débiles.

---

# 38. REGLAS DE DISEÑO

1. No hardcodear catálogos institucionales en HTML salvo constantes técnicas.
2. No usar texto libre para claves de relación.
3. No crear una columna nueva por cada indicador anual.
4. No crear un HTML diferente por municipio.
5. No crear una base diferente por unidad operativa.
6. No insertar Excel directamente a tablas productivas.
7. No borrar registros para corregirlos.
8. No confiar en la UI para seguridad.
9. No sumar dimensiones demográficas incompatibles.
10. No reutilizar el folio como PK técnico.
11. No exponer evidencias mediante URLs públicas.
12. No modificar V1 sin respaldo.

---

# 39. PRIMER ALCANCE FUNCIONAL V2

## Release V2.1 — Core

Incluye:

- Seguridad
- Roles
- Alcances
- Auditoría
- Territorio
- Unidades
- Espacios
- Personas
- Tipos de registro
- Acciones
- Registro base
- Evidencias
- Validación
- Import staging
- Storage
- Folios
- RLS

## Release V2.2 — Admin

Incluye:

- Gestor genérico de catálogos
- Excel
- Plantillas
- Usuarios
- Roles
- Importaciones
- Auditoría

## Release V2.3 — CDCM

Incluye inicialmente:

- Taller
- Capacitación
- Curso de verano
- Reunión
- Intercambio
- Proyecto sociocultural
- Proyecto circuito/regional
- Evento

## Release V2.4 — Indicadores

- Versionado anual
- Metas
- Reglas de aporte
- Avance automático
- Dashboard directivo

## Release V2.5 — Bibliotecas

- Directorio/espacios
- Responsables
- Estadística mensual
- Métricas versionadas
- Indicadores
- Concentrados

---

# 40. CRITERIOS DE V2.1 TERMINADO

V2.1 estará terminado cuando:

- RLS esté activo y probado.
- Ningún usuario pueda cambiar su propio rol.
- El primer ADMIN tenga bootstrap controlado.
- Municipios estén normalizados.
- Comunidades puedan cargarse por Excel.
- Espacios puedan administrarse sin código.
- Personas puedan administrarse sin código.
- Acciones puedan configurarse.
- El UUID sea estable.
- El folio sea único y generado por BD.
- Storage sea privado.
- La captura sea idempotente.
- Exista soft delete.
- Exista auditoría.
- Exista staging de importación.
- V1 siga respaldado.

---

# 41. UBICACIÓN DE ESTE DOCUMENTO

Crear en la raíz del proyecto:

```text
/docs
```

Guardar este archivo como:

```text
/docs/Vinculacion_V2_Blueprint.md
```

Este documento será el **documento rector**.

Si una implementación contradice este Blueprint, deberá:

1. corregirse, o
2. actualizarse explícitamente este Blueprint mediante una nueva versión.

No se modificarán arquitectura y código por separado sin documentar el cambio.

---

# 42. ESTRUCTURA RECOMENDADA DEL PROYECTO AL INICIAR V2

```text
Vinculacion-Cultural/
│
├── docs/
│   └── Vinculacion_V2_Blueprint.md
│
├── backup/
│   └── v1/
│       ├── index.html
│       ├── admin.html
│       ├── offline-db.js
│       ├── sw.js
│       └── manifest.json
│
├── sql/
│   └── v2/
│
├── index.html
├── admin.html
├── offline-db.js
├── sw.js
├── manifest.json
│
├── assets/
└── data-local-no-git/
```

Los respaldos con datos personales, CSV o exportaciones de Supabase NO deben publicarse en repositorios públicos.

---

# 43. SIGUIENTE PASO OFICIAL

Una vez aprobado este Blueprint:

## Paso 1
Congelar respaldo V1.

## Paso 2
Generar:

```text
/sql/v2/00_preflight.sql
...
/sql/v2/99_vinculacion_v2_super.sql
```

## Paso 3
Revisar el SQL sin ejecutarlo.

## Paso 4
Respaldar Supabase.

## Paso 5
Ejecutar V2.1 de manera controlada.

## Paso 6
Construir `admin.html` V2 completo.

## Paso 7
Construir `index.html` V2 completo.

---

# 44. DECISIÓN DE ARQUITECTURA

**Aprobación propuesta:**

> Vinculación Cultural 2.0 se construirá como una plataforma institucional única, parametrizada por catálogos, con núcleo común, módulos especializados, territorio normalizado, indicadores versionados, administración autoservicio, seguridad RLS, evidencias privadas, validación, auditoría, importación controlada y compatibilidad offline.

Este Blueprint reemplaza como referencia de arquitectura a los scripts SQL históricos y a las decisiones ad hoc utilizadas durante la construcción de V1.

Los scripts y archivos V1 se conservarán únicamente como base funcional y fuente de migración.
