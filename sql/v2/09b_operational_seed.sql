-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 09b_operational_seed.sql
-- Semilla operativa CDCM basada en archivos institucionales 2025
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   02_catalogs.sql
--   03_operation_modules.sql
--   04_indicators.sql
--   05_functions_triggers.sql + hotfix 05a
--   06_rls.sql
--   07_storage.sql
--   08_views_rpc.sql
--   09_seed_base.sql
--
-- CARGA / AJUSTA:
--   ✓ regionalización CDCM 2025: Regiones I-IV
--   ✓ asignación de los 46 municipios a región
--   ✓ aliases adicionales observados en concentrados CDCM
--   ✓ corrección semántica de Tipo de Asentamiento
--   ✓ programas operativos CDCM
--   ✓ acciones operativas CDCM
--   ✓ configuración dinámica de formularios
--   ✓ unidades de medida adicionales
--   ✓ 5 indicadores CDCM 2025 como referencia histórica
--
-- DELIBERADAMENTE NO CARGA:
--   ✗ indicadores 2026
--   ✗ reglas accion_indicador
--   ✗ metas oficiales
--   ✗ cambios de grupos etarios/género
--
-- RAZÓN:
--   Las fuentes 2026 revisadas presentan diferencias de definición en
--   grupos etarios. No se reconcilian silenciosamente.
--
-- FUENTES OPERATIVAS PRINCIPALES:
--   - Indicadores 2025, hoja CDCM
--   - Desglose numeralia Regiones I-IV
--   - CONCENTRADOS 2025
--   - CDCM. RESUMEN POR PROYECTO
--   - Base para indicadores oficial
--
-- SEGURIDAD:
--   Script idempotente.
--   No toca V1.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '180s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.cat_municipios') IS NULL
     OR to_regclass('v2.cat_programas') IS NULL
     OR to_regclass('v2.cat_acciones') IS NULL
     OR to_regclass('v2.configuracion_acciones') IS NULL
     OR to_regclass('v2.cat_indicadores') IS NULL
     OR to_regclass('v2.indicadores_version') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos requeridos de V2.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.09'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 09_seed_base.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. CORRECCIÓN: TIPO DE ASENTAMIENTO
--
-- La fuente institucional maneja:
--   Urbano / Rural / Periurbano
--
-- Los valores Comunidad/Colonia/Localidad/etc. sembrados en 09 describen
-- clases de localidad/espacio, no el Tipo de Asentamiento institucional.
-- Como V2 aún no tiene registros productivos, se conservan pero se inactivan.
-- ============================================================================

UPDATE v2.cat_tipos_asentamiento
SET activo = false
WHERE upper(btrim(clave)) IN (
  'COMUNIDAD',
  'COLONIA',
  'LOCALIDAD',
  'BARRIO',
  'EJIDO',
  'RANCHERIA',
  'OTRO'
);


INSERT INTO v2.cat_tipos_asentamiento (
  clave,
  nombre,
  orden,
  activo
)
VALUES
  ('URBANO', 'Urbano', 10, true),
  ('RURAL', 'Rural', 20, true),
  ('PERIURBANO', 'Periurbano', 30, true)
ON CONFLICT DO NOTHING;


UPDATE v2.cat_tipos_asentamiento
SET activo = true
WHERE upper(btrim(clave)) IN (
  'URBANO',
  'RURAL',
  'PERIURBANO'
);


-- ============================================================================
-- 02. REGIONES CDCM 2025
-- ============================================================================

INSERT INTO v2.cat_regiones (
  clave,
  nombre,
  descripcion,
  orden,
  activo
)
VALUES
  (
    'RI',
    'Región I',
    'Regionalización utilizada en el desglose de numeralia CDCM 2025.',
    10,
    true
  ),
  (
    'RII',
    'Región II',
    'Regionalización utilizada en el desglose de numeralia CDCM 2025.',
    20,
    true
  ),
  (
    'RIII',
    'Región III',
    'Regionalización utilizada en el desglose de numeralia CDCM 2025.',
    30,
    true
  ),
  (
    'RIV',
    'Región IV',
    'Regionalización utilizada en el desglose de numeralia CDCM 2025.',
    40,
    true
  )
