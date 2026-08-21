-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 09e_operational_seed_2026.sql
-- Configuración operativa y metas de proceso oficiales 2026
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   02_catalogs.sql
--   03_operation_modules.sql
--   04_indicators.sql
--   05_functions_triggers.sql + 05a hotfix
--   06_rls.sql
--   07_storage.sql
--   08_views_rpc.sql
--   09_seed_base.sql
--   09b_operational_seed.sql
--   09d_demographic_model_2026.sql
--
-- FUENTE:
--   Base para indicadores oficial / Cat_Alineacion 2026.
--
-- CARGA:
--   ✓ cierre de configuraciones históricas CDCM 2025
--   ✓ tipos de registro APOYO y VISITA
--   ✓ unidades de medida oficiales faltantes
--   ✓ programas Bibliotecas necesarios para acciones 2026
--   ✓ 13 acciones operativas PB 2026
--       - 9 CDCM
--       - 4 Bibliotecas
--   ✓ 13 configuraciones de formulario vigentes 2026
--   ✓ 14 metas/indicadores de proceso oficiales 2026
--       - QC4102.2601
--       - PB3562.2601 a PB3562.2605
--       - PB3563.2601 a PB3563.2605
--       - PB3564.2601 a PB3564.2603
--   ✓ 14 metas anuales
--   ✓ 13 reglas automáticas UNO_POR_REGISTRO
--
-- REGLA DE PRUDENCIA:
--   QC4102.2601 se registra con su meta oficial de 20 talleres, pero NO se
--   vincula automáticamente a una acción PB. La documentación revisada no
--   demuestra una relación de equivalencia que permita hacerlo sin riesgo de
--   doble conteo.
--
-- PARA LOS 13 PB:
--   Una fila VALIDADA de la acción oficial representa una unidad realizada.
--   Por eso UNO_POR_REGISTRO es una regla segura siempre que el frontend
--   mantenga la granularidad de "un registro = una unidad reportable".
--
-- NO HACE:
--   ✗ no migra V1
--   ✗ no carga registros históricos
--   ✗ no elimina indicadores 2025
--   ✗ no convierte total_beneficiarios a participantes/accesos
--   ✗ no crea reglas automáticas para QC4102.2601
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '240s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.cat_esquemas_demograficos') IS NULL
     OR to_regclass('v2.cat_acciones') IS NULL
     OR to_regclass('v2.configuracion_acciones') IS NULL
     OR to_regclass('v2.cat_indicadores') IS NULL
     OR to_regclass('v2.indicadores_version') IS NULL
     OR to_regclass('v2.metas_indicador') IS NULL
     OR to_regclass('v2.accion_indicador') IS NULL THEN

    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos requeridos de V2.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.09d'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 09d_demographic_model_2026.sql.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.cat_esquemas_demograficos
    WHERE upper(btrim(clave)) = 'OFICIAL_2026'
      AND activo = true
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: no existe el esquema demográfico OFICIAL_2026.';
  END IF;
END
$$;


-- ============================================================================
-- 01. CERRAR VIGENCIA DE CONFIGURACIONES CDCM HISTÓRICAS 2025
--
-- No se desactivan: deben seguir siendo legibles para históricos.
-- Solo se evita que sean consideradas configuración vigente en 2026.
-- ============================================================================

UPDATE v2.configuracion_acciones ca
SET
  vigente_hasta = DATE '2025-12-31'
FROM v2.cat_acciones a
JOIN v2.cat_unidades_operativas u
  ON u.id = a.unidad_operativa_id
WHERE ca.accion_id = a.id
  AND upper(btrim(u.clave)) = 'CDCM'
  AND ca.vigente_desde = DATE '2025-01-01'
  AND (
    ca.vigente_hasta IS NULL
    OR ca.vigente_hasta <> DATE '2025-12-31'
  );


-- ============================================================================
-- 02. TIPOS DE REGISTRO 2026 FALTANTES
-- ============================================================================

INSERT INTO v2.cat_tipos_registro (
  clave,
  nombre,
  descripcion,
  orden,
  activo
)
SELECT *
FROM (
  VALUES
    (
      'APOYO',
      'Apoyo',
      'Apoyo institucional otorgado a organismo, colectivo, persona o proyecto.',
      120,
      true
    ),
    (
      'VISITA',
      'Visita',
      'Visita cultural, educativa, patrimonial o de mediación.',
      130,
      true
    )
) AS x(clave, nombre, descripcion, orden, activo)
WHERE NOT EXISTS (
  SELECT 1
  FROM v2.cat_tipos_registro tr
  WHERE lower(btrim(tr.clave)) = lower(x.clave)
);


UPDATE v2.cat_tipos_registro tr
SET
  nombre = x.nombre,
  descripcion = x.descripcion,
  orden = x.orden,
  activo = true
FROM (
  VALUES
    (
      'APOYO',
      'Apoyo',
      'Apoyo institucional otorgado a organismo, colectivo, persona o proyecto.',
      120
    ),
    (
      'VISITA',
      'Visita',
      'Visita cultural, educativa, patrimonial o de mediación.',
      130
    )
) AS x(clave, nombre, descripcion, orden)
WHERE lower(btrim(tr.clave)) = lower(x.clave);


-- ============================================================================
-- 03. UNIDADES DE MEDIDA OFICIALES FALTANTES
-- ============================================================================

