-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 08_views_rpc.sql
-- Vistas operativas, calidad, indicadores y RPC de dashboard
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   02_catalogs.sql
--   03_operation_modules.sql
--   04_indicators.sql
--   05_functions_triggers.sql
--   06_rls.sql
--   07_storage.sql
--
-- CREA:
--   v2.vw_registros_operativos
--   v2.vw_pendientes_validacion
--   v2.vw_calidad_datos
--   v2.vw_resumen_municipios
--   v2.vw_resumen_unidades
--   v2.vw_aportes_indicadores
--   v2.vw_avance_indicadores
--
--   v2.rpc_dashboard_resumen(...)
--
-- SEGURIDAD:
--   Todas las vistas usan security_invoker=true.
--   Eso obliga a respetar RLS y permisos del usuario que consulta.
--
--   La RPC es SECURITY INVOKER, no SECURITY DEFINER.
--
-- NO HACE:
--   ✗ no modifica V1
--   ✗ no expone todavía el schema v2 en la Data API
--   ✗ no carga catálogos
--   ✗ no migra históricos
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '180s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.cat_municipios') IS NULL
     OR to_regclass('v2.cat_unidades_operativas') IS NULL
     OR to_regclass('v2.accion_indicador') IS NULL
     OR to_regclass('v2.metas_indicador') IS NULL THEN

    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos requeridos de 01-07.';
  END IF;
END
$$;


-- ============================================================================
-- 01. VISTA OPERATIVA ENRIQUECIDA
-- ============================================================================

CREATE OR REPLACE VIEW v2.vw_registros_operativos
WITH (security_invoker = true)
AS
SELECT
  r.id,
  r.folio,

  r.unidad_operativa_id,
  u.clave                    AS unidad_clave,
  u.nombre                   AS unidad_nombre,

  r.programa_id,
  p.clave                    AS programa_clave,
  p.nombre                   AS programa_nombre,

  r.accion_id,
  a.clave                    AS accion_clave,
  a.nombre                   AS accion_nombre,

  r.tipo_registro_id,
  tr.clave                   AS tipo_registro_clave,
  tr.nombre                  AS tipo_registro_nombre,

  r.municipio_id,
  m.clave_inegi,
  m.nombre_oficial           AS municipio_nombre,

  m.region_id,
  rg.clave                   AS region_clave,
  rg.nombre                  AS region_nombre,

  r.comunidad_id,
  c.nombre                   AS comunidad_nombre,

  r.espacio_id,
  e.nombre                   AS espacio_nombre,

  r.responsable_id,

  r.nombre,
  r.descripcion,
  r.fecha_inicio,
  r.fecha_fin,
  r.periodo_anio,
  r.periodo_mes,
  r.total_beneficiarios,
  r.estatus,
  r.origen,

  r.created_by,
  r.updated_by,
  r.created_at,
  r.updated_at,
  r.row_version,

  r.legacy_folio,
  r.import_job_id

FROM v2.registros r

LEFT JOIN v2.cat_unidades_operativas u
  ON u.id = r.unidad_operativa_id

LEFT JOIN v2.cat_programas p
  ON p.id = r.programa_id

LEFT JOIN v2.cat_acciones a
  ON a.id = r.accion_id

LEFT JOIN v2.cat_tipos_registro tr
  ON tr.id = r.tipo_registro_id

LEFT JOIN v2.cat_municipios m
  ON m.id = r.municipio_id

LEFT JOIN v2.cat_regiones rg
  ON rg.id = m.region_id

LEFT JOIN v2.cat_comunidades c
  ON c.id = r.comunidad_id

LEFT JOIN v2.cat_espacios e
  ON e.id = r.espacio_id

WHERE r.deleted_at IS NULL;


COMMENT ON VIEW v2.vw_registros_operativos IS
'Vista enriquecida de registros activos. Respeta el RLS del usuario mediante security_invoker.';


-- ============================================================================
-- 02. PENDIENTES DE VALIDACIÓN
-- ============================================================================