ON CONFLICT DO NOTHING;


UPDATE v2.cat_regiones r
SET
  nombre = x.nombre,
  descripcion = x.descripcion,
  orden = x.orden,
  activo = true
FROM (
  VALUES
    (
      'RI',
      'Región I',
      'Regionalización utilizada en el desglose de numeralia CDCM 2025.',
      10
    ),
    (
      'RII',
      'Región II',
      'Regionalización utilizada en el desglose de numeralia CDCM 2025.',
      20
    ),
    (
      'RIII',
      'Región III',
      'Regionalización utilizada en el desglose de numeralia CDCM 2025.',
      30
    ),
    (
      'RIV',
      'Región IV',
      'Regionalización utilizada en el desglose de numeralia CDCM 2025.',
      40
    )
) AS x(clave, nombre, descripcion, orden)
WHERE upper(btrim(r.clave)) = x.clave;


-- ============================================================================
-- 03. ASIGNACIÓN DE LOS 46 MUNICIPIOS A REGIONES CDCM
--
-- Derivada de las hojas:
--   Desglose numeralia RI
--   Desglose numeralia RII
--   Desglose numeralia RIII
--   Desglose numeralia RIV
-- ============================================================================

WITH mapa(clave_inegi, region_clave) AS (
  VALUES
    -- Región I
    ('11006', 'RI'),   -- Atarjea
    ('11013', 'RI'),   -- Doctor Mora
    ('11014', 'RI'),   -- Dolores Hidalgo C.I.N.
    ('11029', 'RI'),   -- San Diego de la Unión
    ('11032', 'RI'),   -- San José Iturbide
    ('11033', 'RI'),   -- San Luis de la Paz
    ('11003', 'RI'),   -- San Miguel de Allende
    ('11034', 'RI'),   -- Santa Catarina
    ('11040', 'RI'),   -- Tierra Blanca
    ('11043', 'RI'),   -- Victoria
    ('11045', 'RI'),   -- Xichú

    -- Región II
    ('11012', 'RII'),  -- Cuerámaro
    ('11015', 'RII'),  -- Guanajuato
    ('11020', 'RII'),  -- León
    ('11008', 'RII'),  -- Manuel Doblado
    ('11022', 'RII'),  -- Ocampo
    ('11023', 'RII'),  -- Pénjamo
    ('11025', 'RII'),  -- Purísima del Rincón
    ('11026', 'RII'),  -- Romita
    ('11030', 'RII'),  -- San Felipe
    ('11031', 'RII'),  -- San Francisco del Rincón
    ('11037', 'RII'),  -- Silao de la Victoria

    -- Región III
    ('11001', 'RIII'), -- Abasolo
    ('11007', 'RIII'), -- Celaya
    ('11009', 'RIII'), -- Comonfort
    ('11011', 'RIII'), -- Cortazar
    ('11016', 'RIII'), -- Huanímaro
    ('11017', 'RIII'), -- Irapuato
    ('11018', 'RIII'), -- Jaral del Progreso
    ('11035', 'RIII'), -- Santa Cruz de Juventino Rosas
    ('11024', 'RIII'), -- Pueblo Nuevo
    ('11027', 'RIII'), -- Salamanca
    ('11042', 'RIII'), -- Valle de Santiago
    ('11044', 'RIII'), -- Villagrán

    -- Región IV
    ('11002', 'RIV'),  -- Acámbaro
    ('11004', 'RIV'),  -- Apaseo el Alto
    ('11005', 'RIV'),  -- Apaseo el Grande
    ('11010', 'RIV'),  -- Coroneo
    ('11019', 'RIV'),  -- Jerécuaro
    ('11021', 'RIV'),  -- Moroleón
    ('11028', 'RIV'),  -- Salvatierra
    ('11036', 'RIV'),  -- Santiago Maravatío
    ('11038', 'RIV'),  -- Tarandacuao
    ('11039', 'RIV'),  -- Tarimoro
    ('11041', 'RIV'),  -- Uriangato
    ('11046', 'RIV')   -- Yuriria
)
UPDATE v2.cat_municipios m
SET region_id = r.id
FROM mapa mp
JOIN v2.cat_regiones r
  ON upper(btrim(r.clave)) = mp.region_clave
