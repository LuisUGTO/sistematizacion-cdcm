-- ============================================================================
-- VINCULACION CULTURAL V2
-- 12j_bulk_excel_import.sql
-- Etapa 6.4: importacion masiva segura desde Excel
--
-- Principios:
--   - Solo ADMIN prepara y confirma cargas en esta etapa.
--   - Toda fila pasa por v2.import_staging antes de tocar operacion.
--   - La escritura final reutiliza rpc_create_borrador(), por lo que conserva
--     configuraciones vigentes, alcances, demografia, triggers y auditoria.
--   - Los registros entran como BORRADOR y origen IMPORTACION_EXCEL.
--   - MIGRACION_V1 e historicos existentes no se modifican.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.import_jobs') IS NULL
     OR to_regclass('v2.import_staging') IS NULL
     OR to_regclass('v2.registros') IS NULL
     OR to_regprocedure('v2.rpc_create_borrador(jsonb)') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION_FALLIDA: ejecute primero el esquema V2 y 12c_rpc_create_borrador.sql.';
  END IF;
END
$$;


-- Agiliza la deteccion de una actividad ya importada desde otro archivo.
CREATE INDEX IF NOT EXISTS idx_v2_registros_import_fingerprint
  ON v2.registros ((metadata #>> '{importacion,fingerprint}'))
  WHERE origen = 'IMPORTACION_EXCEL'
    AND deleted_at IS NULL
    AND metadata #>> '{importacion,fingerprint}' IS NOT NULL;


-- ============================================================================
-- 01. CREAR TRABAJO
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_import_preparar(
  p_archivo_nombre TEXT,
  p_tipo_importacion TEXT DEFAULT 'ACTIVIDADES_OPERATIVAS',
  p_metadata JSONB DEFAULT '{}'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_job UUID;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesion autenticada.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.profiles p
    WHERE p.user_id = v_uid
      AND p.activo = true
      AND p.rol = 'ADMIN'
  ) THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede realizar importaciones masivas.';
  END IF;

  IF NULLIF(pg_catalog.btrim(p_archivo_nombre), '') IS NULL THEN
    RAISE EXCEPTION 'FILE_REQUIRED: indica el nombre del archivo.';
  END IF;

  INSERT INTO v2.import_jobs (
    tipo_importacion,
    archivo_nombre,
    usuario_id,
    estatus,
    metadata
  )
  VALUES (
    COALESCE(NULLIF(pg_catalog.btrim(p_tipo_importacion), ''), 'ACTIVIDADES_OPERATIVAS'),
    pg_catalog.btrim(p_archivo_nombre),
    v_uid,
    'LEYENDO',
    COALESCE(p_metadata, '{}'::JSONB)
  )
  RETURNING id INTO v_job;

  RETURN v_job;
END;
$function$;


-- ============================================================================
-- 02. CARGAR Y VALIDAR UN LOTE EN STAGING
--
-- Cada elemento de p_rows debe incluir:
--   numero_fila, raw_data, normalized_data
-- normalized_data contiene payload (formato rpc_create_borrador) y fingerprint.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_import_cargar_lote(
  p_job_id UUID,
  p_rows JSONB
)
RETURNS TABLE (
  total_filas INTEGER,
  filas_validas INTEGER,
  filas_error INTEGER,
  filas_duplicadas INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_item JSONB;
  v_row_number INTEGER;
  v_raw JSONB;
  v_normalized JSONB;
  v_payload JSONB;
  v_fingerprint TEXT;
  v_status TEXT;
  v_errors JSONB;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesion autenticada.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.import_jobs j
    JOIN v2.profiles p ON p.user_id = v_uid
    WHERE j.id = p_job_id
      AND j.usuario_id = v_uid
      AND p.activo = true
      AND p.rol = 'ADMIN'
      AND j.estatus IN ('LEYENDO', 'VALIDANDO', 'LISTO')
  ) THEN
    RAISE EXCEPTION 'IMPORT_JOB_FORBIDDEN: el trabajo no existe, no pertenece al usuario o ya fue cerrado.';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'ROWS_INVALID: se esperaba un arreglo de filas.';
  END IF;

  IF jsonb_array_length(p_rows) > 250 THEN
    RAISE EXCEPTION 'BATCH_TOO_LARGE: cada lote admite hasta 250 filas.';
  END IF;

  UPDATE v2.import_jobs j
  SET estatus = 'VALIDANDO', updated_at = pg_catalog.now()
  WHERE j.id = p_job_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_row_number := NULLIF(v_item ->> 'numero_fila', '')::INTEGER;
    v_raw := COALESCE(v_item -> 'raw_data', '{}'::JSONB);
    v_normalized := COALESCE(v_item -> 'normalized_data', '{}'::JSONB);
    v_payload := v_normalized -> 'payload';
    v_fingerprint := NULLIF(pg_catalog.btrim(v_normalized ->> 'fingerprint'), '');
    v_errors := '[]'::JSONB;
    v_status := 'VALIDO';

    IF v_row_number IS NULL OR v_row_number <= 0 THEN
      RAISE EXCEPTION 'ROW_NUMBER_INVALID: toda fila requiere numero_fila positivo.';
    END IF;

    IF v_payload IS NULL OR jsonb_typeof(v_payload) <> 'object' THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'codigo', 'PAYLOAD_INVALID', 'mensaje', 'La fila no contiene datos normalizados.'
      ));
    ELSE
      IF NULLIF(v_payload ->> 'accion_id', '') IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'codigo', 'ACTION_REQUIRED', 'mensaje', 'Falta la accion institucional.'
        ));
      END IF;
      IF NULLIF(v_payload ->> 'configuracion_accion_id', '') IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'codigo', 'CONFIG_REQUIRED', 'mensaje', 'Falta la configuracion vigente.'
        ));
      END IF;
      IF NULLIF(pg_catalog.btrim(v_payload ->> 'nombre'), '') IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'codigo', 'NAME_REQUIRED', 'mensaje', 'Falta el nombre de la actividad.'
        ));
      END IF;
      IF NULLIF(v_payload ->> 'fecha_inicio', '') IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'codigo', 'DATE_REQUIRED', 'mensaje', 'Falta la fecha de inicio.'
        ));
      END IF;
    END IF;

    IF jsonb_array_length(v_errors) > 0 THEN
      v_status := 'ERROR';
    ELSIF v_fingerprint IS NOT NULL AND (
      EXISTS (
        SELECT 1
        FROM v2.import_staging s
        WHERE s.import_job_id = p_job_id
          AND s.numero_fila <> v_row_number
          AND s.normalized_data ->> 'fingerprint' = v_fingerprint
          AND s.estatus IN ('VALIDO', 'DUPLICADO', 'IMPORTADO')
      )
      OR EXISTS (
        SELECT 1
        FROM v2.registros r
        WHERE r.deleted_at IS NULL
          AND r.origen = 'IMPORTACION_EXCEL'
          AND r.metadata #>> '{importacion,fingerprint}' = v_fingerprint
      )
    ) THEN
      v_status := 'DUPLICADO';
      v_errors := jsonb_build_array(jsonb_build_object(
        'codigo', 'DUPLICATE_ACTIVITY',
        'mensaje', 'La misma actividad ya existe en esta carga o en una importacion anterior.'
      ));
    END IF;

    INSERT INTO v2.import_staging (
      import_job_id, numero_fila, raw_data, normalized_data, estatus, errores
    )
    VALUES (
      p_job_id, v_row_number, v_raw, v_normalized, v_status, v_errors
    )
    ON CONFLICT ON CONSTRAINT uq_v2_import_staging_job_fila
    DO UPDATE SET
      raw_data = EXCLUDED.raw_data,
      normalized_data = EXCLUDED.normalized_data,
      estatus = EXCLUDED.estatus,
      errores = EXCLUDED.errores,
      updated_at = pg_catalog.now();
  END LOOP;

  UPDATE v2.import_jobs j
  SET
    total_filas = c.total,
    filas_validas = c.validas,
    filas_error = c.errores,
    filas_duplicadas = c.duplicadas,
    estatus = CASE WHEN c.validas > 0 THEN 'LISTO' ELSE 'ERROR' END,
    updated_at = pg_catalog.now()
  FROM (
    SELECT
      count(*)::INTEGER AS total,
      count(*) FILTER (WHERE s.estatus = 'VALIDO')::INTEGER AS validas,
      count(*) FILTER (WHERE s.estatus = 'ERROR')::INTEGER AS errores,
      count(*) FILTER (WHERE s.estatus = 'DUPLICADO')::INTEGER AS duplicadas
    FROM v2.import_staging s
    WHERE s.import_job_id = p_job_id
  ) c
  WHERE j.id = p_job_id;

  RETURN QUERY
  SELECT j.total_filas, j.filas_validas, j.filas_error, j.filas_duplicadas
  FROM v2.import_jobs j
  WHERE j.id = p_job_id;
