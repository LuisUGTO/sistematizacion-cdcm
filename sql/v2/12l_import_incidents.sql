-- ============================================================================
-- VINCULACION CULTURAL V2
-- 12l_import_incidents.sql
-- Etapa 6.5.4: detalle seguro de incidencias de importacion
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.import_jobs') IS NULL
     OR to_regclass('v2.import_staging') IS NULL
     OR to_regclass('v2.profiles') IS NULL
     OR to_regprocedure('v2.rpc_import_historial()') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION_FALLIDA: instale primero 12j_bulk_excel_import.sql.';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION v2.rpc_import_incidencias(p_job_id UUID)
RETURNS TABLE (
  numero_fila INTEGER,
  hoja TEXT,
  fila_excel INTEGER,
  categoria TEXT,
  actividad TEXT,
  sede TEXT,
  estatus TEXT,
  errores JSONB
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    s.numero_fila,
    s.raw_data ->> 'hoja' AS hoja,
    CASE
      WHEN (s.raw_data ->> 'fila_excel') ~ '^[0-9]+$'
        THEN (s.raw_data ->> 'fila_excel')::INTEGER
      ELSE NULL
    END AS fila_excel,
    s.raw_data ->> 'categoria' AS categoria,
    s.normalized_data #>> '{payload,nombre}' AS actividad,
    s.normalized_data #>> '{payload,metadata,location_text,sede}' AS sede,
    s.estatus,
    COALESCE(s.errores, '[]'::JSONB) AS errores
  FROM v2.import_staging s
  JOIN v2.import_jobs j
    ON j.id = s.import_job_id
  JOIN v2.profiles p
    ON p.user_id = auth.uid()
  WHERE s.import_job_id = p_job_id
    AND p.activo = true
    AND p.rol = 'ADMIN'
    AND s.estatus IN ('ERROR', 'DUPLICADO')
  ORDER BY s.numero_fila
  LIMIT 1000;
$function$;

COMMENT ON FUNCTION v2.rpc_import_incidencias(UUID) IS
'Devuelve errores y duplicados de un trabajo de importacion para administradores autenticados.';

REVOKE ALL ON FUNCTION v2.rpc_import_incidencias(UUID)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION v2.rpc_import_incidencias(UUID)
  TO authenticated;

INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12l',
  '12l_import_incidents.sql - Detalle seguro de errores y duplicados de importacion para ADMIN.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  to_regprocedure('v2.rpc_import_incidencias(uuid)') IS NOT NULL AS rpc_incidencias,
  COALESCE(
    has_function_privilege(
      'authenticated',
      'v2.rpc_import_incidencias(uuid)',
      'EXECUTE'
    ),
    false
  ) AS authenticated_incidencias,
  COALESCE(
    has_function_privilege(
      'anon',
      'v2.rpc_import_incidencias(uuid)',
      'EXECUTE'
    ),
    false
  ) AS anon_incidencias,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12l')
    AS migracion_registrada;

-- Resultado esperado:
-- true | true | false | 1
