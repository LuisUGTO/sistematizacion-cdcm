-- PAQUETE 1: seguridad y permisos. Basado en el diagnóstico entregado.
-- Ejecutar completo. No elimina registros ni cambia asignaciones o contactos.
-- Transacción: si hay error antes de COMMIT, no conserva cambios del paquete.
-- Se rechazan definiciones diferentes de la copia auditada o de este paquete.
BEGIN;
SET LOCAL lock_timeout='10s';
SET LOCAL statement_timeout='120s';
DO $preflight$
DECLARE r RECORD; v_actual TEXT;
BEGIN
  IF to_regclass('v2.schema_migrations') IS NULL OR
     NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id='evidencias-v2') THEN
    RAISE EXCEPTION 'PRECONDICION: faltan migraciones o bucket evidencias-v2.';
  END IF;
  FOR r IN SELECT * FROM (VALUES
      ('v2.rpc_superadmin_actualizar_nombre_usuario(uuid,text)','369f331f96a1bd08c006428f248dda28','34926bfd6d324ba6db8a5eeb24bc46e3'),
      ('v2.rpc_get_registro_validacion(uuid)','559fcc6123f15f7af188c3d7f2f11358','4667f3edb0c3e2493291f808b4c9c0e4'),
      ('v2.rpc_decide_validacion(uuid,integer,text,text)','a681d8edb0590925bfe2f78054183106','4f3dd7610634dec7776602e58f84c8d6'),
      ('v2.rpc_import_preparar(text,text,jsonb)','4f5b14bbaf50268589d603db5847bde7','9231a79e1c6b92bec1fbadcb921fbd4b'),
      ('v2.rpc_import_cargar_lote(uuid,jsonb)','b88b3bc70616a72293944dffed85e328','2bba1df0268a61c220e95028b1d440a8'),
      ('v2.rpc_import_confirmar(uuid)','ebbc4b490c2fe5e55c29bba555d5b98e','9da4d13e47e4ae29828251a76c84b2b6'),
      ('v2.rpc_import_historial()','ece13393db4e4367871e9fdd4259e3ef','f718f85c974ae91be8b2ba7de784944a'),
      ('v2_private.authorize_status_transition()','34cc11892d987662493fc1fb67d1d17e','f7fca46310ba487466093bbece40301e'),
      ('v2_private.protect_superadmin()','e954af7614fc908f9aaa7d898d12a6c4','84438e5341c9aca46ffe7b60b0fd0125')
    ) AS expected(firma,anterior,corregida)
  LOOP
    IF to_regprocedure(r.firma) IS NULL THEN
      RAISE EXCEPTION 'PRECONDICION: falta %',r.firma;
    END IF;
    v_actual:=md5(replace(pg_get_functiondef(to_regprocedure(r.firma)),chr(13),''));
    IF v_actual NOT IN (r.anterior,r.corregida) THEN
      RAISE EXCEPTION 'VERSION_DISTINTA: % cambió desde el diagnóstico; no se aplicó el paquete.',r.firma;
    END IF;
  END LOOP;
END;
$preflight$;