INSERT INTO v2.cat_unidades_medida (
  clave,
  nombre,
  simbolo,
  tipo_dato,
  activo
)
SELECT *
FROM (
  VALUES
    ('TALLER', 'Taller realizado', NULL::TEXT, 'ENTERO', true),
    ('CURSO_TALLER', 'Curso o taller realizado', NULL::TEXT, 'ENTERO', true),
    ('CAPACITACION', 'Capacitación realizada', NULL::TEXT, 'ENTERO', true),
    ('APOYO', 'Apoyo otorgado', NULL::TEXT, 'ENTERO', true),
    ('VISITA', 'Visita realizada', NULL::TEXT, 'ENTERO', true),
    ('ACTIVIDAD', 'Actividad realizada', NULL::TEXT, 'ENTERO', true),
    (
      'ENCUENTRO_CAPACITACION',
      'Encuentro o capacitación realizada',
      NULL::TEXT,
      'ENTERO',
      true
    ),
    (
      'ENCUENTRO_CIRCULO',
      'Encuentro o círculo realizado',
      NULL::TEXT,
      'ENTERO',
      true
    )
) AS x(clave, nombre, simbolo, tipo_dato, activo)
WHERE NOT EXISTS (
  SELECT 1
  FROM v2.cat_unidades_medida um
  WHERE lower(btrim(um.clave)) = lower(x.clave)
);


-- ============================================================================
-- 04. PROGRAMAS PARA BIBLIOTECAS
--
-- cat_programas.clave es globalmente UNIQUE, por eso se usan claves BIB_*.
-- ============================================================================

WITH unidad AS (
  SELECT id
  FROM v2.cat_unidades_operativas
  WHERE upper(btrim(clave)) = 'BIBLIOTECAS'
  LIMIT 1
),
datos(clave, nombre, descripcion, orden) AS (
  VALUES
    (
      'BIB_INTEGRACION_NODOS',
      'Integración de nodos creativos y formativos — Bibliotecas',
      'Vertiente de Bibliotecas para formación lectora y capacitación.',
      10
    ),
    (
      'BIB_COORDINACION_REDES',
      'Coordinación y vinculación de redes de mediación cultural municipal — Bibliotecas',
      'Vertiente de Bibliotecas para promoción lectora y fortalecimiento de la red.',
      20
    ),
    (
      'BIB_FORTALECIMIENTO_PARTICIPATIVO',
      'Fortalecimiento de procesos participativos municipales — Bibliotecas',
      'Vertiente de Bibliotecas para encuentros de lectores y círculos de lectura.',
      30
    )
)
INSERT INTO v2.cat_programas (
  unidad_operativa_id,
  clave,
  nombre,
  descripcion,
  orden,
  activo
)
SELECT
  u.id,
  d.clave,
  d.nombre,
  d.descripcion,
  d.orden,
  true
FROM unidad u
CROSS JOIN datos d
WHERE NOT EXISTS (
  SELECT 1
  FROM v2.cat_programas p
  WHERE lower(btrim(p.clave)) = lower(d.clave)
);


-- ============================================================================
-- 05. ACCIONES OFICIALES PB 2026
--
-- Las claves internas reproducen la clave de proceso con "_" para facilitar
-- trazabilidad sin usarla como texto de negocio.
-- ============================================================================

WITH datos(
  accion_clave,
  unidad_clave,
  programa_clave,
  nombre,
  descripcion,
  orden
) AS (
  VALUES
    -- CDCM / Integración de nodos
    (
      'PB3562_2601',
      'CDCM',
      'INTEGRACION_NODOS',
      'Cursos y talleres para promotores culturales e instructores de casas de la cultura',
      'Meta de proceso PB3562.2601.',
      210
    ),
    (
      'PB3562_2602',
      'CDCM',
      'INTEGRACION_NODOS',
      'Talleres de educación artística y cultural no formales impartidos en casas de cultura y salones culturales',
      'Meta de proceso PB3562.2602.',
      220
    ),
    (
      'PB3562_2604',
      'CDCM',
      'INTEGRACION_NODOS',
      'Talleres de seguimiento a la implementación del programa curricular para la asignatura de artes en la educación básica',
      'Meta de proceso PB3562.2604.',
      240
    ),
    (
      'PB3562_2605',
      'CDCM',
      'INTEGRACION_NODOS',
      'Capacitaciones en danza folclórica dirigidas a directores, maestros y ejecutantes del estado de Guanajuato',
      'Meta de proceso PB3562.2605.',
      250
    ),

    -- Bibliotecas / Integración de nodos
    (
      'PB3562_2603',
      'BIBLIOTECAS',
      'BIB_INTEGRACION_NODOS',
      'Cursos y talleres de formación lectora para bibliotecarios, niños narradores y escritores, padres de familia y promotores de lectura',
      'Meta de proceso PB3562.2603.',
      230
    ),

    -- CDCM / Coordinación de redes
    (
      'PB3563_2601',
      'CDCM',
      'COORDINACION_REDES',
      'Apoyos especiales a organismos culturales municipales',
      'Meta de proceso PB3563.2601.',
      310
    ),
    (
      'PB3563_2602',
      'CDCM',
      'COORDINACION_REDES',
      'Actividades colaborativas de la red de identidad, cultura y memoria',
      'Meta de proceso PB3563.2602.',
      320
    ),
    (
      'PB3563_2603',
      'CDCM',
      'COORDINACION_REDES',
      'Visitas escolares a zonas arqueológicas y recintos culturales del estado',
      'Visitas para impulsar aprendizajes significativos en alumnado de educación básica. Meta PB3563.2603.',
      330
    ),

    -- Bibliotecas / Coordinación de redes
    (
      'PB3563_2604',
      'BIBLIOTECAS',
      'BIB_COORDINACION_REDES',
      'Actividades de promoción y animación lectora para público en general',
      'Meta de proceso PB3563.2604.',
      340
    ),
    (
      'PB3563_2605',
      'BIBLIOTECAS',
      'BIB_COORDINACION_REDES',
      'Encuentros y capacitaciones del personal bibliotecario incorporado a la red estatal de bibliotecas públicas',
      'Meta de proceso PB3563.2605.',
      350
    ),

    -- CDCM / Fortalecimiento participativo
    (
      'PB3564_2601',
      'CDCM',
      'FORTALECIMIENTO_PARTICIPATIVO',
      'Proyectos culturales interinstitucionales y comunitarios dirigidos a públicos vulnerables',
      'Meta de proceso PB3564.2601.',
      410
    ),
    (
      'PB3564_2602',
      'CDCM',
      'FORTALECIMIENTO_PARTICIPATIVO',
      'Proyectos socioculturales en barrios, colonias, periferias y/o comunidades',
      'Meta de proceso PB3564.2602.',
      420
    ),

    -- Bibliotecas / Fortalecimiento participativo
    (
      'PB3564_2603',
      'BIBLIOTECAS',
      'BIB_FORTALECIMIENTO_PARTICIPATIVO',
      'Encuentros de lectores y círculos de lectura para usuarios de la red estatal de bibliotecas públicas',
      'Meta de proceso PB3564.2603.',
      430
    )
)
INSERT INTO v2.cat_acciones (
  unidad_operativa_id,
  programa_id,
  clave,
  nombre,
  descripcion,
  orden,
  activo
)
SELECT
  u.id,
  p.id,
  d.accion_clave,
  d.nombre,
  d.descripcion,
  d.orden,
  true
