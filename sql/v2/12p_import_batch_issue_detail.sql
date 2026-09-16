-- ============================================================================
-- VINCULACION CULTURAL V2
-- 12p_import_batch_issue_detail.sql
-- Etapa 6.6.2: detalle accionable de faltantes por lote de importacion
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.import_jobs') IS NULL
     OR to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.vw_calidad_datos') IS NULL
     OR to_regprocedure('v2.rpc_import_auditar_lote(uuid)') IS NULL
     OR to_regprocedure('v2_private.is_admin()') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION_FALLIDA: instale primero 12n_import_batch_audit.sql.';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION v2.rpc_import_faltantes_lote(p_job_id UUID)
RETURNS TABLE (
  registro_id UUID,
  folio TEXT,
  nombre TEXT,
  estatus TEXT,
  fecha_inicio DATE,
  incidencias TEXT[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesion autenticada.';
  END IF;

  IF NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede auditar lotes.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.import_jobs j
    WHERE j.id = p_job_id
  ) THEN
    RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND: el lote solicitado no existe.';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.folio,
    r.nombre,
    r.estatus,
    r.fecha_inicio,
    COALESCE(q.incidencias, ARRAY[]::TEXT[])
  FROM v2.registros r
  INNER JOIN v2.vw_calidad_datos q
    ON q.id = r.id
  WHERE r.import_job_id = p_job_id
    AND r.origen = 'IMPORTACION_EXCEL'
    AND r.deleted_at IS NULL
    AND r.estatus IN ('BORRADOR', 'CORREGIDO', 'EN_REVISION')
    AND pg_catalog.cardinality(q.incidencias) > 0
  ORDER BY r.folio NULLS LAST, r.fecha_inicio, r.id;
END;
$function$;

COMMENT ON FUNCTION v2.rpc_import_faltantes_lote(UUID) IS
'Lista cada registro bloqueado de un lote Excel con folio, actividad y faltantes exactos. Solo ADMIN.';

REVOKE ALL ON FUNCTION v2.rpc_import_faltantes_lote(UUID)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION v2.rpc_import_faltantes_lote(UUID)
  TO authenticated;

INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12p',
  '12p_import_batch_issue_detail.sql - Folios y faltantes accionables por lote Excel.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  to_regprocedure('v2.rpc_import_faltantes_lote(uuid)') IS NOT NULL
    AS rpc_detalle_faltantes,
  COALESCE(
    has_function_privilege(
      'authenticated',
      'v2.rpc_import_faltantes_lote(uuid)',
      'EXECUTE'
    ), false
  ) AS authenticated_ejecuta,
  COALESCE(
    has_function_privilege(
      'anon',
      'v2.rpc_import_faltantes_lote(uuid)',
      'EXECUTE'
    ), false
  ) AS anon_ejecuta,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12p')
    AS migracion_registrada;

-- Resultado esperado:
-- true | true | false | 1
