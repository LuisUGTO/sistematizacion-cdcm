-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 12d_draft_workflow.sql
-- Edición transaccional de borradores + envío a revisión
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   12c_rpc_create_borrador.sql
--
-- IMPLEMENTA:
--   ✓ lectura segura de un registro para editor
--   ✓ actualización transaccional de BORRADOR manual
--   ✓ responsable reutilizable en cat_personas
--   ✓ actualización de taller/capacitación
--   ✓ reemplazo controlado de demografía
--   ✓ concurrencia optimista mediante row_version
--   ✓ envío BORRADOR -> CAPTURADO -> EN_REVISION
--   ✓ bloqueo de envío si faltan campos institucionales
--
-- NO:
--   ✗ modifica históricos MIGRACION_V1
--   ✗ expone helpers privados
--   ✗ valida automáticamente un registro
--   ✗ crea evidencia Storage (eso lo hace el frontend contra bucket privado)
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.registro_taller') IS NULL
     OR to_regclass('v2.registro_poblacion') IS NULL
     OR to_regclass('v2.registro_evidencias') IS NULL
     OR to_regclass('v2.cat_personas') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos operativos V2.';
  END IF;

  IF to_regprocedure('v2_private.can_read_record(uuid)') IS NULL
     OR to_regprocedure('v2_private.can_edit_record(uuid)') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan helpers de autorización V2.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.12c'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 12c_rpc_create_borrador.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. LEER REGISTRO PARA EDITOR
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_get_registro_editor(
  p_registro_id UUID
)
RETURNS TABLE (
  payload JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION
      'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  IF NOT v2_private.can_read_record(p_registro_id) THEN
    RAISE EXCEPTION
      'READ_FORBIDDEN: no tienes acceso a este registro.';
  END IF;

  RETURN QUERY
  SELECT
    pg_catalog.jsonb_build_object(
      'record',
      pg_catalog.jsonb_build_object(
        'id', r.id,
        'folio', r.folio,
        'unidad_operativa_id', r.unidad_operativa_id,
        'unidad_clave', u.clave,
        'unidad_nombre', u.nombre,

        'programa_id', r.programa_id,
        'programa_clave', p.clave,
        'programa_nombre', p.nombre,

        'accion_id', r.accion_id,
        'accion_clave', a.clave,
        'accion_nombre', a.nombre,

        'tipo_registro_id', r.tipo_registro_id,
        'configuracion_accion_id', r.configuracion_accion_id,

        'municipio_id', r.municipio_id,
        'municipio_nombre', m.nombre_oficial,

        'espacio_id', r.espacio_id,
        'espacio_nombre', e.nombre,

        'responsable_id', r.responsable_id,

        'nombre', r.nombre,
        'descripcion', r.descripcion,
        'fecha_inicio', r.fecha_inicio,
        'fecha_fin', r.fecha_fin,

        'periodo_anio', r.periodo_anio,
        'periodo_mes', r.periodo_mes,

        'total_beneficiarios', r.total_beneficiarios,
        'total_participantes', r.total_participantes,
        'total_accesos', r.total_accesos,

        'esquema_demografico_id', r.esquema_demografico_id,

        'estatus', r.estatus,
        'origen', r.origen,
        'row_version', r.row_version,
        'created_by', r.created_by,
        'created_at', r.created_at,
        'updated_at', r.updated_at
      ),

      'config',
      pg_catalog.jsonb_build_object(
        'id', ca.id,
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
        'permite_offline', ca.permite_offline,
        'vigente_desde', ca.vigente_desde,
        'vigente_hasta', ca.vigente_hasta,
        'configuracion_extra', ca.configuracion_extra,
        'esquema_demografico_id', ca.esquema_demografico_id
      ),

      'responsable',
      CASE
        WHEN cp.id IS NULL THEN NULL
        ELSE pg_catalog.jsonb_build_object(
          'id', cp.id,
          'nombre', cp.nombre,
          'correo', cp.correo,
          'telefono', cp.telefono,
          'municipio_id', cp.municipio_id
        )
      END,

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
              'opcion_poblacion_id', rp.opcion_poblacion_id,
              'universo', rp.universo,
              'cantidad', rp.cantidad
            )
            ORDER BY rp.universo, rp.opcion_poblacion_id
          )
          FROM v2.registro_poblacion rp
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

      'permissions',
      pg_catalog.jsonb_build_object(
        'can_read', true,
        'can_edit',
          (
            r.origen = 'MANUAL'
            AND r.estatus IN ('BORRADOR', 'OBSERVADO', 'CORREGIDO')
            AND v2_private.can_edit_record(r.id)
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

  LEFT JOIN v2.cat_municipios m
    ON m.id = r.municipio_id

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
$$;


-- ============================================================================
-- 02. ACTUALIZAR BORRADOR
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_update_borrador(
  p_registro_id UUID,
  p_expected_row_version INTEGER,
  p_payload JSONB
)
RETURNS TABLE (
  id UUID,
  folio TEXT,
  estatus TEXT,
  row_version INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid                 UUID := auth.uid();
  v_record              RECORD;
  v_config              RECORD;

  v_nombre              TEXT;
  v_descripcion         TEXT;
  v_fecha_inicio        DATE;
  v_fecha_fin           DATE;

  v_municipio_id        UUID;
  v_espacio_id          UUID;

  v_total_beneficiarios INTEGER;
  v_total_participantes INTEGER;
  v_total_accesos       INTEGER;

  v_responsable         JSONB;
  v_responsable_id      UUID;
  v_resp_nombre         TEXT;
  v_resp_correo         TEXT;
  v_resp_telefono       TEXT;

  v_taller              JSONB;
  v_costo               NUMERIC(14,2);

  v_demo                JSONB;
  v_demo_item           JSONB;
  v_opcion_id           UUID;
  v_universo            TEXT;
  v_cantidad            INTEGER;

  v_new_version         INTEGER;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION
      'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  IF p_payload IS NULL
     OR pg_catalog.jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION
      'PAYLOAD_INVALID: se esperaba un objeto JSON.';
  END IF;

  SELECT *
  INTO v_record
  FROM v2.registros r
  WHERE r.id = p_registro_id
    AND r.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'RECORD_NOT_FOUND: registro inexistente.';
  END IF;

  IF v_record.origen <> 'MANUAL' THEN
    RAISE EXCEPTION
      'HISTORICAL_READ_ONLY: los registros migrados se conservan de solo lectura en esta fase.';
  END IF;

  IF v_record.estatus NOT IN ('BORRADOR', 'OBSERVADO', 'CORREGIDO') THEN
    RAISE EXCEPTION
      'STATUS_NOT_EDITABLE: el estado % no admite edición operativa.',
      v_record.estatus;
  END IF;

  IF NOT v2_private.can_edit_record(p_registro_id) THEN
    RAISE EXCEPTION
      'EDIT_FORBIDDEN: no tienes permiso para editar este registro.';
  END IF;

  IF p_expected_row_version IS NULL
     OR p_expected_row_version <> v_record.row_version THEN
    RAISE EXCEPTION
      'VERSION_CONFLICT: el registro cambió desde que lo abriste. Recarga antes de guardar.';
  END IF;

  SELECT *
  INTO v_config
  FROM v2.configuracion_acciones ca
  WHERE ca.id = v_record.configuracion_accion_id
    AND ca.accion_id = v_record.accion_id
    AND ca.activo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'CONFIG_INVALID: el registro ya no tiene una configuración activa.';
  END IF;


  -- --------------------------------------------------------------------------
  -- Campos núcleo
  -- --------------------------------------------------------------------------

  v_nombre :=
    NULLIF(
      pg_catalog.btrim(
        p_payload ->> 'nombre'
      ),
      ''
    );

  v_descripcion :=
    NULLIF(
      pg_catalog.btrim(
        p_payload ->> 'descripcion'
      ),
      ''
    );

  v_fecha_inicio :=
    NULLIF(
      p_payload ->> 'fecha_inicio',
      ''
    )::DATE;

  v_fecha_fin :=
    COALESCE(
      NULLIF(
        p_payload ->> 'fecha_fin',
        ''
      )::DATE,
      v_fecha_inicio
    );

  v_municipio_id :=
    NULLIF(
      p_payload ->> 'municipio_id',
      ''
    )::UUID;

  v_espacio_id :=
    NULLIF(
      p_payload ->> 'espacio_id',
      ''
    )::UUID;

  v_total_beneficiarios :=
    NULLIF(
      p_payload ->> 'total_beneficiarios',
      ''
    )::INTEGER;

  v_total_participantes :=
    NULLIF(
      p_payload ->> 'total_participantes',
      ''
    )::INTEGER;

  v_total_accesos :=
    NULLIF(
      p_payload ->> 'total_accesos',
      ''
    )::INTEGER;

  IF v_nombre IS NULL
     OR v_fecha_inicio IS NULL THEN
    RAISE EXCEPTION
      'REQUIRED_FIELDS: nombre y fecha de inicio son obligatorios.';
  END IF;

  IF v_fecha_fin < v_fecha_inicio THEN
    RAISE EXCEPTION
      'DATE_RANGE_INVALID: fecha de término anterior a fecha de inicio.';
  END IF;

  IF v_fecha_inicio < v_config.vigente_desde
     OR (
       v_config.vigente_hasta IS NOT NULL
       AND v_fecha_inicio > v_config.vigente_hasta
     ) THEN
    RAISE EXCEPTION
      'CONFIG_DATE_INVALID: la fecha ya no corresponde a la configuración de la acción.';
  END IF;

  IF COALESCE(v_total_beneficiarios, 0) < 0
     OR COALESCE(v_total_participantes, 0) < 0
     OR COALESCE(v_total_accesos, 0) < 0 THEN
    RAISE EXCEPTION
      'TOTAL_INVALID: los totales no pueden ser negativos.';
  END IF;

  IF v_municipio_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM v2.cat_municipios m
       WHERE m.id = v_municipio_id
         AND m.activo = true
     ) THEN
    RAISE EXCEPTION
      'MUNICIPALITY_INVALID: municipio inexistente o inactivo.';
  END IF;

  IF v_espacio_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM v2.cat_espacios e
       WHERE e.id = v_espacio_id
         AND e.activo = true
         AND (
           v_municipio_id IS NULL
           OR e.municipio_id = v_municipio_id
         )
     ) THEN
    RAISE EXCEPTION
      'SPACE_INVALID: el espacio no corresponde al municipio.';
  END IF;


  -- --------------------------------------------------------------------------
  -- Responsable
  -- --------------------------------------------------------------------------

  v_responsable :=
    COALESCE(
      p_payload -> 'responsable',
      '{}'::JSONB
    );

  v_resp_nombre :=
    NULLIF(
      pg_catalog.btrim(
        v_responsable ->> 'nombre'
      ),
      ''
    );

  v_resp_correo :=
    NULLIF(
      lower(
        pg_catalog.btrim(
          v_responsable ->> 'correo'
        )
      ),
      ''
    );

  v_resp_telefono :=
    NULLIF(
      pg_catalog.btrim(
        v_responsable ->> 'telefono'
      ),
      ''
    );

  v_responsable_id := NULL;

  IF v_resp_nombre IS NOT NULL THEN
    IF v_resp_correo IS NOT NULL THEN
      SELECT cp.id
      INTO v_responsable_id
      FROM v2.cat_personas cp
      WHERE cp.activo = true
        AND lower(pg_catalog.btrim(cp.correo)) = v_resp_correo
      ORDER BY cp.created_at
      LIMIT 1;
    END IF;

    IF v_responsable_id IS NULL THEN
      SELECT cp.id
      INTO v_responsable_id
      FROM v2.cat_personas cp
      WHERE cp.activo = true
        AND lower(pg_catalog.btrim(cp.nombre))
            = lower(v_resp_nombre)
        AND (
          cp.municipio_id IS NOT DISTINCT FROM v_municipio_id
          OR cp.municipio_id IS NULL
        )
      ORDER BY
        CASE
          WHEN cp.municipio_id IS NOT DISTINCT FROM v_municipio_id
          THEN 0
          ELSE 1
        END,
        cp.created_at
      LIMIT 1;
    END IF;

    IF v_responsable_id IS NULL THEN
      INSERT INTO v2.cat_personas (
        nombre,
        correo,
        telefono,
        municipio_id,
        activo,
        created_by,
        updated_by
      )
      VALUES (
        v_resp_nombre,
        v_resp_correo,
        v_resp_telefono,
        v_municipio_id,
        true,
        v_uid,
        v_uid
      )
      RETURNING v2.cat_personas.id
      INTO v_responsable_id;
    END IF;
  END IF;


  -- --------------------------------------------------------------------------
  -- UPDATE núcleo
  -- --------------------------------------------------------------------------

  UPDATE v2.registros r
  SET
    municipio_id = v_municipio_id,
    espacio_id = v_espacio_id,
    responsable_id = v_responsable_id,

    nombre = v_nombre,
    descripcion = v_descripcion,

    fecha_inicio = v_fecha_inicio,
    fecha_fin = v_fecha_fin,

    periodo_anio =
      EXTRACT(YEAR FROM v_fecha_inicio)::INTEGER,

    periodo_mes =
      EXTRACT(MONTH FROM v_fecha_inicio)::SMALLINT,

    total_beneficiarios =
      v_total_beneficiarios,

    total_participantes =
      v_total_participantes,

    total_accesos =
      v_total_accesos,

    updated_by = v_uid
  WHERE r.id = p_registro_id
  RETURNING r.row_version
  INTO v_new_version;


  -- --------------------------------------------------------------------------
  -- Taller / capacitación
  -- --------------------------------------------------------------------------

  v_taller :=
    COALESCE(
      p_payload -> 'taller',
      '{}'::JSONB
    );

  IF upper(COALESCE(v_config.tipo_formulario, ''))
     IN ('TALLER', 'CAPACITACION') THEN

    v_costo :=
      NULLIF(
        v_taller ->> 'costo',
        ''
      )::NUMERIC(14,2);

    IF v_costo IS NOT NULL
       AND v_costo < 0 THEN
      RAISE EXCEPTION
        'COST_INVALID: el costo no puede ser negativo.';
    END IF;

    INSERT INTO v2.registro_taller (
      registro_id,
      disciplina,
      programacion,
      modalidad_cuota,
      costo,
      moneda,
      observaciones,
      created_by,
      updated_by
    )
    VALUES (
      p_registro_id,

      NULLIF(
        pg_catalog.btrim(
          v_taller ->> 'disciplina'
        ),
        ''
      ),

      NULLIF(
        pg_catalog.btrim(
          v_taller ->> 'programacion'
        ),
        ''
      ),

      NULLIF(
        pg_catalog.btrim(
          v_taller ->> 'modalidad_cuota'
        ),
        ''
      ),

      v_costo,
      'MXN',

      NULLIF(
        pg_catalog.btrim(
          v_taller ->> 'observaciones'
        ),
        ''
      ),

      v_uid,
      v_uid
    )
    ON CONFLICT (registro_id)
    DO UPDATE SET
      disciplina = EXCLUDED.disciplina,
      programacion = EXCLUDED.programacion,
      modalidad_cuota = EXCLUDED.modalidad_cuota,
      costo = EXCLUDED.costo,
      moneda = EXCLUDED.moneda,
      observaciones = EXCLUDED.observaciones,
      updated_by = v_uid;
  END IF;


  -- --------------------------------------------------------------------------
  -- Demografía: reemplazo completo
  -- --------------------------------------------------------------------------

  v_demo :=
    COALESCE(
      p_payload -> 'demografia',
      '[]'::JSONB
    );

  IF pg_catalog.jsonb_typeof(v_demo) <> 'array' THEN
    RAISE EXCEPTION
      'DEMOGRAPHY_INVALID: demografia debe ser arreglo JSON.';
  END IF;

  DELETE FROM v2.registro_poblacion rp
  WHERE rp.registro_id = p_registro_id;

  FOR v_demo_item
  IN
    SELECT value
    FROM pg_catalog.jsonb_array_elements(v_demo)
  LOOP
    v_opcion_id :=
      NULLIF(
        v_demo_item ->> 'opcion_poblacion_id',
        ''
      )::UUID;

    v_universo :=
      upper(
        NULLIF(
          pg_catalog.btrim(
            v_demo_item ->> 'universo'
          ),
          ''
        )
      );

    v_cantidad :=
      NULLIF(
        v_demo_item ->> 'cantidad',
        ''
      )::INTEGER;

    IF v_opcion_id IS NULL
       OR v_universo IS NULL
       OR v_cantidad IS NULL THEN
      RAISE EXCEPTION
        'DEMOGRAPHY_ROW_INVALID: faltan opción, universo o cantidad.';
    END IF;

    IF v_universo NOT IN (
      'BENEFICIARIOS',
      'PARTICIPANTES',
      'ACCESOS'
    ) THEN
      RAISE EXCEPTION
        'DEMOGRAPHY_UNIVERSE_INVALID: universo % no permitido.',
        v_universo;
    END IF;

    IF v_cantidad <= 0 THEN
      CONTINUE;
    END IF;

    IF v_record.esquema_demografico_id IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM v2.esquema_opciones_poblacion eo
         WHERE eo.esquema_id =
               v_record.esquema_demografico_id
           AND eo.opcion_poblacion_id =
               v_opcion_id
           AND eo.activo = true
       ) THEN
      RAISE EXCEPTION
        'DEMOGRAPHY_OPTION_INVALID: opción fuera del esquema del registro.';
    END IF;

    INSERT INTO v2.registro_poblacion (
      registro_id,
      opcion_poblacion_id,
      universo,
      cantidad,
      observaciones,
      created_by
    )
    VALUES (
      p_registro_id,
      v_opcion_id,
      v_universo,
      v_cantidad,
      'Edición directa V2; valor no inferido.',
      v_uid
    );
  END LOOP;


  RETURN QUERY
  SELECT
    p_registro_id,
    v_record.folio,
    v_record.estatus,
    v_new_version;