FROM datos d
JOIN v2.cat_unidades_operativas u
  ON upper(btrim(u.clave)) = d.unidad_clave
JOIN v2.cat_programas p
  ON lower(btrim(p.clave)) = lower(d.programa_clave)
 AND p.unidad_operativa_id = u.id
WHERE NOT EXISTS (
  SELECT 1
  FROM v2.cat_acciones a
  WHERE lower(btrim(a.clave)) = lower(d.accion_clave)
);


-- Actualización idempotente de nombre/programa/unidad.
WITH datos(
  accion_clave,
  unidad_clave,
  programa_clave,
  nombre,
  descripcion,
  orden
) AS (
  VALUES
    ('PB3562_2601','CDCM','INTEGRACION_NODOS','Cursos y talleres para promotores culturales e instructores de casas de la cultura','Meta de proceso PB3562.2601.',210),
    ('PB3562_2602','CDCM','INTEGRACION_NODOS','Talleres de educación artística y cultural no formales impartidos en casas de cultura y salones culturales','Meta de proceso PB3562.2602.',220),
    ('PB3562_2603','BIBLIOTECAS','BIB_INTEGRACION_NODOS','Cursos y talleres de formación lectora para bibliotecarios, niños narradores y escritores, padres de familia y promotores de lectura','Meta de proceso PB3562.2603.',230),
    ('PB3562_2604','CDCM','INTEGRACION_NODOS','Talleres de seguimiento a la implementación del programa curricular para la asignatura de artes en la educación básica','Meta de proceso PB3562.2604.',240),
    ('PB3562_2605','CDCM','INTEGRACION_NODOS','Capacitaciones en danza folclórica dirigidas a directores, maestros y ejecutantes del estado de Guanajuato','Meta de proceso PB3562.2605.',250),
    ('PB3563_2601','CDCM','COORDINACION_REDES','Apoyos especiales a organismos culturales municipales','Meta de proceso PB3563.2601.',310),
    ('PB3563_2602','CDCM','COORDINACION_REDES','Actividades colaborativas de la red de identidad, cultura y memoria','Meta de proceso PB3563.2602.',320),
    ('PB3563_2603','CDCM','COORDINACION_REDES','Visitas escolares a zonas arqueológicas y recintos culturales del estado','Visitas para impulsar aprendizajes significativos en alumnado de educación básica. Meta PB3563.2603.',330),
    ('PB3563_2604','BIBLIOTECAS','BIB_COORDINACION_REDES','Actividades de promoción y animación lectora para público en general','Meta de proceso PB3563.2604.',340),
    ('PB3563_2605','BIBLIOTECAS','BIB_COORDINACION_REDES','Encuentros y capacitaciones del personal bibliotecario incorporado a la red estatal de bibliotecas públicas','Meta de proceso PB3563.2605.',350),
    ('PB3564_2601','CDCM','FORTALECIMIENTO_PARTICIPATIVO','Proyectos culturales interinstitucionales y comunitarios dirigidos a públicos vulnerables','Meta de proceso PB3564.2601.',410),
    ('PB3564_2602','CDCM','FORTALECIMIENTO_PARTICIPATIVO','Proyectos socioculturales en barrios, colonias, periferias y/o comunidades','Meta de proceso PB3564.2602.',420),
    ('PB3564_2603','BIBLIOTECAS','BIB_FORTALECIMIENTO_PARTICIPATIVO','Encuentros de lectores y círculos de lectura para usuarios de la red estatal de bibliotecas públicas','Meta de proceso PB3564.2603.',430)
)
UPDATE v2.cat_acciones a
SET
  unidad_operativa_id = u.id,
  programa_id = p.id,
  nombre = d.nombre,
  descripcion = d.descripcion,
  orden = d.orden,
  activo = true
FROM datos d
JOIN v2.cat_unidades_operativas u
  ON upper(btrim(u.clave)) = d.unidad_clave