CREATE OR REPLACE FUNCTION v2.rpc_superadmin_actualizar_nombre_usuario(p_user_id uuid, p_nombre text)
 RETURNS TABLE(user_id uuid, email text, nombre text, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_nombre TEXT := btrim(COALESCE(p_nombre, ''));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  IF v2_private.current_role() IS DISTINCT FROM 'SUPERADMIN' THEN
    RAISE EXCEPTION 'SUPERADMIN_REQUIRED: sólo SUPERADMIN puede modificar nombres de usuario.';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'USER_REQUIRED: selecciona un usuario.';
  END IF;

  IF char_length(v_nombre) < 2 OR char_length(v_nombre) > 180 THEN
    RAISE EXCEPTION 'NAME_INVALID: el nombre debe tener entre 2 y 180 caracteres.';
  END IF;

  RETURN QUERY
  UPDATE v2.profiles p
  SET nombre = v_nombre,
      updated_at = now()
  WHERE p.user_id = p_user_id
  RETURNING p.user_id, p.email, p.nombre, p.updated_at;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'USER_NOT_FOUND: el perfil V2 no existe.';
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION v2.rpc_get_registro_validacion(p_registro_id uuid)
 RETURNS TABLE(payload jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid  UUID := auth.uid();
  v_role TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION
      'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  v_role := v2_private.current_role();

  IF COALESCE(v_role, '') NOT IN ('SUPERADMIN', 'ADMIN', 'SUPERVISOR') THEN
    RAISE EXCEPTION
      'VALIDATION_ROLE_REQUIRED: solo SUPERADMIN/ADMIN/SUPERVISOR pueden revisar.';
  END IF;

  IF NOT v2_private.can_manage_record(p_registro_id) THEN
    RAISE EXCEPTION
      'VALIDATION_SCOPE_FORBIDDEN: registro fuera de tu alcance.';
  END IF;

  RETURN QUERY
  SELECT
    pg_catalog.jsonb_build_object(

      'record',
      pg_catalog.jsonb_build_object(
        'id', r.id,
        'folio', r.folio,
        'estatus', r.estatus,
        'row_version', r.row_version,
        'origen', r.origen,

        'unidad_operativa_id', r.unidad_operativa_id,
        'unidad_clave', u.clave,
        'unidad_nombre', u.nombre,

        'programa_id', r.programa_id,
        'programa_clave', p.clave,
        'programa_nombre', p.nombre,

        'accion_id', r.accion_id,
        'accion_clave', a.clave,
        'accion_nombre', a.nombre,

        'tipo_registro', tr.nombre,

        'municipio_id', r.municipio_id,
        'municipio_nombre', m.nombre_oficial,
        'region_nombre', rg.nombre,

        'comunidad_id', r.comunidad_id,
        'comunidad_nombre', c.nombre,

        'espacio_id', r.espacio_id,
        'espacio_nombre', e.nombre,

        'nombre', r.nombre,
        'descripcion', r.descripcion,
        'fecha_inicio', r.fecha_inicio,
        'fecha_fin', r.fecha_fin,

        'total_beneficiarios', r.total_beneficiarios,
        'total_participantes', r.total_participantes,
        'total_accesos', r.total_accesos,

        'created_at', r.created_at,
        'updated_at', r.updated_at
      ),

      'responsable',
      CASE
        WHEN cp.id IS NULL THEN NULL
        ELSE pg_catalog.jsonb_build_object(
          'id', cp.id,
          'nombre', cp.nombre,
          'correo', cp.correo,
          'telefono', cp.telefono
        )
      END,

      'config',
      pg_catalog.jsonb_build_object(
        'tipo_formulario', ca.tipo_formulario,
        'requiere_municipio', ca.requiere_municipio,
        'requiere_comunidad', ca.requiere_comunidad,
        'requiere_espacio', ca.requiere_espacio,
        'requiere_responsable', ca.requiere_responsable,
        'requiere_docente', ca.requiere_docente,
        'requiere_beneficiarios', ca.requiere_beneficiarios,
        'requiere_demografia', ca.requiere_demografia,
        'requiere_gps', ca.requiere_gps,
        'requiere_evidencia', ca.requiere_evidencia,
        'requiere_validacion', ca.requiere_validacion,
        'configuracion_extra', ca.configuracion_extra
      ),

      'taller',
      CASE
        WHEN rt.registro_id IS NULL THEN NULL
        ELSE pg_catalog.jsonb_build_object(
          'disciplina', rt.disciplina,
          'programacion', rt.programacion,
          'modalidad_cuota', rt.modalidad_cuota,
          'costo', rt.costo,
          'moneda', rt.moneda,
          'observaciones', rt.observaciones
        )
      END,

      'demografia',
      COALESCE(
        (
          SELECT pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'universo', rp.universo,
              'cantidad', rp.cantidad,
              'opcion_id', op.id,
              'opcion_clave', op.clave,
              'opcion_nombre', op.nombre,
              'dimension_clave', d.clave,
              'dimension_nombre', d.nombre
            )
            ORDER BY
              rp.universo,
              d.orden,
              op.orden,
              op.nombre
          )
          FROM v2.registro_poblacion rp
          JOIN v2.cat_opciones_poblacion op
            ON op.id = rp.opcion_poblacion_id
          JOIN v2.cat_dimensiones_poblacion d
            ON d.id = op.dimension_id
          WHERE rp.registro_id = r.id
        ),
        '[]'::JSONB
      ),

      'evidencias',
      COALESCE(
        (
          SELECT pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'id', re.id,
              'tipo_evidencia', re.tipo_evidencia,
              'bucket_id', re.bucket_id,
              'storage_path', re.storage_path,
              'nombre_original', re.nombre_original,
              'mime_type', re.mime_type,
              'size_bytes', re.size_bytes,
              'created_at', re.created_at
            )
            ORDER BY re.created_at DESC
          )
          FROM v2.registro_evidencias re
          WHERE re.registro_id = r.id
            AND re.activo = true
        ),
        '[]'::JSONB
      ),

      'historial',
      COALESCE(
        (
          SELECT pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'id', rv.id,
              'estatus_anterior', rv.estatus_anterior,
              'estatus_nuevo', rv.estatus_nuevo,
              'observacion', rv.observacion,
              'usuario_id', rv.usuario_id,
              'usuario_nombre', pr.nombre,
              'usuario_email', pr.email,
              'created_at', rv.created_at
            )
            ORDER BY rv.created_at DESC
          )
          FROM v2.registro_validaciones rv
          LEFT JOIN v2.profiles pr
            ON pr.user_id = rv.usuario_id
          WHERE rv.registro_id = r.id
        ),
        '[]'::JSONB
      ),

      'calidad',
      COALESCE(
        (
          SELECT pg_catalog.jsonb_build_object(
            'incidencias', q.incidencias,
            'total_incidencias', q.total_incidencias,
            'datos_completos', q.datos_completos
          )
          FROM v2.vw_calidad_datos q
          WHERE q.id = r.id
        ),
        pg_catalog.jsonb_build_object(
          'incidencias', ARRAY[]::TEXT[],
          'total_incidencias', 0,
          'datos_completos', true
        )
      ),

      'indicadores',
      COALESCE(
        (
          SELECT pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'indicador_version_id', iv.id,
              'clave', iv.clave,
              'nombre', iv.nombre,
              'regla_aporte', ai.regla_aporte,
              'requiere_validado', ai.requiere_validado,
              'factor', ai.factor,
              'valor_estimado',
                CASE ai.regla_aporte
                  WHEN 'UNO_POR_REGISTRO'
                    THEN ai.factor
                  WHEN 'TOTAL_BENEFICIARIOS'
                    THEN
                      CASE
                        WHEN r.total_beneficiarios IS NULL THEN NULL
                        ELSE r.total_beneficiarios * ai.factor
                      END
                  ELSE NULL
                END
            )
            ORDER BY iv.clave
          )
          FROM v2.accion_indicador ai
          JOIN v2.indicadores_version iv
            ON iv.id = ai.indicador_version_id
           AND iv.activo = true
           AND iv.ejercicio = r.periodo_anio
          WHERE ai.accion_id = r.accion_id
            AND ai.activo = true
        ),
        '[]'::JSONB
      ),

      'permissions',
      pg_catalog.jsonb_build_object(
        'can_decide',
          (
            r.estatus = 'EN_REVISION'
            AND v2_private.can_manage_record(r.id)
          )
      )
    ) AS payload

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

  LEFT JOIN v2.cat_personas cp
    ON cp.id = r.responsable_id

  LEFT JOIN v2.configuracion_acciones ca
    ON ca.id = r.configuracion_accion_id

  LEFT JOIN v2.registro_taller rt
    ON rt.registro_id = r.id

  WHERE r.id = p_registro_id
    AND r.deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'RECORD_NOT_FOUND: registro inexistente.';
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION v2.rpc_decide_validacion(p_registro_id uuid, p_expected_row_version integer, p_decision text, p_observacion text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, folio text, estatus text, row_version integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid          UUID := auth.uid();
  v_role         TEXT;
  v_record       RECORD;
  v_decision     TEXT;
  v_observacion  TEXT;
  v_nuevo_estado TEXT;
  v_version      INTEGER;
  v_incidencias  TEXT[];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION
      'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  v_role :=
    v2_private.current_role();

  IF COALESCE(v_role, '') NOT IN ('SUPERADMIN', 'ADMIN', 'SUPERVISOR') THEN
    RAISE EXCEPTION
      'VALIDATION_ROLE_REQUIRED: solo SUPERADMIN/ADMIN/SUPERVISOR pueden decidir.';
  END IF;

  SELECT r.*
  INTO v_record
  FROM v2.registros r
  WHERE r.id = p_registro_id
    AND r.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'RECORD_NOT_FOUND: registro inexistente.';
  END IF;

  IF NOT v2_private.can_manage_record(p_registro_id) THEN
    RAISE EXCEPTION
      'VALIDATION_SCOPE_FORBIDDEN: registro fuera de tu alcance.';
  END IF;

  IF v_record.estatus <> 'EN_REVISION' THEN
    RAISE EXCEPTION
      'STATUS_NOT_REVIEWABLE: se esperaba EN_REVISION y se encontró %.',
      v_record.estatus;
  END IF;

  IF p_expected_row_version IS NULL
     OR p_expected_row_version <> v_record.row_version THEN
    RAISE EXCEPTION
      'VERSION_CONFLICT: el registro cambió desde que lo abriste. Recarga antes de decidir.';
  END IF;

  v_decision :=
    upper(
      pg_catalog.btrim(
        COALESCE(p_decision, '')
      )
    );

  v_observacion :=
    NULLIF(
      pg_catalog.btrim(
        COALESCE(p_observacion, '')
      ),
      ''
    );

  IF v_decision NOT IN ('VALIDAR', 'OBSERVAR') THEN
    RAISE EXCEPTION
      'DECISION_INVALID: use VALIDAR u OBSERVAR.';
  END IF;

  IF v_decision = 'OBSERVAR'
     AND (
       v_observacion IS NULL
       OR pg_catalog.char_length(v_observacion) < 10
     ) THEN
    RAISE EXCEPTION
      'OBSERVATION_REQUIRED: describe la corrección requerida con al menos 10 caracteres.';
  END IF;


  -- --------------------------------------------------------------------------
  -- VALIDAR exige que la calidad siga completa al momento de decidir.
  -- --------------------------------------------------------------------------

  IF v_decision = 'VALIDAR' THEN

    SELECT q.incidencias
    INTO v_incidencias
    FROM v2.vw_calidad_datos q
    WHERE q.id = p_registro_id;

    v_incidencias :=
      COALESCE(
        v_incidencias,
        ARRAY[]::TEXT[]
      );

    IF pg_catalog.cardinality(v_incidencias) > 0 THEN
      RAISE EXCEPTION
        'QUALITY_BLOCK: %',
        pg_catalog.array_to_string(
          v_incidencias,
          ', '
        );
    END IF;

    v_nuevo_estado :=
      'VALIDADO';

    v_observacion :=
      COALESCE(
        v_observacion,
        'Registro validado sin observaciones adicionales.'
      );

  ELSE

    v_nuevo_estado :=
      'OBSERVADO';

  END IF;


  -- El trigger de historial consume esta observación en la misma transición.
  PERFORM pg_catalog.set_config(
    'v2.validation_observation',
    v_observacion,
    true
  );

  UPDATE v2.registros AS r
  SET
    estatus = v_nuevo_estado,
    updated_by = v_uid
  WHERE r.id = p_registro_id
  RETURNING r.row_version
  INTO v_version;

  RETURN QUERY
  SELECT
    p_registro_id,
    v_record.folio,
    v_nuevo_estado,
    v_version;
END;
$function$
;

CREATE OR REPLACE FUNCTION v2.rpc_import_preparar(p_archivo_nombre text, p_tipo_importacion text DEFAULT 'ACTIVIDADES_OPERATIVAS'::text, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
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
      AND p.rol IN ('SUPERADMIN', 'ADMIN')
  ) THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo SUPERADMIN/ADMIN puede realizar importaciones masivas.';
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
$function$
;

CREATE OR REPLACE FUNCTION v2.rpc_import_cargar_lote(p_job_id uuid, p_rows jsonb)
 RETURNS TABLE(total_filas integer, filas_validas integer, filas_error integer, filas_duplicadas integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
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
      AND p.rol IN ('SUPERADMIN', 'ADMIN')
      AND j.estatus IN ('LEYENDO', 'VALIDANDO', 'LISTO', 'ERROR')
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
$function$
;

CREATE OR REPLACE FUNCTION v2.rpc_import_confirmar(p_job_id uuid)
 RETURNS TABLE(job_id uuid, estatus text, total_filas integer, filas_importadas integer, filas_error integer, filas_duplicadas integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
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
    AND p.rol IN ('SUPERADMIN', 'ADMIN')
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
$function$
;

CREATE OR REPLACE FUNCTION v2.rpc_import_historial()
 RETURNS TABLE(id uuid, archivo_nombre text, tipo_importacion text, estatus text, total_filas integer, filas_importadas integer, filas_error integer, filas_duplicadas integer, created_at timestamp with time zone, completed_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT
    j.id, j.archivo_nombre, j.tipo_importacion, j.estatus,
    j.total_filas, j.filas_importadas, j.filas_error,
    j.filas_duplicadas, j.created_at, j.completed_at
  FROM v2.import_jobs j
  JOIN v2.profiles p ON p.user_id = auth.uid()
  WHERE p.activo = true
    AND p.rol IN ('SUPERADMIN', 'ADMIN')
  ORDER BY j.created_at DESC
  LIMIT 25;
$function$
;

CREATE OR REPLACE FUNCTION v2_private.authorize_status_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  v_role TEXT;
BEGIN
  -- Migraciones controladas desde SQL Editor / servicio.
  IF auth.uid() IS NULL
     AND current_user IN ('postgres', 'supabase_admin', 'service_role') THEN
    RETURN NEW;
  END IF;

  v_role := v2_private.current_role();

  IF v_role IN ('SUPERADMIN', 'ADMIN') THEN
    RETURN NEW;
  END IF;

  IF v_role = 'CAPTURISTA'
     AND OLD.created_by = auth.uid()
     AND (
       (OLD.estatus = 'BORRADOR'   AND NEW.estatus = 'CAPTURADO')
       OR
       (OLD.estatus = 'CAPTURADO'  AND NEW.estatus = 'EN_REVISION')
       OR
       (OLD.estatus = 'OBSERVADO'  AND NEW.estatus = 'CORREGIDO')
       OR
       (OLD.estatus = 'CORREGIDO'  AND NEW.estatus = 'EN_REVISION')
     ) THEN
    RETURN NEW;
  END IF;

  IF v_role = 'SUPERVISOR'
     AND v2_private.has_scope(
       OLD.unidad_operativa_id,
       OLD.municipio_id
     )
     AND (
       (OLD.estatus = 'CAPTURADO'  AND NEW.estatus = 'EN_REVISION')
       OR
       (OLD.estatus = 'EN_REVISION' AND NEW.estatus = 'VALIDADO')
       OR
       (OLD.estatus = 'EN_REVISION' AND NEW.estatus = 'OBSERVADO')
       OR
       (OLD.estatus = 'CORREGIDO' AND NEW.estatus = 'EN_REVISION')
     ) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION
    'El rol % no puede realizar la transición % -> %.',
    COALESCE(v_role, 'SIN_ROL'),
    OLD.estatus,
    NEW.estatus;
END;
$function$
;

CREATE OR REPLACE FUNCTION v2_private.protect_superadmin()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE caller TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  caller:=v2_private.current_role();
  IF OLD.rol='SUPERADMIN' AND (NEW.rol IS DISTINCT FROM OLD.rol OR NEW.activo IS DISTINCT FROM OLD.activo) THEN
    RAISE EXCEPTION 'SUPERADMIN_PROTECTED: la cuenta principal no puede modificarse desde el panel.';
  END IF;
  IF caller IS DISTINCT FROM 'SUPERADMIN' AND (OLD.rol='ADMIN' OR NEW.rol IN ('ADMIN','SUPERADMIN')) THEN
    RAISE EXCEPTION 'SUPERADMIN_REQUIRED: solo SUPERADMIN puede gestionar administradores.';
  END IF;
  IF OLD.rol<>'SUPERADMIN' AND NEW.rol='SUPERADMIN' THEN
    RAISE EXCEPTION 'SUPERADMIN_UNIQUE: no se puede asignar este rol desde el panel.';
  END IF;
  RETURN NEW;
END $function$
;
REVOKE ALL ON FUNCTION v2.rpc_superadmin_actualizar_nombre_usuario(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_superadmin_actualizar_nombre_usuario(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION v2.rpc_get_registro_validacion(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_get_registro_validacion(uuid) TO authenticated;
REVOKE ALL ON FUNCTION v2.rpc_decide_validacion(uuid,integer,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_decide_validacion(uuid,integer,text,text) TO authenticated;
REVOKE ALL ON FUNCTION v2.rpc_import_preparar(text,text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_import_preparar(text,text,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION v2.rpc_import_cargar_lote(uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_import_cargar_lote(uuid,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION v2.rpc_import_confirmar(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_import_confirmar(uuid) TO authenticated;
REVOKE ALL ON FUNCTION v2.rpc_import_historial() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_import_historial() TO authenticated;
REVOKE ALL ON FUNCTION v2_private.authorize_status_transition() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.protect_superadmin() FROM PUBLIC, anon, authenticated;
UPDATE storage.buckets
SET file_size_limit=10485760,
    allowed_mime_types=ARRAY['image/jpeg','image/png','image/webp','application/pdf']::text[],
    public=false
WHERE id='evidencias-v2';
INSERT INTO v2.schema_migrations(version,descripcion)
VALUES ('2.1.13-security-01','Paquete 1: autorización segura, SUPERADMIN en validación/importación y evidencias privadas con límites.')
ON CONFLICT(version) DO NOTHING;
COMMIT;
SELECT 'PAQUETE_1_APLICADO' AS resultado;
