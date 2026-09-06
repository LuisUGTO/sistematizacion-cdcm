-- ============================================================================
-- VINCULACION CULTURAL V2
-- 12n_import_batch_audit.sql
-- Etapa 6.6: auditoria y flujo masivo seguro por lote de importacion
--
-- Principios:
--   - Solo ADMIN opera lotes importados desde Excel.
--   - Cada lote se identifica por import_job_id; nunca se mezclan archivos.
--   - Envio y validacion reutilizan las RPC canonicas registro por registro.
--   - Los triggers existentes conservan row_version, historial y auditoria.
--   - Se procesan como maximo 100 registros por llamada.
--   - MIGRACION_V1 queda fuera de este flujo por diseño.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.import_jobs') IS NULL
     OR to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.vw_calidad_datos') IS NULL
     OR to_regprocedure('v2.rpc_import_historial()') IS NULL
     OR to_regprocedure('v2.rpc_submit_borrador(uuid,integer)') IS NULL
     OR to_regprocedure('v2.rpc_decide_validacion(uuid,integer,text,text)') IS NULL
     OR to_regprocedure('v2_private.is_admin()') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION_FALLIDA: instale primero 12d, 12f y 12j-12m.';
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_v2_registros_import_job_status_active
  ON v2.registros (import_job_id, estatus, id)
  WHERE deleted_at IS NULL
    AND origen = 'IMPORTACION_EXCEL';