JOIN v2.cat_programas p
  ON lower(btrim(p.clave)) = lower(d.programa_clave)
 AND p.unidad_operativa_id = u.id
WHERE lower(btrim(a.clave)) = lower(d.accion_clave);


-- ============================================================================
-- 06. CONFIGURACIÓN DE FORMULARIOS VIGENTE 2026
--
-- total_beneficiarios NO se exige para estas configuraciones.
-- Participación/Acceso existen como campos 2026 y ambos pueden capturarse.
-- En configuracion_extra se conserva la clave y meta oficial.
-- ============================================================================

WITH datos(
  accion_clave,
  tipo_registro_clave,
  tipo_formulario,
  req_municipio,
  req_comunidad,
  req_espacio,
  req_responsable,
  req_docente,
  req_demografia,
  clave_proceso,
  unidad_oficial,
  meta_anual
) AS (
  VALUES
    ('PB3562_2601','CAPACITACION','CAPACITACION',true,false,false,true,true,true,'PB3562.2601','Cursos y talleres realizados',138::NUMERIC),
    ('PB3562_2602','TALLER','TALLER',true,false,true,true,true,true,'PB3562.2602','Talleres realizados',3800::NUMERIC),
    ('PB3562_2603','CAPACITACION','CAPACITACION',true,false,true,true,true,true,'PB3562.2603','Cursos y talleres realizados',90::NUMERIC),
    ('PB3562_2604','CAPACITACION','CAPACITACION',true,false,false,true,true,true,'PB3562.2604','Talleres realizados',20::NUMERIC),
    ('PB3562_2605','CAPACITACION','CAPACITACION',true,false,false,true,true,true,'PB3562.2605','Capacitaciones realizadas',2::NUMERIC),

    ('PB3563_2601','APOYO','APOYO',true,false,false,true,false,false,'PB3563.2601','Apoyos otorgados',74::NUMERIC),
    ('PB3563_2602','EVENTO','EVENTO',true,false,false,true,false,true,'PB3563.2602','Acciones realizadas',495::NUMERIC),
    ('PB3563_2603','VISITA','EVENTO',true,false,true,true,false,true,'PB3563.2603','Visitas realizadas',30::NUMERIC),
    ('PB3563_2604','EVENTO','EVENTO',true,false,true,true,false,true,'PB3563.2604','Actividades realizadas',125::NUMERIC),
    ('PB3563_2605','CAPACITACION','CAPACITACION',true,false,true,true,false,true,'PB3563.2605','Encuentros y capacitaciones realizadas',2::NUMERIC),

    ('PB3564_2601','PROYECTO_SOCIOCULTURAL','PROYECTO',true,false,false,true,false,true,'PB3564.2601','Proyectos realizados',3::NUMERIC),
    ('PB3564_2602','PROYECTO_SOCIOCULTURAL','PROYECTO',true,false,false,true,false,true,'PB3564.2602','Proyectos realizados',10::NUMERIC),
    ('PB3564_2603','EVENTO','EVENTO',true,false,true,true,false,true,'PB3564.2603','Encuentros y círculos realizados',95::NUMERIC)
),
esquema AS (
  SELECT id
  FROM v2.cat_esquemas_demograficos
  WHERE upper(btrim(clave)) = 'OFICIAL_2026'
  LIMIT 1
)
INSERT INTO v2.configuracion_acciones (
  accion_id,
  tipo_registro_id,
  tipo_formulario,

  requiere_municipio,
  requiere_comunidad,
  requiere_espacio,
  requiere_responsable,
  requiere_docente,

  requiere_beneficiarios,
  requiere_demografia,

  requiere_gps,
  requiere_evidencia,
  requiere_validacion,

  permite_offline,

  vigente_desde,
  vigente_hasta,

  configuracion_extra,
  activo,

  esquema_demografico_id
)
SELECT
  a.id,
  tr.id,
  d.tipo_formulario,

  d.req_municipio,
  d.req_comunidad,
  d.req_espacio,
  d.req_responsable,
  d.req_docente,

  false,
  d.req_demografia,

  false,
  true,
  true,

  true,

  DATE '2026-01-01',
  DATE '2026-12-31',

  pg_catalog.jsonb_build_object(
    'fuente', 'Base para indicadores oficial 2026',
    'clave_proceso', d.clave_proceso,
    'unidad_medida_oficial', d.unidad_oficial,
    'meta_anual', d.meta_anual,
    'captura_participacion', d.req_demografia,
    'captura_acceso', d.req_demografia,
    'participacion_y_acceso_son_variables_independientes', true,
    'granularidad', 'UNA_UNIDAD_REPORTABLE_POR_REGISTRO'
  ),

  true,
  e.id

FROM datos d

JOIN v2.cat_acciones a
  ON upper(btrim(a.clave)) = d.accion_clave

JOIN v2.cat_tipos_registro tr
  ON upper(btrim(tr.clave)) = d.tipo_registro_clave

CROSS JOIN esquema e

ON CONFLICT (accion_id, vigente_desde)
DO UPDATE SET
  tipo_registro_id = EXCLUDED.tipo_registro_id,
  tipo_formulario = EXCLUDED.tipo_formulario,

  requiere_municipio = EXCLUDED.requiere_municipio,
  requiere_comunidad = EXCLUDED.requiere_comunidad,
  requiere_espacio = EXCLUDED.requiere_espacio,
  requiere_responsable = EXCLUDED.requiere_responsable,
  requiere_docente = EXCLUDED.requiere_docente,

  requiere_beneficiarios = EXCLUDED.requiere_beneficiarios,
  requiere_demografia = EXCLUDED.requiere_demografia,

  requiere_gps = EXCLUDED.requiere_gps,
  requiere_evidencia = EXCLUDED.requiere_evidencia,
  requiere_validacion = EXCLUDED.requiere_validacion,

  permite_offline = EXCLUDED.permite_offline,

  vigente_hasta = EXCLUDED.vigente_hasta,
  configuracion_extra = EXCLUDED.configuracion_extra,
  activo = true,

  esquema_demografico_id = EXCLUDED.esquema_demografico_id;