CREATE OR REPLACE VIEW v2.vw_pendientes_validacion
WITH (security_invoker = true)
AS
SELECT
  vo.*,

  (
    CURRENT_DATE - vo.updated_at::DATE
  )::INTEGER AS dias_sin_movimiento,

  CASE vo.estatus
    WHEN 'CAPTURADO'   THEN 'PENDIENTE_REVISION'
    WHEN 'EN_REVISION' THEN 'PENDIENTE_DECISION'
    WHEN 'OBSERVADO'   THEN 'PENDIENTE_CORRECCION'
    WHEN 'CORREGIDO'   THEN 'PENDIENTE_RE_REVISION'
    ELSE 'OTRO'
  END AS tipo_pendiente

FROM v2.vw_registros_operativos vo
WHERE vo.estatus IN (
  'CAPTURADO',
  'EN_REVISION',
  'OBSERVADO',
  'CORREGIDO'
);


COMMENT ON VIEW v2.vw_pendientes_validacion IS
'Registros que requieren revisión, decisión o corrección.';


-- ============================================================================
-- 03. CALIDAD DE DATOS
--
-- Genera incidencias estructurales utilizando la configuración de la acción.
-- No altera datos: solo identifica faltantes.
-- ============================================================================

CREATE OR REPLACE VIEW v2.vw_calidad_datos
WITH (security_invoker = true)
AS
WITH base AS (
  SELECT
    r.id,
    r.folio,
    r.nombre,
    r.unidad_operativa_id,
    r.municipio_id,
    r.accion_id,
    r.estatus,
    r.periodo_anio,
    r.periodo_mes,
    r.created_at,
    r.updated_at,

    ARRAY_REMOVE(
      ARRAY[
        CASE
          WHEN r.folio IS NULL OR btrim(r.folio) = ''
          THEN 'SIN_FOLIO'
        END,

        CASE
          WHEN r.configuracion_accion_id IS NULL
          THEN 'SIN_CONFIGURACION_ACCION'
        END,

        CASE
          WHEN ca.requiere_municipio = true
               AND r.municipio_id IS NULL
          THEN 'SIN_MUNICIPIO'
        END,

        CASE
          WHEN ca.requiere_comunidad = true
               AND r.comunidad_id IS NULL
          THEN 'SIN_COMUNIDAD'
        END,

        CASE
          WHEN ca.requiere_espacio = true
               AND r.espacio_id IS NULL
          THEN 'SIN_ESPACIO'
        END,

        CASE
          WHEN ca.requiere_responsable = true
               AND r.responsable_id IS NULL
          THEN 'SIN_RESPONSABLE'
        END,

        CASE
          WHEN ca.requiere_beneficiarios = true
               AND r.total_beneficiarios IS NULL
          THEN 'SIN_TOTAL_BENEFICIARIOS'
        END,

        CASE
          WHEN ca.requiere_demografia = true
               AND NOT EXISTS (
                 SELECT 1
                 FROM v2.registro_poblacion rp
                 WHERE rp.registro_id = r.id
               )
          THEN 'SIN_DEMOGRAFIA'
        END,

        CASE
          WHEN ca.requiere_evidencia = true
               AND NOT EXISTS (
                 SELECT 1
                 FROM v2.registro_evidencias re
                 WHERE re.registro_id = r.id
                   AND re.activo = true
               )
          THEN 'SIN_EVIDENCIA'
        END

      ],
      NULL
    )::TEXT[] AS incidencias

  FROM v2.registros r

  LEFT JOIN v2.configuracion_acciones ca
    ON ca.id = r.configuracion_accion_id

  WHERE r.deleted_at IS NULL
)
SELECT
  b.*,
  COALESCE(cardinality(b.incidencias), 0) AS total_incidencias,
  (
    COALESCE(cardinality(b.incidencias), 0) = 0
  ) AS datos_completos
FROM base b;


COMMENT ON VIEW v2.vw_calidad_datos IS
'Incidencias de completitud de cada registro de acuerdo con la configuración de su acción.';


-- ============================================================================
-- 04. RESUMEN TERRITORIAL POR MUNICIPIO
--
-- Considera:
--   - municipio principal del registro
--   - territorios adicionales
--
-- Para evitar duplicar el total general:
--   - el total_beneficiarios se atribuye al municipio principal
--   - territorios adicionales solo suman beneficiarios si se capturó
--     explícitamente registro_territorios.beneficiarios.
-- ============================================================================