-- ============================================================================
-- 01. AUDITORIA DEL LOTE
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_import_auditar_lote(p_job_id UUID)
RETURNS TABLE (
  job_id UUID,
  archivo_nombre TEXT,
  estatus_importacion TEXT,
  filas_archivo INTEGER,
  filas_importadas INTEGER,
  filas_error INTEGER,
  filas_duplicadas INTEGER,
  registros_activos INTEGER,
  borradores_listos INTEGER,
  borradores_bloqueados INTEGER,
  revision_lista INTEGER,
  revision_bloqueada INTEGER,
  registros_validados INTEGER,
  registros_observados INTEGER,
  registros_otros INTEGER,
  sin_cifra_personas INTEGER,
  sin_sede_texto INTEGER,
  beneficiarios_reportados BIGINT,
  fecha_minima DATE,
  fecha_maxima DATE,
  meses_con_datos INTEGER,
  acciones_distintas INTEGER,
  municipios_distintos INTEGER,
  estatus_resumen JSONB,
  incidencias_resumen JSONB
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_job RECORD;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesion autenticada.';
  END IF;

  IF NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede auditar lotes.';
  END IF;

  SELECT j.*
  INTO v_job
  FROM v2.import_jobs j
  WHERE j.id = p_job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND: el lote solicitado no existe.';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      r.id,
      r.estatus,
      r.total_beneficiarios,
      r.fecha_inicio,
      r.periodo_mes,
      r.accion_id,
      r.municipio_id,
      r.metadata,
      COALESCE(q.incidencias, ARRAY[]::TEXT[]) AS incidencias
    FROM v2.registros r
    LEFT JOIN v2.vw_calidad_datos q
      ON q.id = r.id
    WHERE r.import_job_id = p_job_id
      AND r.origen = 'IMPORTACION_EXCEL'
      AND r.deleted_at IS NULL
      AND r.estatus <> 'ANULADO'
  ),
  status_json AS (
    SELECT COALESCE(
      pg_catalog.jsonb_object_agg(s.estatus, s.cantidad),
      '{}'::JSONB
    ) AS value
    FROM (
      SELECT b.estatus, count(*)::INTEGER AS cantidad
      FROM base b
      GROUP BY b.estatus
    ) s
  ),
  issue_json AS (
    SELECT COALESCE(
      pg_catalog.jsonb_object_agg(i.codigo, i.cantidad),
      '{}'::JSONB
    ) AS value
    FROM (
      SELECT issue.codigo, count(*)::INTEGER AS cantidad
      FROM base b
      CROSS JOIN LATERAL pg_catalog.unnest(b.incidencias) AS issue(codigo)
      GROUP BY issue.codigo
    ) i
  ),
  summary AS (
    SELECT
      count(*)::INTEGER AS registros_activos,
      count(*) FILTER (
        WHERE b.estatus IN ('BORRADOR', 'CORREGIDO')
          AND pg_catalog.cardinality(b.incidencias) = 0
      )::INTEGER AS borradores_listos,
      count(*) FILTER (
        WHERE b.estatus IN ('BORRADOR', 'CORREGIDO')
          AND pg_catalog.cardinality(b.incidencias) > 0
      )::INTEGER AS borradores_bloqueados,
      count(*) FILTER (
        WHERE b.estatus = 'EN_REVISION'
          AND pg_catalog.cardinality(b.incidencias) = 0
      )::INTEGER AS revision_lista,
      count(*) FILTER (
        WHERE b.estatus = 'EN_REVISION'
          AND pg_catalog.cardinality(b.incidencias) > 0
      )::INTEGER AS revision_bloqueada,
      count(*) FILTER (WHERE b.estatus = 'VALIDADO')::INTEGER
        AS registros_validados,
      count(*) FILTER (WHERE b.estatus = 'OBSERVADO')::INTEGER
        AS registros_observados,
      count(*) FILTER (
        WHERE b.estatus NOT IN (
          'BORRADOR', 'CORREGIDO', 'EN_REVISION', 'VALIDADO', 'OBSERVADO'
        )
      )::INTEGER AS registros_otros,
      count(*) FILTER (WHERE b.total_beneficiarios IS NULL)::INTEGER
        AS sin_cifra_personas,
      count(*) FILTER (
        WHERE NULLIF(
          pg_catalog.btrim(COALESCE(b.metadata #>> '{location_text,sede}', '')),
          ''
        ) IS NULL
      )::INTEGER AS sin_sede_texto,
      COALESCE(sum(b.total_beneficiarios), 0)::BIGINT
        AS beneficiarios_reportados,
      min(b.fecha_inicio) AS fecha_minima,
      max(b.fecha_inicio) AS fecha_maxima,
      count(DISTINCT b.periodo_mes)
        FILTER (WHERE b.periodo_mes IS NOT NULL)::INTEGER AS meses_con_datos,
      count(DISTINCT b.accion_id)::INTEGER AS acciones_distintas,
      count(DISTINCT b.municipio_id)
        FILTER (WHERE b.municipio_id IS NOT NULL)::INTEGER
        AS municipios_distintos
    FROM base b
  )
  SELECT
    v_job.id,
    v_job.archivo_nombre,
    v_job.estatus,
    v_job.total_filas,
    v_job.filas_importadas,
    v_job.filas_error,
    v_job.filas_duplicadas,
    summary.registros_activos,
    summary.borradores_listos,
    summary.borradores_bloqueados,
    summary.revision_lista,
    summary.revision_bloqueada,
    summary.registros_validados,
    summary.registros_observados,
    summary.registros_otros,
    summary.sin_cifra_personas,
    summary.sin_sede_texto,
    summary.beneficiarios_reportados,
    summary.fecha_minima,
    summary.fecha_maxima,
    summary.meses_con_datos,
    summary.acciones_distintas,
    summary.municipios_distintos,
    status_json.value,
    issue_json.value
  FROM summary
  CROSS JOIN status_json
  CROSS JOIN issue_json;
END;
$function$;


-- ============================================================================
-- 02. ENVIAR BORRADORES DEL LOTE A REVISION
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_import_enviar_revision_lote(
  p_job_id UUID,
  p_confirmacion TEXT,
  p_limite INTEGER DEFAULT 100
)
RETURNS TABLE (
  procesados INTEGER,
  restantes INTEGER,
  bloqueados_calidad INTEGER,
  fallidos INTEGER,
  errores JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_record RECORD;
  v_processed INTEGER := 0;
  v_failed INTEGER := 0;
  v_remaining INTEGER := 0;
  v_blocked INTEGER := 0;
  v_errors JSONB := '[]'::JSONB;
  v_error TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesion autenticada.';
  END IF;

  IF NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede procesar lotes.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM v2.import_jobs j WHERE j.id = p_job_id) THEN
    RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND: el lote solicitado no existe.';
  END IF;

  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 100 THEN
    RAISE EXCEPTION 'LIMIT_INVALID: use un limite entre 1 y 100.';
  END IF;

  IF pg_catalog.upper(pg_catalog.btrim(COALESCE(p_confirmacion, '')))
       <> 'ENVIAR LOTE A REVISION' THEN
    RAISE EXCEPTION
      'CONFIRMATION_REQUIRED: escribe exactamente ENVIAR LOTE A REVISION.';
  END IF;

  FOR v_record IN
    SELECT r.id, r.folio, r.row_version
    FROM v2.registros r
    LEFT JOIN v2.vw_calidad_datos q ON q.id = r.id
    WHERE r.import_job_id = p_job_id
      AND r.origen = 'IMPORTACION_EXCEL'
      AND r.deleted_at IS NULL
      AND r.estatus IN ('BORRADOR', 'CORREGIDO')
      AND COALESCE(pg_catalog.cardinality(q.incidencias), 0) = 0
    ORDER BY r.folio, r.id
    LIMIT p_limite
  LOOP
    BEGIN
      PERFORM 1
      FROM v2.rpc_submit_borrador(v_record.id, v_record.row_version);
      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      v_failed := v_failed + 1;
      IF pg_catalog.jsonb_array_length(v_errors) < 10 THEN
        v_errors := v_errors || pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'folio', v_record.folio,
            'mensaje', v_error
          )
        );
      END IF;
    END;
  END LOOP;

  SELECT count(*)::INTEGER
  INTO v_remaining
  FROM v2.registros r
  LEFT JOIN v2.vw_calidad_datos q ON q.id = r.id
  WHERE r.import_job_id = p_job_id
    AND r.origen = 'IMPORTACION_EXCEL'
    AND r.deleted_at IS NULL
    AND r.estatus IN ('BORRADOR', 'CORREGIDO')
    AND COALESCE(pg_catalog.cardinality(q.incidencias), 0) = 0;

  SELECT count(*)::INTEGER
  INTO v_blocked
  FROM v2.registros r
  LEFT JOIN v2.vw_calidad_datos q ON q.id = r.id
  WHERE r.import_job_id = p_job_id
    AND r.origen = 'IMPORTACION_EXCEL'
    AND r.deleted_at IS NULL
    AND r.estatus IN ('BORRADOR', 'CORREGIDO')
    AND COALESCE(pg_catalog.cardinality(q.incidencias), 0) > 0;

  RETURN QUERY
  SELECT v_processed, v_remaining, v_blocked, v_failed, v_errors;