-- ============================================================================
-- 07. INDICADORES CONCEPTUALES / METAS DE PROCESO 2026
--
-- cat_indicadores funciona aquí como catálogo conceptual estable.
-- indicadores_version conserva la CLAVE DE PROCESO oficial 2026.
-- ============================================================================

WITH datos(
  concepto_clave,
  unidad_clave,
  nombre
) AS (
  VALUES
    (
      'CAPACITACION_PROYECTOS_CULTURALES',
      NULL::TEXT,
      'Capacitación teórico-práctica para formulación, planeación y evaluación de proyectos culturales y artísticos'
    ),

    ('FORMACION_PROMOTORES_CULTURALES','CDCM','Cursos y talleres para promotores culturales e instructores de casas de la cultura'),
    ('TALLERES_NO_FORMALES_CDCM','CDCM','Talleres de educación artística y cultural no formales impartidos en casas de cultura y salones culturales'),
    ('FORMACION_LECTORA_BIBLIOTECAS','BIBLIOTECAS','Cursos y talleres de formación lectora para bibliotecarios, niños narradores y escritores, padres de familia y promotores de lectura'),
    ('SEGUIMIENTO_CURRICULAR_ARTES','CDCM','Talleres de seguimiento a la implementación del programa curricular para la asignatura de artes en la educación básica'),
    ('FORMACION_DANZA_FOLCLORICA','CDCM','Capacitaciones en danza folclórica dirigidas a directores, maestros y ejecutantes del estado de Guanajuato'),

    ('APOYOS_ORGANISMOS_CULTURALES_MUNICIPALES','CDCM','Apoyos especiales a organismos culturales municipales'),
    ('RED_IDENTIDAD_CULTURA_MEMORIA','CDCM','Actividades colaborativas de la red de identidad, cultura y memoria'),
    ('VISITAS_ESCOLARES_PATRIMONIO','CDCM','Visitas escolares a zonas arqueológicas y recintos culturales del estado'),
    ('PROMOCION_ANIMACION_LECTORA','BIBLIOTECAS','Actividades de promoción y animación lectora para público en general'),
    ('FORMACION_PERSONAL_BIBLIOTECARIO','BIBLIOTECAS','Encuentros y capacitaciones del personal bibliotecario incorporado a la red estatal de bibliotecas públicas'),

    ('PROYECTOS_INTERINSTITUCIONALES_VULNERABLES','CDCM','Proyectos culturales interinstitucionales y comunitarios dirigidos a públicos vulnerables'),
    ('PROYECTOS_SOCIOCULTURALES_TERRITORIO','CDCM','Proyectos socioculturales en barrios, colonias, periferias y/o comunidades'),
    ('CIRCULOS_LECTURA_BIBLIOTECAS','BIBLIOTECAS','Encuentros de lectores y círculos de lectura para usuarios de la red estatal de bibliotecas públicas')
)
INSERT INTO v2.cat_indicadores (
  clave_interna,
  nombre_base,
  descripcion,
  unidad_operativa_id,
  activo
)
SELECT
  d.concepto_clave,
  d.nombre,
  'Meta de proceso institucional versionada. Fuente oficial 2026.',
  u.id,
  true
FROM datos d
LEFT JOIN v2.cat_unidades_operativas u
  ON upper(btrim(u.clave)) = d.unidad_clave
WHERE NOT EXISTS (
  SELECT 1
  FROM v2.cat_indicadores i
  WHERE lower(btrim(i.clave_interna)) = lower(d.concepto_clave)
);


-- ============================================================================
-- 08. VERSIONES OFICIALES 2026
-- ============================================================================