CREATE OR REPLACE VIEW v2.vw_resumen_municipios
WITH (security_invoker = true)
AS
WITH cobertura AS (

  SELECT
    r.id                    AS registro_id,
    r.municipio_id,
    r.estatus,
    r.periodo_anio,
    r.unidad_operativa_id,
    r.total_beneficiarios   AS beneficiarios_atribuidos

  FROM v2.registros r
  WHERE r.deleted_at IS NULL
    AND r.municipio_id IS NOT NULL

  UNION ALL

  SELECT
    rt.registro_id,
    rt.municipio_id,
    r.estatus,
    r.periodo_anio,
    r.unidad_operativa_id,
    rt.beneficiarios        AS beneficiarios_atribuidos

  FROM v2.registro_territorios rt

  JOIN v2.registros r
    ON r.id = rt.registro_id

  WHERE r.deleted_at IS NULL
    AND (
      r.municipio_id IS NULL
      OR rt.municipio_id IS DISTINCT FROM r.municipio_id
    )
)
SELECT
  c.municipio_id,
  m.clave_inegi,
  m.nombre_oficial AS municipio_nombre,
  m.region_id,
  rg.nombre        AS region_nombre,

  c.periodo_anio,
  c.unidad_operativa_id,
  u.nombre         AS unidad_nombre,

  COUNT(DISTINCT c.registro_id) AS total_registros,

  COUNT(DISTINCT c.registro_id)
    FILTER (WHERE c.estatus = 'VALIDADO')
    AS registros_validados,

  COUNT(DISTINCT c.registro_id)
    FILTER (
      WHERE c.estatus IN (
        'CAPTURADO',
        'EN_REVISION',
        'OBSERVADO',
        'CORREGIDO'
      )
    )
    AS registros_pendientes,

  COALESCE(
    SUM(c.beneficiarios_atribuidos),
    0
  )::BIGINT AS beneficiarios_atribuidos

FROM cobertura c

JOIN v2.cat_municipios m
  ON m.id = c.municipio_id

LEFT JOIN v2.cat_regiones rg
  ON rg.id = m.region_id

LEFT JOIN v2.cat_unidades_operativas u
  ON u.id = c.unidad_operativa_id

GROUP BY
  c.municipio_id,
  m.clave_inegi,
  m.nombre_oficial,
  m.region_id,
  rg.nombre,
  c.periodo_anio,
  c.unidad_operativa_id,
  u.nombre;


COMMENT ON VIEW v2.vw_resumen_municipios IS
'Resumen territorial por municipio, ejercicio y unidad operativa.';


-- ============================================================================
-- 05. RESUMEN POR UNIDAD OPERATIVA
-- ============================================================================

CREATE OR REPLACE VIEW v2.vw_resumen_unidades
WITH (security_invoker = true)
AS
SELECT
  r.unidad_operativa_id,
  u.clave               AS unidad_clave,
  u.nombre              AS unidad_nombre,
  r.periodo_anio,

  COUNT(*) AS total_registros,

  COUNT(*)
    FILTER (WHERE r.estatus = 'BORRADOR')
    AS borradores,

  COUNT(*)
    FILTER (
      WHERE r.estatus IN (
        'CAPTURADO',
        'EN_REVISION',
        'OBSERVADO',
        'CORREGIDO'
      )
    )
    AS pendientes,

  COUNT(*)
    FILTER (WHERE r.estatus = 'VALIDADO')
    AS validados,

  COUNT(*)
    FILTER (WHERE r.estatus = 'ANULADO')
    AS anulados,

  COALESCE(
    SUM(r.total_beneficiarios)
      FILTER (WHERE r.estatus <> 'ANULADO'),
    0
  )::BIGINT AS total_beneficiarios

FROM v2.registros r

LEFT JOIN v2.cat_unidades_operativas u
  ON u.id = r.unidad_operativa_id

WHERE r.deleted_at IS NULL

GROUP BY
  r.unidad_operativa_id,
  u.clave,
  u.nombre,
  r.periodo_anio;


COMMENT ON VIEW v2.vw_resumen_unidades IS
'Resumen de operación por unidad y ejercicio.';


-- ============================================================================
-- 06. APORTES A INDICADORES
--
-- Automáticos:
--   UNO_POR_REGISTRO
--   TOTAL_BENEFICIARIOS
--
-- Pendientes de módulo futuro:
--   VALOR_METRICA
--
-- Manuales:
--   registro_indicador_aportes cuando están validados.
-- ============================================================================