END;
$function$;


-- ============================================================================
-- 03. VALIDAR REGISTROS EN REVISION DEL LOTE
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_import_validar_lote(
  p_job_id UUID,
  p_confirmacion TEXT,
  p_limite INTEGER DEFAULT 100
)
RETURNS TABLE (
  procesados INTEGER,
  restantes INTEGER,
  bloqueados_calidad INTEGER,
  fallidos INTEGER,
  errores JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_record RECORD;
  v_processed INTEGER := 0;
  v_failed INTEGER := 0;
  v_remaining INTEGER := 0;
  v_blocked INTEGER := 0;
  v_errors JSONB := '[]'::JSONB;
  v_error TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesion autenticada.';
  END IF;

  IF NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede validar lotes.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM v2.import_jobs j WHERE j.id = p_job_id) THEN
    RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND: el lote solicitado no existe.';
  END IF;

  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 100 THEN
    RAISE EXCEPTION 'LIMIT_INVALID: use un limite entre 1 y 100.';
  END IF;

  IF pg_catalog.upper(pg_catalog.btrim(COALESCE(p_confirmacion, '')))
       <> 'VALIDAR LOTE' THEN
    RAISE EXCEPTION
      'CONFIRMATION_REQUIRED: escribe exactamente VALIDAR LOTE.';
  END IF;

  FOR v_record IN
    SELECT r.id, r.folio, r.row_version
    FROM v2.registros r
    LEFT JOIN v2.vw_calidad_datos q ON q.id = r.id
    WHERE r.import_job_id = p_job_id
      AND r.origen = 'IMPORTACION_EXCEL'
      AND r.deleted_at IS NULL
      AND r.estatus = 'EN_REVISION'
      AND COALESCE(pg_catalog.cardinality(q.incidencias), 0) = 0
    ORDER BY r.folio, r.id
    LIMIT p_limite
  LOOP
    BEGIN
      PERFORM 1
      FROM v2.rpc_decide_validacion(
        v_record.id,
        v_record.row_version,
        'VALIDAR',
        'Registro validado mediante auditoria administrativa del lote Excel.'
      );
      v_processed := v_processed + 1;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      v_failed := v_failed + 1;
      IF pg_catalog.jsonb_array_length(v_errors) < 10 THEN
        v_errors := v_errors || pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'folio', v_record.folio,
            'mensaje', v_error
          )
        );
      END IF;
    END;
  END LOOP;

  SELECT count(*)::INTEGER
  INTO v_remaining
  FROM v2.registros r
  LEFT JOIN v2.vw_calidad_datos q ON q.id = r.id
  WHERE r.import_job_id = p_job_id
    AND r.origen = 'IMPORTACION_EXCEL'
    AND r.deleted_at IS NULL
    AND r.estatus = 'EN_REVISION'
    AND COALESCE(pg_catalog.cardinality(q.incidencias), 0) = 0;

  SELECT count(*)::INTEGER
  INTO v_blocked
  FROM v2.registros r
  LEFT JOIN v2.vw_calidad_datos q ON q.id = r.id
  WHERE r.import_job_id = p_job_id
    AND r.origen = 'IMPORTACION_EXCEL'
    AND r.deleted_at IS NULL
    AND r.estatus = 'EN_REVISION'
    AND COALESCE(pg_catalog.cardinality(q.incidencias), 0) > 0;

  RETURN QUERY
  SELECT v_processed, v_remaining, v_blocked, v_failed, v_errors;