END;
$$;


-- ============================================================================
-- 03. ENVIAR A REVISIÓN
--
-- BORRADOR:
--   BORRADOR -> CAPTURADO -> EN_REVISION
--
-- CORREGIDO:
--   CORREGIDO -> EN_REVISION
--
-- Los triggers existentes:
--   - validan ambas transiciones
--   - incrementan row_version
--   - escriben historial de validación
--   - escriben auditoría
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_submit_borrador(
  p_registro_id UUID,
  p_expected_row_version INTEGER
)
RETURNS TABLE (
  id UUID,
  folio TEXT,
  estatus TEXT,
  row_version INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       UUID := auth.uid();
  v_record    RECORD;
  v_config    RECORD;
  v_issues    TEXT[] := ARRAY[]::TEXT[];
  v_version   INTEGER;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION
      'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  SELECT *
  INTO v_record
  FROM v2.registros r
  WHERE r.id = p_registro_id
    AND r.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'RECORD_NOT_FOUND: registro inexistente.';
  END IF;

  IF v_record.origen <> 'MANUAL' THEN
    RAISE EXCEPTION
      'HISTORICAL_READ_ONLY: un histórico migrado no se envía a revisión desde este flujo.';
  END IF;

  IF v_record.estatus NOT IN ('BORRADOR', 'CORREGIDO') THEN
    RAISE EXCEPTION
      'STATUS_NOT_SUBMITTABLE: estado % no enviable a revisión.',
      v_record.estatus;
  END IF;

  IF NOT v2_private.can_edit_record(p_registro_id) THEN
    RAISE EXCEPTION
      'SUBMIT_FORBIDDEN: no tienes permiso para enviar este registro.';
  END IF;

  IF p_expected_row_version IS NULL
     OR p_expected_row_version <> v_record.row_version THEN
    RAISE EXCEPTION
      'VERSION_CONFLICT: el registro cambió. Recarga antes de enviar.';
  END IF;

  SELECT *
  INTO v_config
  FROM v2.configuracion_acciones ca
  WHERE ca.id = v_record.configuracion_accion_id
    AND ca.accion_id = v_record.accion_id;

  IF NOT FOUND THEN
    v_issues :=
      pg_catalog.array_append(
        v_issues,
        'SIN_CONFIGURACION_ACCION'
      );
  ELSE
    IF v_config.requiere_municipio
       AND v_record.municipio_id IS NULL THEN
      v_issues :=
        pg_catalog.array_append(
          v_issues,
          'SIN_MUNICIPIO'
        );
    END IF;

    IF v_config.requiere_comunidad
       AND v_record.comunidad_id IS NULL THEN
      v_issues :=
        pg_catalog.array_append(
          v_issues,
          'SIN_COMUNIDAD'
        );
    END IF;

    IF v_config.requiere_espacio
       AND v_record.espacio_id IS NULL THEN
      v_issues :=
        pg_catalog.array_append(
          v_issues,
          'SIN_ESPACIO'
        );
    END IF;

    IF v_config.requiere_responsable
       AND v_record.responsable_id IS NULL THEN
      v_issues :=
        pg_catalog.array_append(
          v_issues,
          'SIN_RESPONSABLE'
        );
    END IF;

    IF v_config.requiere_beneficiarios
       AND v_record.total_beneficiarios IS NULL THEN
      v_issues :=
        pg_catalog.array_append(
          v_issues,
          'SIN_TOTAL_BENEFICIARIOS'
        );
    END IF;

    IF v_config.requiere_demografia
       AND NOT EXISTS (
         SELECT 1
         FROM v2.registro_poblacion rp
         WHERE rp.registro_id = p_registro_id
       ) THEN
      v_issues :=
        pg_catalog.array_append(
          v_issues,
          'SIN_DEMOGRAFIA'
        );
    END IF;

    IF v_config.requiere_evidencia
       AND NOT EXISTS (
         SELECT 1
         FROM v2.registro_evidencias re
         WHERE re.registro_id = p_registro_id
           AND re.activo = true
       ) THEN
      v_issues :=
        pg_catalog.array_append(
          v_issues,
          'SIN_EVIDENCIA'
        );
    END IF;
  END IF;

  IF v_record.folio IS NULL
     OR pg_catalog.btrim(v_record.folio) = '' THEN
    v_issues :=
      pg_catalog.array_append(
        v_issues,
        'SIN_FOLIO'
      );
  END IF;

  IF v_record.nombre IS NULL
     OR pg_catalog.btrim(v_record.nombre) = '' THEN
    v_issues :=
      pg_catalog.array_append(
        v_issues,
        'SIN_NOMBRE'
      );
  END IF;

  IF pg_catalog.cardinality(v_issues) > 0 THEN
    RAISE EXCEPTION
      'QUALITY_BLOCK: %',
      pg_catalog.array_to_string(
        v_issues,
        ', '
      );
  END IF;

  IF v_record.estatus = 'BORRADOR' THEN
    UPDATE v2.registros
    SET
      estatus = 'CAPTURADO',
      updated_by = v_uid
    WHERE id = p_registro_id;

    UPDATE v2.registros
    SET
      estatus = 'EN_REVISION',
      updated_by = v_uid
    WHERE id = p_registro_id
    RETURNING row_version
    INTO v_version;

  ELSE
    UPDATE v2.registros
    SET
      estatus = 'EN_REVISION',
      updated_by = v_uid
    WHERE id = p_registro_id
    RETURNING row_version
    INTO v_version;
  END IF;

  RETURN QUERY
  SELECT
    p_registro_id,
    v_record.folio,
    'EN_REVISION'::TEXT,
    v_version;
END;
$$;


-- ============================================================================
-- 04. PERMISOS
-- ============================================================================

REVOKE ALL
ON FUNCTION v2.rpc_get_registro_editor(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION v2.rpc_get_registro_editor(UUID)
TO authenticated;


REVOKE ALL
ON FUNCTION v2.rpc_update_borrador(UUID, INTEGER, JSONB)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION v2.rpc_update_borrador(UUID, INTEGER, JSONB)
TO authenticated;


REVOKE ALL
ON FUNCTION v2.rpc_submit_borrador(UUID, INTEGER)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION v2.rpc_submit_borrador(UUID, INTEGER)
TO authenticated;


-- ============================================================================
-- 05. REGISTRO
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.12d',
  '12d_draft_workflow.sql - Editor seguro de borradores, responsable, demografía y envío transaccional a revisión.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;


-- ============================================================================
-- 06. VERIFICACIÓN
--
-- Esperado:
-- true | true | true | false | false | false | 1
-- ============================================================================

SELECT
  (
    to_regprocedure(
      'v2.rpc_get_registro_editor(uuid)'
    ) IS NOT NULL
  ) AS rpc_editor,

  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.rpc_get_registro_editor(uuid)',
    'EXECUTE'
  ) AS authenticated_editor,

  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.rpc_update_borrador(uuid,integer,jsonb)',
    'EXECUTE'
  ) AS authenticated_update,

  pg_catalog.has_function_privilege(
    'anon',
    'v2.rpc_get_registro_editor(uuid)',
    'EXECUTE'
  ) AS anon_editor,

  pg_catalog.has_function_privilege(
    'anon',
    'v2.rpc_update_borrador(uuid,integer,jsonb)',
    'EXECUTE'
  ) AS anon_update,

  pg_catalog.has_function_privilege(
    'anon',
    'v2.rpc_submit_borrador(uuid,integer)',
    'EXECUTE'
  ) AS anon_submit,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12d'
  ) AS migracion_registrada;