CREATE OR REPLACE VIEW v2.vw_aportes_indicadores
WITH (security_invoker = true)
AS
WITH automaticos AS (
  SELECT
    r.id                    AS registro_id,
    r.folio,
    r.periodo_anio,
    r.unidad_operativa_id,
    r.municipio_id,
    r.estatus,

    ai.indicador_version_id,

    'AUTOMATICO'::TEXT      AS fuente,
    ai.regla_aporte,

    CASE ai.regla_aporte

      WHEN 'UNO_POR_REGISTRO'
        THEN ai.factor

      WHEN 'TOTAL_BENEFICIARIOS'
        THEN
          CASE
            WHEN r.total_beneficiarios IS NULL THEN NULL
            ELSE r.total_beneficiarios * ai.factor
          END

      WHEN 'VALOR_METRICA'
        THEN NULL

      WHEN 'VALOR_MANUAL_VALIDADO'
        THEN NULL

      ELSE NULL
    END::NUMERIC(18,4) AS valor,

    CASE
      WHEN ai.regla_aporte IN (
        'UNO_POR_REGISTRO',
        'TOTAL_BENEFICIARIOS'
      )
      THEN true
      ELSE false
    END AS calculable_automaticamente

  FROM v2.registros r

  JOIN v2.accion_indicador ai
    ON ai.accion_id = r.accion_id
   AND ai.activo = true

  JOIN v2.indicadores_version iv
    ON iv.id = ai.indicador_version_id
   AND iv.activo = true
   AND iv.ejercicio = r.periodo_anio

  WHERE r.deleted_at IS NULL

    AND (
      ai.requiere_validado = false
      OR r.estatus = 'VALIDADO'
    )

    -- La regla manual se obtiene de la tabla de aportes explícitos.
    AND ai.regla_aporte <> 'VALOR_MANUAL_VALIDADO'
),

manuales AS (
  SELECT
    r.id                    AS registro_id,
    r.folio,
    r.periodo_anio,
    r.unidad_operativa_id,
    r.municipio_id,
    r.estatus,

    ria.indicador_version_id,

    ria.fuente,
    'VALOR_MANUAL_VALIDADO'::TEXT AS regla_aporte,

    ria.valor::NUMERIC(18,4) AS valor,

    false AS calculable_automaticamente

  FROM v2.registro_indicador_aportes ria

  JOIN v2.registros r
    ON r.id = ria.registro_id

  JOIN v2.indicadores_version iv
    ON iv.id = ria.indicador_version_id
   AND iv.activo = true
   AND iv.ejercicio = r.periodo_anio

  WHERE ria.activo = true
    AND ria.validado = true
    AND r.deleted_at IS NULL
)

SELECT * FROM automaticos
UNION ALL
SELECT * FROM manuales;


COMMENT ON VIEW v2.vw_aportes_indicadores IS
'Detalle de aportes automáticos y manuales validados a indicadores.';


-- ============================================================================
-- 07. AVANCE CONTRA META
--
-- Una fila por meta activa.
-- La atribución territorial para REGION/MUNICIPIO utiliza el municipio
-- principal del registro para evitar doble conteo institucional.
-- ============================================================================