WITH datos(
  concepto_clave,
  clave_proceso,
  nombre,
  unidad_medida_clave,
  unidad_medida_oficial,
  meta_anual,
  area,
  direccion,
  accion_clave
) AS (
  VALUES
    (
      'CAPACITACION_PROYECTOS_CULTURALES',
      'QC4102.2601',
      'Capacitación teórico-práctica a personas creadoras, gestoras, promotoras y productoras culturales a través de talleres para fortalecer sus capacidades en la formulación, planeación y evaluación de proyectos culturales y artísticos.',
      'TALLER',
      'Talleres realizados',
      20::NUMERIC,
      'Subsecretaría de Desarrollo Comunitario y Promoción Patrimonial',
      'Dirección de Vinculación',
      NULL::TEXT
    ),

    ('FORMACION_PROMOTORES_CULTURALES','PB3562.2601','Cursos y talleres para promotores culturales e instructores de casas de la cultura','CURSO_TALLER','Cursos y talleres realizados',138::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3562_2601'),
    ('TALLERES_NO_FORMALES_CDCM','PB3562.2602','Talleres de educación artística y cultural no formales impartidos en casas de cultura y salones culturales','TALLER','Talleres realizados',3800::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3562_2602'),
    ('FORMACION_LECTORA_BIBLIOTECAS','PB3562.2603','Cursos y talleres de formación lectora para bibliotecarios, niños narradores y escritores, padres de familia y promotores de lectura','CURSO_TALLER','Cursos y talleres realizados',90::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3562_2603'),
    ('SEGUIMIENTO_CURRICULAR_ARTES','PB3562.2604','Talleres de seguimiento a la implementación del programa curricular para la asignatura de artes en la educación básica','TALLER','Talleres realizados',20::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3562_2604'),
    ('FORMACION_DANZA_FOLCLORICA','PB3562.2605','Capacitaciones en danza folclórica dirigido a directores, maestros y ejecutantes del estado de Guanajuato','CAPACITACION','Capacitaciones realizadas',2::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3562_2605'),

    ('APOYOS_ORGANISMOS_CULTURALES_MUNICIPALES','PB3563.2601','Apoyos especiales a organismos culturales municipales','APOYO','Apoyos otorgados',74::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3563_2601'),
    ('RED_IDENTIDAD_CULTURA_MEMORIA','PB3563.2602','Actividades colaborativas de la red de identidad cultura y memoria','ACCION','Acciones realizadas',495::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3563_2602'),
    ('VISITAS_ESCOLARES_PATRIMONIO','PB3563.2603','Visitas escolares a zonas arqueológicas y recintos culturales del estado para impulsar aprendizajes significativos en alumnos de educación básica','VISITA','Visitas realizadas',30::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3563_2603'),
    ('PROMOCION_ANIMACION_LECTORA','PB3563.2604','Actividades de promoción y animación lectora para público en general','ACTIVIDAD','Actividades realizadas',125::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3563_2604'),
    ('FORMACION_PERSONAL_BIBLIOTECARIO','PB3563.2605','Encuentros y capacitaciones del personal bibliotecario incorporado a la red estatal de bibliotecas públicas del estado de Guanajuato','ENCUENTRO_CAPACITACION','Encuentros y capacitaciones realizadas',2::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3563_2605'),

    ('PROYECTOS_INTERINSTITUCIONALES_VULNERABLES','PB3564.2601','Proyectos culturales interinstitucionales y comunitarios dirigidos a públicos vulnerables','PROYECTO','Proyectos realizados',3::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3564_2601'),
    ('PROYECTOS_SOCIOCULTURALES_TERRITORIO','PB3564.2602','Proyectos socioculturales en barrios, colonias, periferias y/o comunidades','PROYECTO','Proyectos realizados',10::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3564_2602'),
    ('CIRCULOS_LECTURA_BIBLIOTECAS','PB3564.2603','Encuentros de lectores y círculos de lectura para usuarios de la red estatal de bibliotecas públicas','ENCUENTRO_CIRCULO','Encuentros y círculos realizados',95::NUMERIC,'Secretaría de Cultura','Secretaría de Cultura','PB3564_2603')
)
INSERT INTO v2.indicadores_version (
  indicador_id,
  ejercicio,
  clave,
  nombre,
  descripcion,
  unidad_medida_id,
  periodicidad,
  sentido,
  fuente,
  formula_descriptiva,
  desglose,
  vigente_desde,
  vigente_hasta,
  activo,
  metadata
)
SELECT
  i.id,
  2026,
  d.clave_proceso,
  d.nombre,
  'Meta de proceso oficial 2026.',
  um.id,
  'ANUAL',
  'ASCENDENTE',
  'Base para indicadores oficial 2026',
  CASE
    WHEN d.accion_clave IS NULL
      THEN 'Pendiente de alineación automática; no inferir relación con otras claves de proceso.'
    ELSE 'Conteo de registros VALIDADO asociados a la acción oficial; un registro equivale a una unidad reportable.'
  END,
  d.unidad_medida_oficial,
  DATE '2026-01-01',
  DATE '2026-12-31',
  true,
  pg_catalog.jsonb_build_object(
    'tipo', 'META_PROCESO_2026',
    'clave_proceso', d.clave_proceso,
    'meta_anual_fuente', d.meta_anual,
    'unidad_medida_fuente', d.unidad_medida_oficial,
    'area_fuente', d.area,
    'direccion_fuente', d.direccion,
    'accion_clave_v2', d.accion_clave,
    'auto_calculable', d.accion_clave IS NOT NULL
  )
FROM datos d
JOIN v2.cat_indicadores i
  ON upper(btrim(i.clave_interna)) = d.concepto_clave
JOIN v2.cat_unidades_medida um
  ON upper(btrim(um.clave)) = d.unidad_medida_clave

ON CONFLICT (indicador_id, ejercicio)
DO UPDATE SET
  clave = EXCLUDED.clave,
  nombre = EXCLUDED.nombre,
  descripcion = EXCLUDED.descripcion,
  unidad_medida_id = EXCLUDED.unidad_medida_id,
  periodicidad = EXCLUDED.periodicidad,
  sentido = EXCLUDED.sentido,
  fuente = EXCLUDED.fuente,
  formula_descriptiva = EXCLUDED.formula_descriptiva,
  desglose = EXCLUDED.desglose,
  vigente_desde = EXCLUDED.vigente_desde,
  vigente_hasta = EXCLUDED.vigente_hasta,
  activo = true,
  metadata = EXCLUDED.metadata;


-- ============================================================================
-- 09. METAS ANUALES 2026
--
-- Se registran como ESTATAL porque Meta_Anual es un valor agregado de la
-- ficha de proceso revisada, no una cuota municipal.
-- ============================================================================

WITH datos(clave_proceso, meta_anual) AS (
  VALUES
    ('QC4102.2601', 20::NUMERIC),

    ('PB3562.2601', 138::NUMERIC),
    ('PB3562.2602', 3800::NUMERIC),
    ('PB3562.2603', 90::NUMERIC),
    ('PB3562.2604', 20::NUMERIC),
    ('PB3562.2605', 2::NUMERIC),

    ('PB3563.2601', 74::NUMERIC),
    ('PB3563.2602', 495::NUMERIC),
    ('PB3563.2603', 30::NUMERIC),
    ('PB3563.2604', 125::NUMERIC),
    ('PB3563.2605', 2::NUMERIC),

    ('PB3564.2601', 3::NUMERIC),
    ('PB3564.2602', 10::NUMERIC),
    ('PB3564.2603', 95::NUMERIC)
)
UPDATE v2.metas_indicador m
SET
  meta = d.meta_anual,
  periodo_inicio = DATE '2026-01-01',
  periodo_fin = DATE '2026-12-31',
  observaciones = 'Meta_Anual de la fuente oficial 2026.',
  activo = true
FROM datos d
JOIN v2.indicadores_version iv
  ON iv.ejercicio = 2026
 AND upper(btrim(iv.clave)) = upper(d.clave_proceso)
WHERE m.indicador_version_id = iv.id
  AND m.alcance = 'ESTATAL';


WITH datos(clave_proceso, meta_anual) AS (
  VALUES
    ('QC4102.2601', 20::NUMERIC),

    ('PB3562.2601', 138::NUMERIC),
    ('PB3562.2602', 3800::NUMERIC),
    ('PB3562.2603', 90::NUMERIC),
    ('PB3562.2604', 20::NUMERIC),
    ('PB3562.2605', 2::NUMERIC),

    ('PB3563.2601', 74::NUMERIC),
    ('PB3563.2602', 495::NUMERIC),
    ('PB3563.2603', 30::NUMERIC),
    ('PB3563.2604', 125::NUMERIC),
    ('PB3563.2605', 2::NUMERIC),

    ('PB3564.2601', 3::NUMERIC),
    ('PB3564.2602', 10::NUMERIC),
    ('PB3564.2603', 95::NUMERIC)
)
INSERT INTO v2.metas_indicador (
  indicador_version_id,
  alcance,
  meta,
  periodo_inicio,
  periodo_fin,
  observaciones,
  activo
)
SELECT
  iv.id,
  'ESTATAL',
  d.meta_anual,
  DATE '2026-01-01',
  DATE '2026-12-31',
  'Meta_Anual de la fuente oficial 2026.',
  true
FROM datos d
JOIN v2.indicadores_version iv
  ON iv.ejercicio = 2026
 AND upper(btrim(iv.clave)) = upper(d.clave_proceso)
WHERE NOT EXISTS (
  SELECT 1
  FROM v2.metas_indicador m
  WHERE m.indicador_version_id = iv.id
    AND m.alcance = 'ESTATAL'
    AND m.activo = true
);


-- ============================================================================
-- 10. REGLAS AUTOMÁTICAS SEGURAS PARA LOS 13 PB
--
-- NO se incluye QC4102.2601.
-- ============================================================================

WITH mapa(accion_clave, clave_proceso) AS (
  VALUES
    ('PB3562_2601','PB3562.2601'),
    ('PB3562_2602','PB3562.2602'),
    ('PB3562_2603','PB3562.2603'),
    ('PB3562_2604','PB3562.2604'),
    ('PB3562_2605','PB3562.2605'),

    ('PB3563_2601','PB3563.2601'),
    ('PB3563_2602','PB3563.2602'),
    ('PB3563_2603','PB3563.2603'),
    ('PB3563_2604','PB3563.2604'),
    ('PB3563_2605','PB3563.2605'),

    ('PB3564_2601','PB3564.2601'),
    ('PB3564_2602','PB3564.2602'),
    ('PB3564_2603','PB3564.2603')
)
INSERT INTO v2.accion_indicador (
  accion_id,
  indicador_version_id,
  regla_aporte,
  parametros,
  requiere_validado,
  factor,
  activo
)
SELECT
  a.id,
  iv.id,
  'UNO_POR_REGISTRO',
  pg_catalog.jsonb_build_object(
    'fuente', 'Base para indicadores oficial 2026',
    'granularidad', 'UNA_UNIDAD_REPORTABLE_POR_REGISTRO',
    'clave_proceso', m.clave_proceso
  ),
  true,
  1,
  true
FROM mapa m
JOIN v2.cat_acciones a
  ON upper(btrim(a.clave)) = m.accion_clave
JOIN v2.indicadores_version iv
  ON iv.ejercicio = 2026
 AND upper(btrim(iv.clave)) = upper(m.clave_proceso)

ON CONFLICT (
  accion_id,
  indicador_version_id,
  regla_aporte
)
DO UPDATE SET
  parametros = EXCLUDED.parametros,
  requiere_validado = true,
  factor = 1,
  activo = true;


-- ============================================================================
-- 11. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.09e',
  '09e_operational_seed_2026.sql - Acciones, configuraciones, metas de proceso y reglas seguras 2026.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 12. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

SELECT
  'V2.1 - 09e_operational_seed_2026' AS instalacion,

  (
    SELECT count(*)
    FROM v2.configuracion_acciones ca
    JOIN v2.cat_acciones a
      ON a.id = ca.accion_id
    JOIN v2.cat_unidades_operativas u
      ON u.id = a.unidad_operativa_id
    WHERE upper(btrim(u.clave)) = 'CDCM'
      AND ca.vigente_desde = DATE '2025-01-01'
      AND ca.vigente_hasta = DATE '2025-12-31'
  ) AS configs_2025_cerradas,

  (
    SELECT count(*)
    FROM v2.cat_tipos_registro
    WHERE upper(btrim(clave)) IN ('APOYO', 'VISITA')
      AND activo = true
  ) AS tipos_2026_agregados,

  (
    SELECT count(*)
    FROM v2.cat_programas p
    JOIN v2.cat_unidades_operativas u
      ON u.id = p.unidad_operativa_id
    WHERE upper(btrim(u.clave)) = 'BIBLIOTECAS'
      AND upper(btrim(p.clave)) IN (
        'BIB_INTEGRACION_NODOS',
        'BIB_COORDINACION_REDES',
        'BIB_FORTALECIMIENTO_PARTICIPATIVO'
      )
      AND p.activo = true
  ) AS programas_bibliotecas_2026,

  (
    SELECT count(*)
    FROM v2.cat_acciones a
    JOIN v2.cat_unidades_operativas u
      ON u.id = a.unidad_operativa_id
    WHERE upper(btrim(u.clave)) = 'CDCM'
      AND upper(btrim(a.clave)) IN (
        'PB3562_2601',
        'PB3562_2602',
        'PB3562_2604',
        'PB3562_2605',
        'PB3563_2601',
        'PB3563_2602',
        'PB3563_2603',
        'PB3564_2601',
        'PB3564_2602'
      )
  ) AS acciones_cdcm_2026,

  (
    SELECT count(*)
    FROM v2.cat_acciones a
    JOIN v2.cat_unidades_operativas u
      ON u.id = a.unidad_operativa_id
    WHERE upper(btrim(u.clave)) = 'BIBLIOTECAS'
      AND upper(btrim(a.clave)) IN (
        'PB3562_2603',
        'PB3563_2604',
        'PB3563_2605',
        'PB3564_2603'
      )
  ) AS acciones_bibliotecas_2026,

  (
    SELECT count(*)
    FROM v2.configuracion_acciones ca
    JOIN v2.cat_acciones a
      ON a.id = ca.accion_id
    WHERE ca.vigente_desde = DATE '2026-01-01'
      AND upper(btrim(a.clave)) LIKE 'PB356%'
      AND ca.esquema_demografico_id IS NOT NULL
  ) AS configuraciones_pb_2026,

  (
    SELECT count(*)
    FROM v2.indicadores_version
    WHERE ejercicio = 2026
      AND upper(btrim(clave)) IN (
        'QC4102.2601',
        'PB3562.2601',
        'PB3562.2602',
        'PB3562.2603',
        'PB3562.2604',
        'PB3562.2605',
        'PB3563.2601',
        'PB3563.2602',
        'PB3563.2603',
        'PB3563.2604',
        'PB3563.2605',
        'PB3564.2601',
        'PB3564.2602',
        'PB3564.2603'
      )
  ) AS metas_proceso_versiones_2026,

  (
    SELECT count(*)
    FROM v2.metas_indicador m
    JOIN v2.indicadores_version iv
      ON iv.id = m.indicador_version_id
    WHERE iv.ejercicio = 2026
      AND m.alcance = 'ESTATAL'
      AND m.activo = true
      AND upper(btrim(iv.clave)) IN (
        'QC4102.2601',
        'PB3562.2601',
        'PB3562.2602',
        'PB3562.2603',
        'PB3562.2604',
        'PB3562.2605',
        'PB3563.2601',
        'PB3563.2602',
        'PB3563.2603',
        'PB3563.2604',
        'PB3563.2605',
        'PB3564.2601',
        'PB3564.2602',
        'PB3564.2603'
      )
  ) AS metas_anuales_2026,

  (
    SELECT count(*)
    FROM v2.accion_indicador ai
    JOIN v2.indicadores_version iv
      ON iv.id = ai.indicador_version_id
    WHERE iv.ejercicio = 2026
      AND ai.regla_aporte = 'UNO_POR_REGISTRO'
      AND ai.activo = true
      AND upper(btrim(iv.clave)) LIKE 'PB356%'
  ) AS reglas_pb_automaticas,

  (
    SELECT count(*)
    FROM v2.accion_indicador ai
    JOIN v2.indicadores_version iv
      ON iv.id = ai.indicador_version_id
    WHERE iv.ejercicio = 2026
      AND upper(btrim(iv.clave)) = 'QC4102.2601'
      AND ai.activo = true
  ) AS reglas_qc4102_automaticas,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.09e'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO:
--
-- configs_2025_cerradas             = 12
-- tipos_2026_agregados              = 2
-- programas_bibliotecas_2026        = 3
-- acciones_cdcm_2026                = 9
-- acciones_bibliotecas_2026         = 4
-- configuraciones_pb_2026           = 13
-- metas_proceso_versiones_2026      = 14
-- metas_anuales_2026                = 14
-- reglas_pb_automaticas             = 13
-- reglas_qc4102_automaticas         = 0   <-- INTENCIONAL
-- migracion_registrada              = 1
--
-- Es decir:
--
--   12 | 2 | 3 | 9 | 4 | 13 | 14 | 14 | 13 | 0 | 1
--
-- SIGUIENTE PASO:
--
--   10_legacy_migration_preflight.sql
--
-- Antes de insertar los 317 registros V1:
--   1. clasificar cada fila contra acciones V2,
--   2. normalizar municipios/aliases,
--   3. detectar el folio duplicado,
--   4. identificar los 186 beneficiarios artificiales = 1,
--   5. clasificar evidencias URL/path,
--   6. producir un resumen DRY-RUN,
--   7. migrar SOLO después de revisar ese resumen.
--
-- NO se hará INSERT directo de los históricos sin ese preflight.
-- ============================================================================