END;
$function$;


-- ============================================================================
-- 03. CONFIRMAR FILAS VALIDAS
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_import_confirmar(
  p_job_id UUID
)
RETURNS TABLE (
  job_id UUID,
  estatus TEXT,
  total_filas INTEGER,
  filas_importadas INTEGER,
  filas_error INTEGER,
  filas_duplicadas INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_file_name TEXT;
  v_stage RECORD;
  v_payload JSONB;
  v_record_id UUID;
  v_folio TEXT;
  v_error TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesion autenticada.';
  END IF;

  SELECT j.archivo_nombre
  INTO v_file_name
  FROM v2.import_jobs j
  JOIN v2.profiles p ON p.user_id = v_uid
  WHERE j.id = p_job_id
    AND j.usuario_id = v_uid
    AND p.activo = true
    AND p.rol = 'ADMIN'
    AND j.estatus IN ('LISTO', 'COMPLETADO_CON_ERRORES');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'IMPORT_JOB_NOT_READY: el trabajo no existe o no esta listo para confirmar.';
  END IF;

  UPDATE v2.import_jobs j
  SET estatus = 'IMPORTANDO', updated_at = pg_catalog.now()
  WHERE j.id = p_job_id;

  FOR v_stage IN
    SELECT s.id, s.numero_fila, s.normalized_data
    FROM v2.import_staging s
    WHERE s.import_job_id = p_job_id
      AND s.estatus = 'VALIDO'
    ORDER BY s.numero_fila
  LOOP
    BEGIN
      v_payload := v_stage.normalized_data -> 'payload';

      SELECT created.id, created.folio
      INTO v_record_id, v_folio
      FROM v2.rpc_create_borrador(v_payload) AS created
      LIMIT 1;

      UPDATE v2.registros r
      SET
        origen = 'IMPORTACION_EXCEL',
        import_job_id = p_job_id,
        archivo_origen = v_file_name,
        fila_origen = v_stage.numero_fila,
        metadata = COALESCE(r.metadata, '{}'::JSONB) || jsonb_build_object(
          'importacion', jsonb_build_object(
            'job_id', p_job_id,
            'archivo', v_file_name,
            'fila', v_stage.numero_fila,
            'fingerprint', v_stage.normalized_data ->> 'fingerprint',
            'perfil', v_stage.normalized_data ->> 'perfil',
            'hoja', v_stage.normalized_data ->> 'hoja'
          )
        ),
        updated_by = v_uid,
        updated_at = pg_catalog.now()
      WHERE r.id = v_record_id;

      UPDATE v2.import_staging s
      SET
        estatus = 'IMPORTADO',
        normalized_data = s.normalized_data || jsonb_build_object(
          'registro_id', v_record_id,
          'folio', v_folio
        ),
        updated_at = pg_catalog.now()
      WHERE s.id = v_stage.id;

    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      UPDATE v2.import_staging s
      SET
        estatus = 'ERROR',
        errores = COALESCE(s.errores, '[]'::JSONB) || jsonb_build_array(
          jsonb_build_object('codigo', 'DATABASE_VALIDATION', 'mensaje', v_error)
        ),
        updated_at = pg_catalog.now()
      WHERE s.id = v_stage.id;
    END;
  END LOOP;

  UPDATE v2.import_jobs j
  SET
    filas_importadas = c.importadas,
    filas_error = c.errores,
    filas_duplicadas = c.duplicadas,
    estatus = CASE
      WHEN c.importadas > 0 AND c.errores = 0 THEN 'COMPLETADO'
      WHEN c.importadas > 0 THEN 'COMPLETADO_CON_ERRORES'
      ELSE 'ERROR'
    END,
    completed_at = pg_catalog.now(),
    updated_at = pg_catalog.now()
  FROM (
    SELECT
      count(*) FILTER (WHERE s.estatus = 'IMPORTADO')::INTEGER AS importadas,
      count(*) FILTER (WHERE s.estatus = 'ERROR')::INTEGER AS errores,
      count(*) FILTER (WHERE s.estatus = 'DUPLICADO')::INTEGER AS duplicadas
    FROM v2.import_staging s
    WHERE s.import_job_id = p_job_id
  ) c
  WHERE j.id = p_job_id;

  RETURN QUERY
  SELECT
    j.id, j.estatus, j.total_filas, j.filas_importadas,
    j.filas_error, j.filas_duplicadas
  FROM v2.import_jobs j
  WHERE j.id = p_job_id;
END;
$function$;


-- ============================================================================
-- 04. HISTORIAL Y DETALLE DE INCIDENCIAS
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_import_historial()
RETURNS TABLE (
  id UUID,
  archivo_nombre TEXT,
  tipo_importacion TEXT,
  estatus TEXT,
  total_filas INTEGER,
  filas_importadas INTEGER,
  filas_error INTEGER,
  filas_duplicadas INTEGER,
  created_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    j.id, j.archivo_nombre, j.tipo_importacion, j.estatus,
    j.total_filas, j.filas_importadas, j.filas_error,
    j.filas_duplicadas, j.created_at, j.completed_at
  FROM v2.import_jobs j
  JOIN v2.profiles p ON p.user_id = auth.uid()
  WHERE p.activo = true
    AND p.rol = 'ADMIN'
  ORDER BY j.created_at DESC
  LIMIT 25;
$function$;


COMMENT ON FUNCTION v2.rpc_import_preparar(TEXT, TEXT, JSONB) IS
'Crea un trabajo de importacion Excel V2. Solo ADMIN.';
COMMENT ON FUNCTION v2.rpc_import_cargar_lote(UUID, JSONB) IS
'Carga hasta 250 filas por lote en staging, valida requeridos y detecta duplicados.';
COMMENT ON FUNCTION v2.rpc_import_confirmar(UUID) IS
'Convierte filas validas en borradores V2 mediante la escritura canonica existente.';
COMMENT ON FUNCTION v2.rpc_import_historial() IS
'Devuelve las 25 importaciones masivas recientes para el ADMIN.';


REVOKE ALL ON FUNCTION v2.rpc_import_preparar(TEXT, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2.rpc_import_cargar_lote(UUID, JSONB)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2.rpc_import_confirmar(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2.rpc_import_historial()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION v2.rpc_import_preparar(TEXT, TEXT, JSONB)
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_import_cargar_lote(UUID, JSONB)
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_import_confirmar(UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_import_historial()
  TO authenticated;


INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12j',
  '12j_bulk_excel_import.sql - Importacion Excel con staging, duplicados, confirmacion y trazabilidad V2 solo para ADMIN.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;


-- VERIFICACION POST-INSTALACION
SELECT
  to_regprocedure('v2.rpc_import_preparar(text,text,jsonb)') IS NOT NULL AS rpc_preparar,
  to_regprocedure('v2.rpc_import_cargar_lote(uuid,jsonb)') IS NOT NULL AS rpc_lote,
  to_regprocedure('v2.rpc_import_confirmar(uuid)') IS NOT NULL AS rpc_confirmar,
  to_regprocedure('v2.rpc_import_historial()') IS NOT NULL AS rpc_historial,
  COALESCE(has_function_privilege('authenticated', 'v2.rpc_import_preparar(text,text,jsonb)', 'EXECUTE'), false) AS authenticated_preparar,
  COALESCE(has_function_privilege('anon', 'v2.rpc_import_preparar(text,text,jsonb)', 'EXECUTE'), false) AS anon_preparar,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12j') AS migracion_registrada;

-- RESULTADO ESPERADO:
-- true | true | true | true | true | false | 1