CREATE OR REPLACE VIEW v2.vw_avance_indicadores
WITH (security_invoker = true)
AS
WITH avances AS (
  SELECT
    m.id                    AS meta_id,
    m.indicador_version_id,
    m.alcance,
    m.unidad_operativa_id,
    m.region_id,
    m.municipio_id,
    m.meta,

    COALESCE(
      SUM(a.valor) FILTER (
        WHERE
          CASE m.alcance

            WHEN 'ESTATAL'
              THEN true

            WHEN 'UNIDAD'
              THEN r.unidad_operativa_id = m.unidad_operativa_id

            WHEN 'REGION'
              THEN mun.region_id = m.region_id

            WHEN 'MUNICIPIO'
              THEN r.municipio_id = m.municipio_id

            ELSE false
          END
      ),
      0
    )::NUMERIC(18,4) AS avance

  FROM v2.metas_indicador m

  JOIN v2.indicadores_version iv
    ON iv.id = m.indicador_version_id
   AND iv.activo = true

  LEFT JOIN v2.vw_aportes_indicadores a
    ON a.indicador_version_id = m.indicador_version_id

  LEFT JOIN v2.registros r
    ON r.id = a.registro_id

  LEFT JOIN v2.cat_municipios mun
    ON mun.id = r.municipio_id

  WHERE m.activo = true

  GROUP BY
    m.id,
    m.indicador_version_id,
    m.alcance,
    m.unidad_operativa_id,
    m.region_id,
    m.municipio_id,
    m.meta
)
SELECT
  av.meta_id,

  iv.indicador_id,
  ci.clave_interna,
  ci.nombre_base,

  av.indicador_version_id,
  iv.ejercicio,
  iv.clave                  AS indicador_clave,
  iv.nombre                 AS indicador_nombre,
  iv.periodicidad,
  iv.sentido,

  um.clave                  AS unidad_medida_clave,
  um.nombre                 AS unidad_medida_nombre,
  um.simbolo                AS unidad_medida_simbolo,

  av.alcance,
  av.unidad_operativa_id,
  u.nombre                  AS alcance_unidad_nombre,
  av.region_id,
  rg.nombre                 AS alcance_region_nombre,
  av.municipio_id,
  m.nombre_oficial          AS alcance_municipio_nombre,

  av.meta,
  av.avance,

  CASE
    WHEN av.meta = 0 THEN NULL
    ELSE ROUND(
      (av.avance / av.meta) * 100,
      2
    )
  END AS cumplimiento_pct,

  GREATEST(
    av.meta - av.avance,
    0
  )::NUMERIC(18,4) AS pendiente_meta

FROM avances av

JOIN v2.indicadores_version iv
  ON iv.id = av.indicador_version_id

JOIN v2.cat_indicadores ci
  ON ci.id = iv.indicador_id

JOIN v2.cat_unidades_medida um
  ON um.id = iv.unidad_medida_id

LEFT JOIN v2.cat_unidades_operativas u
  ON u.id = av.unidad_operativa_id

LEFT JOIN v2.cat_regiones rg
  ON rg.id = av.region_id

LEFT JOIN v2.cat_municipios m
  ON m.id = av.municipio_id;


COMMENT ON VIEW v2.vw_avance_indicadores IS
'Avance visible por el usuario contra cada meta activa de indicadores versionados.';