WHERE m.clave_inegi = mp.clave_inegi;


-- ============================================================================
-- 04. ALIASES ADICIONALES OBSERVADOS EN ARCHIVOS CDCM 2025
-- ============================================================================

INSERT INTO v2.cat_municipio_alias (
  municipio_id,
  alias,
  origen,
  activo
)
SELECT
  m.id,
  x.alias,
  'CDCM_2025',
  true
FROM (
  VALUES
    ('11014', 'Dolores H.'),
    ('11014', 'Dolores Hidalgo CIN'),
    ('11005', 'Apaseo el Gde'),
    ('11035', 'Juventino Rosas'),
    ('11025', 'Purísima del R'),
    ('11031', 'San Francisco del R'),
    ('11037', 'Silao'),
    ('11044', 'Villagran')
) AS x(clave_inegi, alias)
JOIN v2.cat_municipios m
  ON m.clave_inegi = x.clave_inegi
WHERE NOT EXISTS (
  SELECT 1
  FROM v2.cat_municipio_alias a
  WHERE lower(btrim(a.alias)) = lower(btrim(x.alias))
);


-- ============================================================================
-- 05. PROGRAMAS OPERATIVOS CDCM
--
-- Nombres tomados del material institucional de indicadores.
-- ============================================================================

WITH unidad AS (
  SELECT id
  FROM v2.cat_unidades_operativas
  WHERE upper(btrim(clave)) = 'CDCM'
  LIMIT 1
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
  x.clave,
  x.nombre,
  x.descripcion,
  x.orden,
  true
FROM unidad u
CROSS JOIN (
  VALUES
    (
      'INTEGRACION_NODOS',
      'Integración de nodos creativos y formativos',
      'Programa de referencia para talleres, formación y capacitación.',
      10
    ),
    (
      'COORDINACION_REDES',
      'Coordinación y vinculación de redes de mediación cultural municipal',
      'Programa de referencia para acciones colaborativas y articulación municipal.',
      20
    ),
    (
      'FORTALECIMIENTO_PARTICIPATIVO',
      'Fortalecimiento de procesos participativos municipales',
      'Programa de referencia para proyectos socioculturales y comunitarios.',
      30
    )
) AS x(clave, nombre, descripcion, orden)
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 06. ACCIONES OPERATIVAS CDCM
--
-- El catálogo distingue el tipo de acción de un nombre particular de proyecto.
-- Ejemplo:
--   Acción = Proyecto sociocultural
--   Nombre del registro = "Memorias en el corazón"
-- ============================================================================

WITH unidad AS (
  SELECT id
  FROM v2.cat_unidades_operativas
  WHERE upper(btrim(clave)) = 'CDCM'
  LIMIT 1
),
datos(
  clave,
  nombre,
  descripcion,
  programa_clave,
  orden
) AS (
  VALUES
    (
      'TALLER_CASA_CULTURA',
      'Taller en Casa de Cultura',
      'Taller presencial operado en Casa de Cultura.',
      'INTEGRACION_NODOS',
      10
    ),
    (
      'TALLER_SALON_CULTURA',
      'Taller en Salón de Cultura',
      'Taller operado en Salón de Cultura.',
      'INTEGRACION_NODOS',
      20
    ),
    (
      'TALLER_VERANO',
      'Taller o curso de verano',
      'Actividad formativa correspondiente a la programación de verano.',
      'INTEGRACION_NODOS',
      30
    ),
    (
      'CAPACITACION_PROMOTORES',
      'Capacitación a promotores culturales',
      'Capacitación dirigida a promotores, enlaces u organismos culturales municipales.',
      'INTEGRACION_NODOS',
      40
    ),
    (
      'REUNION_COLABORACION',
      'Reunión de trabajo colaborativo',
      'Reunión de coordinación, colaboración o seguimiento.',
      'COORDINACION_REDES',
      50
    ),
    (
      'ACTIVIDAD_PROYECTO_CIRCUITO',
      'Proyecto de circuito cultural',
      'Proyecto o conjunto de actividades articuladas mediante circuito cultural.',
      'COORDINACION_REDES',
      60
    ),
    (
      'ACTIVIDAD_PROYECTO_REGIONAL',
      'Proyecto regional cultural',
      'Proyecto cultural de cobertura regional o multiterritorial.',
      'COORDINACION_REDES',
      70
    ),
    (
      'INTERCAMBIO_CULTURAL',
      'Intercambio cultural',
      'Intercambio cultural, artístico o artesanal entre territorios.',
      'COORDINACION_REDES',
      80
    ),
    (
      'ARTICULACION_INTER_INTRA',
      'Articulación inter e intramunicipal',
      'Acción de articulación entre actores, territorios o instituciones.',
      'COORDINACION_REDES',
      90
    ),
    (
      'PROYECTO_SOCIOCULTURAL',
      'Proyecto sociocultural',
      'Proyecto sociocultural desarrollado en barrios, colonias, periferias o comunidades.',
      'FORTALECIMIENTO_PARTICIPATIVO',
      100
    ),
    (
      'EXPOSICION_MUESTRA',
      'Exposición, muestra o exhibición',
      'Exposición, muestra o exhibición cultural.',
      NULL,
      110
    ),
    (
      'EVENTO_MUNICIPAL',
      'Evento municipal en espacio público',
      'Evento cultural municipal desarrollado en espacio público.',
      NULL,
      120
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
  d.clave,
  d.nombre,
  d.descripcion,
  d.orden,
  true
FROM datos d
CROSS JOIN unidad u
LEFT JOIN v2.cat_programas p
  ON p.unidad_operativa_id = u.id
 AND upper(btrim(p.clave)) = d.programa_clave
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 07. CONFIGURACIÓN DINÁMICA DE FORMULARIOS
--
-- No se exige GPS por defecto.
-- Evidencia y validación sí son institucionales.
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
  req_beneficiarios,
  req_demografia,
  req_gps,
  req_evidencia,
  req_validacion,
  permite_offline
) AS (
  VALUES
    ('TALLER_CASA_CULTURA',       'TALLER',                 'TALLER',       true, false, true,  true,  true,  true, true, false, true, true, true),
    ('TALLER_SALON_CULTURA',      'TALLER',                 'TALLER',       true, false, true,  true,  true,  true, true, false, true, true, true),
    ('TALLER_VERANO',             'CURSO_VERANO',           'TALLER',       true, false, true,  true,  true,  true, true, false, true, true, true),
    ('CAPACITACION_PROMOTORES',   'CAPACITACION',           'CAPACITACION', true, false, true,  true,  false, true, true, false, true, true, true),
    ('REUNION_COLABORACION',      'REUNION',                'REUNION',      true, false, false, true,  false, true, true, false, true, true, true),
    ('ACTIVIDAD_PROYECTO_CIRCUITO','PROYECTO_CIRCUITO',     'PROYECTO',     true, false, false, true,  false, true, true, false, true, true, true),
    ('ACTIVIDAD_PROYECTO_REGIONAL','PROYECTO_REGIONAL',     'PROYECTO',     false,false, false, true,  false, true, true, false, true, true, true),
    ('INTERCAMBIO_CULTURAL',      'INTERCAMBIO',            'INTERCAMBIO',  true, false, false, true,  false, true, true, false, true, true, true),
    ('ARTICULACION_INTER_INTRA',  'REUNION',                'REUNION',      true, false, false, true,  false, true, true, false, true, true, true),
    ('PROYECTO_SOCIOCULTURAL',    'PROYECTO_SOCIOCULTURAL', 'PROYECTO',     true, true,  false, true,  false, true, true, false, true, true, true),
    ('EXPOSICION_MUESTRA',        'EXPOSICION',             'EVENTO',       true, false, true,  true,  false, true, true, false, true, true, true),
    ('EVENTO_MUNICIPAL',          'EVENTO',                 'EVENTO',       true, false, false, true,  false, true, true, false, true, true, true)
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
  configuracion_extra,
  activo
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
  d.req_beneficiarios,
  d.req_demografia,
  d.req_gps,
  d.req_evidencia,
  d.req_validacion,
  d.permite_offline,
  DATE '2025-01-01',
  pg_catalog.jsonb_build_object(
    'fuente', 'CDCM 2025',
    'seed', '09b_operational_seed'
  ),
  true
FROM datos d
JOIN v2.cat_acciones a
  ON upper(btrim(a.clave)) = d.accion_clave
JOIN v2.cat_tipos_registro tr
  ON upper(btrim(tr.clave)) = d.tipo_registro_clave

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
  configuracion_extra = EXCLUDED.configuracion_extra,
  activo = true;


-- ============================================================================
-- 08. UNIDADES DE MEDIDA ADICIONALES PARA INDICADORES 2025
-- ============================================================================

INSERT INTO v2.cat_unidades_medida (
  clave,
  nombre,
  simbolo,
  tipo_dato,
  activo
)
VALUES
  ('JOVEN', 'Joven', NULL, 'ENTERO', true),
  ('PARTICIPANTE', 'Participante', NULL, 'ENTERO', true),
  ('ESQUEMA', 'Esquema', NULL, 'ENTERO', true),
  ('ESPACIO', 'Espacio', NULL, 'ENTERO', true)
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 09. CATÁLOGO CONCEPTUAL DE INDICADORES CDCM 2025
-- ============================================================================

WITH unidad AS (
  SELECT id
  FROM v2.cat_unidades_operativas
  WHERE upper(btrim(clave)) = 'CDCM'
  LIMIT 1
)
INSERT INTO v2.cat_indicadores (
  clave_interna,
  nombre_base,
  descripcion,
  unidad_operativa_id,
  activo
)
SELECT
  x.clave,
  x.nombre,
  x.descripcion,
  u.id,
  true
FROM unidad u
CROSS JOIN (
  VALUES
    (
      'I10465',
      'Número de acciones para la creación, producción y difusión artística desarrolladas para la población en condición de vulnerabilidad',
      'Indicador CDCM observado en la hoja Indicadores 2025.'
    ),
    (
      'I10689',
      'Jóvenes participantes en actividades en el desarrollo de su entorno',
      'Indicador CDCM observado en la hoja Indicadores 2025.'
    ),
    (
      'I12430',
      'Tasa de esquemas de formación, investigación, experimentación, desarrollo artístico y cultural',
      'La fuente incluye la instrucción: reportar los esquemas por escrito; no en cantidad.'
    ),
    (
      'I12431',
      'Tasa de variación anual de participantes en los esquemas de formación, investigación, experimentación, desarrollo artístico y cultural',
      'Indicador CDCM observado en la hoja Indicadores 2025.'
    ),
    (
      'I09194',
      'Espacios utilizados en actividades artísticas y culturales promovidas por el gobierno de Estado',
      'Indicador CDCM observado en la hoja Indicadores 2025.'
    )
) AS x(clave, nombre, descripcion)
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 10. VERSIONES 2025
--
-- Se guardan los totales del archivo como METADATA DE REFERENCIA,
-- no como cálculo V2 ni como meta oficial.
-- ============================================================================

WITH datos(
  clave,
  nombre,
  unidad_clave,
  desglose,
  total_reportado,
  proyeccion_reportada
) AS (
  VALUES
    (
      'I10465',
      'Número de acciones para la creación, producción y difusión artística desarrolladas para la población en condición de vulnerabilidad',
      'ACCION',
      'Actividades generadas por circuitos y regiones en colaboración: reuniones, actividades de proyecto de circuito y/o regional, intercambios culturales, articulación y proyectos socioculturales.',
      752::NUMERIC,
      NULL::NUMERIC
    ),
    (
      'I10689',
      'Jóvenes participantes en actividades en el desarrollo de su entorno',
      'JOVEN',
      'Jóvenes asistentes a actividades de los OCM.',
      796636::NUMERIC,
      NULL::NUMERIC
    ),
    (
      'I12430',
      'Tasa de esquemas de formación, investigación, experimentación, desarrollo artístico y cultural',
      'ESQUEMA',
      'Capacitaciones a promotores culturales y esquemas reportados por las coordinaciones.',
      226::NUMERIC,
      NULL::NUMERIC
    ),
    (
      'I12431',
      'Tasa de variación anual de participantes en los esquemas de formación, investigación, experimentación, desarrollo artístico y cultural',
      'PARTICIPANTE',
      'Participantes en capacitaciones y esquemas de formación reportados por CDCM.',
      27031::NUMERIC,
      NULL::NUMERIC
    ),
    (
      'I09194',
      'Espacios utilizados en actividades artísticas y culturales promovidas por el gobierno de Estado',
      'ESPACIO',
      'Plazas públicas de los municipios.',
      43::NUMERIC,
      46::NUMERIC
    )
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
  2025,
  d.clave,
  d.nombre,
  'Versión histórica CDCM 2025 cargada como referencia para validación de migración.',
  um.id,
  'MENSUAL',
  'ASCENDENTE',
  'Indicadores 2025 - hoja CDCM',
  NULL,
  d.desglose,
  DATE '2025-01-01',
  DATE '2025-12-31',
  true,
  pg_catalog.jsonb_build_object(
    'total_reportado_fuente', d.total_reportado,
    'proyeccion_reportada_fuente', d.proyeccion_reportada,
    'es_referencia_historica', true
  )
FROM datos d
JOIN v2.cat_indicadores i
  ON upper(btrim(i.clave_interna)) = d.clave
JOIN v2.cat_unidades_medida um
  ON upper(btrim(um.clave)) = d.unidad_clave

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
-- 11. IMPORTANTE: NO CREAR action_indicador TODAVÍA
--
-- Razones:
--   I10465 agrega varias clases de acciones.
--   I10689 requiere sumar específicamente la opción poblacional Juventudes.
--   I12430 habla de esquemas, no necesariamente de registros.
--   I09194 requiere contar espacios distintos, no registros.
--
-- Las cuatro reglas requieren ampliar el motor de indicadores antes de
-- automatizarlas sin producir resultados falsos.
-- ============================================================================


-- ============================================================================
-- 12. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.09b',
  '09b_operational_seed.sql - Regionalización CDCM 2025, programas, acciones, configuración e indicadores históricos.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 13. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

SELECT
  'V2.1 - 09b_operational_seed' AS instalacion,

  (
    SELECT count(*)
    FROM v2.cat_regiones
    WHERE upper(btrim(clave)) IN (
      'RI', 'RII', 'RIII', 'RIV'
    )
      AND activo = true
  ) AS regiones_cdcm,

  (
    SELECT count(*)
    FROM v2.cat_municipios m
    JOIN v2.cat_regiones r
      ON r.id = m.region_id
    WHERE upper(btrim(r.clave)) IN (
      'RI', 'RII', 'RIII', 'RIV'
    )
  ) AS municipios_con_region,

  (
    SELECT count(*)
    FROM v2.cat_tipos_asentamiento
    WHERE upper(btrim(clave)) IN (
      'URBANO', 'RURAL', 'PERIURBANO'
    )
      AND activo = true
  ) AS tipos_asentamiento_activos,

  (
    SELECT count(*)
    FROM v2.cat_municipio_alias
    WHERE origen = 'CDCM_2025'
  ) AS aliases_cdcm_2025,

  (
    SELECT count(*)
    FROM v2.cat_programas p
    JOIN v2.cat_unidades_operativas u
      ON u.id = p.unidad_operativa_id
    WHERE upper(btrim(u.clave)) = 'CDCM'
      AND upper(btrim(p.clave)) IN (
        'INTEGRACION_NODOS',
        'COORDINACION_REDES',
        'FORTALECIMIENTO_PARTICIPATIVO'
      )
  ) AS programas_cdcm,

  (
    SELECT count(*)
    FROM v2.cat_acciones a
    JOIN v2.cat_unidades_operativas u
      ON u.id = a.unidad_operativa_id
    WHERE upper(btrim(u.clave)) = 'CDCM'
      AND upper(btrim(a.clave)) IN (
        'TALLER_CASA_CULTURA',
        'TALLER_SALON_CULTURA',
        'TALLER_VERANO',
        'CAPACITACION_PROMOTORES',
        'REUNION_COLABORACION',
        'ACTIVIDAD_PROYECTO_CIRCUITO',
        'ACTIVIDAD_PROYECTO_REGIONAL',
        'INTERCAMBIO_CULTURAL',
        'ARTICULACION_INTER_INTRA',
        'PROYECTO_SOCIOCULTURAL',
        'EXPOSICION_MUESTRA',
        'EVENTO_MUNICIPAL'
      )
  ) AS acciones_cdcm,

  (
    SELECT count(*)
    FROM v2.configuracion_acciones ca
    JOIN v2.cat_acciones a
      ON a.id = ca.accion_id
    JOIN v2.cat_unidades_operativas u
      ON u.id = a.unidad_operativa_id
    WHERE upper(btrim(u.clave)) = 'CDCM'
      AND ca.vigente_desde = DATE '2025-01-01'
  ) AS configuraciones_cdcm,

  (
    SELECT count(*)
    FROM v2.indicadores_version iv
    JOIN v2.cat_indicadores i
      ON i.id = iv.indicador_id
    JOIN v2.cat_unidades_operativas u
      ON u.id = i.unidad_operativa_id
    WHERE upper(btrim(u.clave)) = 'CDCM'
      AND iv.ejercicio = 2025
      AND upper(btrim(iv.clave)) IN (
        'I10465',
        'I10689',
        'I12430',
        'I12431',
        'I09194'
      )
  ) AS indicadores_cdcm_2025,

  (
    SELECT count(*)
    FROM v2.accion_indicador ai
    JOIN v2.indicadores_version iv
      ON iv.id = ai.indicador_version_id
    WHERE iv.ejercicio = 2025
  ) AS reglas_automaticas_2025,

  (
    SELECT count(*)
    FROM v2.indicadores_version
    WHERE ejercicio = 2026
  ) AS versiones_2026,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.09b'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO:
--
-- regiones_cdcm                 = 4
-- municipios_con_region         = 46
-- tipos_asentamiento_activos    = 3
-- aliases_cdcm_2025             = 8
-- programas_cdcm                = 3
-- acciones_cdcm                 = 12
-- configuraciones_cdcm          = 12
-- indicadores_cdcm_2025         = 5
-- reglas_automaticas_2025       = 0   <-- INTENCIONAL
-- versiones_2026                = 0   <-- INTENCIONAL
-- migracion_registrada          = 1
--
-- Es decir:
--   4 | 46 | 3 | 8 | 3 | 12 | 12 | 5 | 0 | 0 | 1
--
-- SIGUIENTE PASO:
--
--   09c_source_alignment_2026.sql
--
-- Pero 09c será primero un DIAGNÓSTICO, no un seed:
-- comparará las definiciones 2026 antes de decidir qué catálogo es oficial.
--
-- Después:
--   10_legacy_migration.sql
-- ============================================================================