END;
$function$;


COMMENT ON FUNCTION v2.rpc_import_auditar_lote(UUID) IS
'Resume calidad, estados, cifras y cobertura de un lote Excel. Solo ADMIN.';
COMMENT ON FUNCTION v2.rpc_import_enviar_revision_lote(UUID, TEXT, INTEGER) IS
'Envia hasta 100 borradores importados usando rpc_submit_borrador y conserva auditoria.';
COMMENT ON FUNCTION v2.rpc_import_validar_lote(UUID, TEXT, INTEGER) IS
'Valida hasta 100 registros importados usando rpc_decide_validacion y conserva historial.';

REVOKE ALL ON FUNCTION v2.rpc_import_auditar_lote(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2.rpc_import_enviar_revision_lote(UUID, TEXT, INTEGER)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2.rpc_import_validar_lote(UUID, TEXT, INTEGER)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION v2.rpc_import_auditar_lote(UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_import_enviar_revision_lote(UUID, TEXT, INTEGER)
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_import_validar_lote(UUID, TEXT, INTEGER)
  TO authenticated;

INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12n',
  '12n_import_batch_audit.sql - Auditoria, envio a revision y validacion masiva segura por lote Excel.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  to_regprocedure('v2.rpc_import_auditar_lote(uuid)') IS NOT NULL
    AS rpc_auditoria,
  to_regprocedure('v2.rpc_import_enviar_revision_lote(uuid,text,integer)') IS NOT NULL
    AS rpc_envio,
  to_regprocedure('v2.rpc_import_validar_lote(uuid,text,integer)') IS NOT NULL
    AS rpc_validacion,
  COALESCE(
    has_function_privilege(
      'authenticated',
      'v2.rpc_import_auditar_lote(uuid)',
      'EXECUTE'
    ), false
  ) AS authenticated_auditoria,
  COALESCE(
    has_function_privilege(
      'anon',
      'v2.rpc_import_auditar_lote(uuid)',
      'EXECUTE'
    ), false
  ) AS anon_auditoria,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12n')
    AS migracion_registrada;

-- Resultado esperado:
-- true | true | true | true | false | 1