-- ============================================================================
-- 08. RPC DE RESUMEN DEL DASHBOARD
--
-- SECURITY INVOKER:
--   RLS se aplica automáticamente.
--
-- p_anio NULL:
--   usa el ejercicio actual.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_dashboard_resumen(
  p_anio INTEGER DEFAULT NULL,
  p_unidad UUID DEFAULT NULL,
  p_municipio UUID DEFAULT NULL
)
RETURNS TABLE (
  ejercicio                 INTEGER,
  total_registros           BIGINT,
  borradores                BIGINT,
  pendientes_revision       BIGINT,
  validados                 BIGINT,
  observados                BIGINT,
  anulados                  BIGINT,
  total_beneficiarios       BIGINT,
  municipios_con_actividad  BIGINT,
  porcentaje_validado       NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT
    COALESCE(
      p_anio,
      EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
    ) AS ejercicio,

    COUNT(*) AS total_registros,

    COUNT(*)
      FILTER (WHERE r.estatus = 'BORRADOR')
      AS borradores,

    COUNT(*)
      FILTER (
        WHERE r.estatus IN (
          'CAPTURADO',
          'EN_REVISION',
          'CORREGIDO'
        )
      )
      AS pendientes_revision,

    COUNT(*)
      FILTER (WHERE r.estatus = 'VALIDADO')
      AS validados,

    COUNT(*)
      FILTER (WHERE r.estatus = 'OBSERVADO')
      AS observados,

    COUNT(*)
      FILTER (WHERE r.estatus = 'ANULADO')
      AS anulados,

    COALESCE(
      SUM(r.total_beneficiarios)
        FILTER (WHERE r.estatus <> 'ANULADO'),
      0
    )::BIGINT AS total_beneficiarios,

    COUNT(DISTINCT r.municipio_id)
      FILTER (WHERE r.municipio_id IS NOT NULL)
      AS municipios_con_actividad,

    CASE
      WHEN COUNT(*) = 0 THEN 0::NUMERIC
      ELSE ROUND(
        (
          COUNT(*) FILTER (WHERE r.estatus = 'VALIDADO')
        )::NUMERIC
        / COUNT(*)::NUMERIC
        * 100,
        2
      )
    END AS porcentaje_validado

  FROM v2.registros r

  WHERE r.deleted_at IS NULL

    AND r.periodo_anio = COALESCE(
      p_anio,
      EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
    )

    AND (
      p_unidad IS NULL
      OR r.unidad_operativa_id = p_unidad
    )

    AND (
      p_municipio IS NULL
      OR r.municipio_id = p_municipio
    )
$$;


COMMENT ON FUNCTION v2.rpc_dashboard_resumen(INTEGER, UUID, UUID) IS
'Resumen operativo del dashboard respetando RLS del usuario autenticado.';


-- ============================================================================
-- 09. PERMISOS DE VISTAS Y RPC
-- ============================================================================

REVOKE ALL ON
  v2.vw_registros_operativos,
  v2.vw_pendientes_validacion,
  v2.vw_calidad_datos,
  v2.vw_resumen_municipios,
  v2.vw_resumen_unidades,
  v2.vw_aportes_indicadores,
  v2.vw_avance_indicadores
FROM PUBLIC, anon;

GRANT SELECT ON
  v2.vw_registros_operativos,
  v2.vw_pendientes_validacion,
  v2.vw_calidad_datos,
  v2.vw_resumen_municipios,
  v2.vw_resumen_unidades,
  v2.vw_aportes_indicadores,
  v2.vw_avance_indicadores
TO authenticated;


REVOKE ALL ON FUNCTION
  v2.rpc_dashboard_resumen(INTEGER, UUID, UUID)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  v2.rpc_dashboard_resumen(INTEGER, UUID, UUID)
TO authenticated;


-- ============================================================================
-- 10. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.08',
  '08_views_rpc.sql - Vistas operativas, calidad, territorio, indicadores y RPC de dashboard.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 11. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

WITH vistas_esperadas(nombre) AS (
  VALUES
    ('vw_registros_operativos'),
    ('vw_pendientes_validacion'),
    ('vw_calidad_datos'),
    ('vw_resumen_municipios'),
    ('vw_resumen_unidades'),
    ('vw_aportes_indicadores'),
    ('vw_avance_indicadores')
)
SELECT
  'V2.1 - 08_views_rpc' AS instalacion,

  (
    SELECT count(*)
    FROM vistas_esperadas ve
    WHERE to_regclass('v2.' || ve.nombre) IS NOT NULL
  ) AS vistas_creadas,

  (
    SELECT count(*)
    FROM vistas_esperadas ve
    JOIN pg_class c
      ON c.oid = to_regclass('v2.' || ve.nombre)
    WHERE COALESCE(c.reloptions, ARRAY[]::TEXT[])
          @> ARRAY['security_invoker=true']::TEXT[]
  ) AS vistas_security_invoker,

  (
    to_regprocedure(
      'v2.rpc_dashboard_resumen(integer,uuid,uuid)'
    ) IS NOT NULL
  ) AS rpc_dashboard_existe,

  (
    SELECT count(*)
    FROM information_schema.tables
    WHERE table_schema = 'v2'
      AND table_type = 'BASE TABLE'
  ) AS tablas_v2,

  (
    SELECT count(*)
    FROM pg_policies
    WHERE schemaname = 'v2'
      AND (
        'anon' = ANY (roles)
        OR 'public' = ANY (roles)
      )
  ) AS policies_v2_anon_public,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.08'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO:
--
-- vistas_creadas               = 7
-- vistas_security_invoker      = 7
-- rpc_dashboard_existe         = true
-- tablas_v2                    = 44
-- policies_v2_anon_public      = 0
-- migracion_registrada         = 1
--
-- En este punto la arquitectura base queda:
--
--   01 Core             ✓
--   02 Catálogos        ✓
--   03 Operación        ✓
--   04 Indicadores      ✓
--   05 Automatización   ✓
--   06 Seguridad/RLS    ✓
--   07 Storage          ✓
--   08 Vistas/RPC       ✓
--
-- Próximo archivo:
--   09_seed_base.sql
--
-- Ahí empezaremos a CARGAR información real:
--   - unidades operativas
--   - tipos de registro
--   - tipos de espacio
--   - funciones de personas
--   - dimensiones/opciones de población
--   - unidades de medida
--   - aliases históricos conocidos
--
-- Los municipios oficiales y regiones se cargarán de forma controlada,
-- evitando volver a introducir variantes históricas como texto libre.
-- ============================================================================
