-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 12f_validation_workflow.sql
-- Fase 5: validación institucional, observaciones y corrección
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   12d_draft_workflow.sql
--   12e_hotfix_submit_ambiguous_id.sql
--
-- IMPLEMENTA:
--   ✓ detalle seguro para revisor ADMIN/SUPERVISOR
--   ✓ VALIDAR: EN_REVISION -> VALIDADO
--   ✓ OBSERVAR: EN_REVISION -> OBSERVADO con observación obligatoria
--   ✓ historial con observación en la MISMA transición generada por trigger
--   ✓ concurrencia optimista row_version
--   ✓ bloqueo de VALIDADO si vw_calidad_datos todavía reporta incidencias
--   ✓ CORREGIDO para el flujo del capturista
--   ✓ preview de indicadores vinculados a la acción
--
-- SEGURIDAD:
--   ✓ RPC SECURITY DEFINER con search_path vacío
--   ✓ decisión únicamente ADMIN o SUPERVISOR
--   ✓ SUPERVISOR limitado por can_manage_record() / scopes
--   ✓ anon sin EXECUTE
--   ✓ históricos no se alteran desde el flujo de corrección
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
     OR to_regclass('v2.registro_validaciones') IS NULL
     OR to_regclass('v2.registro_evidencias') IS NULL
     OR to_regclass('v2.accion_indicador') IS NULL
     OR to_regclass('v2.indicadores_version') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos V2 requeridos para validación.';
  END IF;

  IF to_regprocedure('v2_private.can_manage_record(uuid)') IS NULL
     OR to_regprocedure('v2_private.can_edit_record(uuid)') IS NULL
     OR to_regprocedure('v2_private.current_role()') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan helpers de autorización de 06_rls.sql.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.12e'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 12e_hotfix_submit_ambiguous_id.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. HISTORIAL: CAPTURAR OBSERVACIÓN DE LA TRANSICIÓN
--
-- La tabla registro_validaciones sigue siendo escrita por trigger.
-- La RPC coloca temporalmente la observación en una variable de transacción:
--
--   v2.validation_observation
--
-- y el trigger la incorpora a la misma fila de historial del cambio de estado.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.log_registro_validation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_observacion TEXT;
BEGIN
  v_observacion :=
    NULLIF(
      pg_catalog.btrim(
        pg_catalog.current_setting(
          'v2.validation_observation',
          true
        )
      ),
      ''
    );

  IF TG_OP = 'INSERT' THEN

    INSERT INTO v2.registro_validaciones (
      registro_id,
      estatus_anterior,
      estatus_nuevo,
      observacion,
      usuario_id,
      created_at
    )
    VALUES (
      NEW.id,
      NULL,
      NEW.estatus,
      'Estatus inicial del registro.',
      auth.uid(),
      pg_catalog.now()
    );

  ELSIF TG_OP = 'UPDATE'
        AND NEW.estatus IS DISTINCT FROM OLD.estatus THEN

    INSERT INTO v2.registro_validaciones (
      registro_id,
      estatus_anterior,
      estatus_nuevo,
      observacion,
      usuario_id,
      created_at
    )
    VALUES (
      NEW.id,
      OLD.estatus,
      NEW.estatus,
      v_observacion,
      auth.uid(),
      pg_catalog.now()
    );

  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL
ON FUNCTION v2.log_registro_validation()
FROM PUBLIC, anon, authenticated;


-- ============================================================================
-- 02. DETALLE SEGURO PARA VALIDACIÓN
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_get_registro_validacion(
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
  v_uid  UUID := auth.uid();
  v_role TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION
      'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  v_role := v2_private.current_role();

  IF v_role NOT IN ('ADMIN', 'SUPERVISOR') THEN
    RAISE EXCEPTION
      'VALIDATION_ROLE_REQUIRED: solo ADMIN/SUPERVISOR pueden revisar.';
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
$$;


-- ============================================================================
-- 03. DECISIÓN DEL REVISOR
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_decide_validacion(
  p_registro_id UUID,
  p_expected_row_version INTEGER,
  p_decision TEXT,
  p_observacion TEXT DEFAULT NULL
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

  IF v_role NOT IN ('ADMIN', 'SUPERVISOR') THEN
    RAISE EXCEPTION
      'VALIDATION_ROLE_REQUIRED: solo ADMIN/SUPERVISOR pueden decidir.';
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
$$;


-- ============================================================================
-- 04. MARCAR CORRECCIÓN
--
-- Se llama DESPUÉS de que rpc_update_borrador guardó los cambios de un
-- registro OBSERVADO. Así el capturista obtiene:
--
--   OBSERVADO -> CORREGIDO
--
-- y después puede usar rpc_submit_borrador:
--
--   CORREGIDO -> EN_REVISION
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_mark_corregido(
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
  v_uid     UUID := auth.uid();
  v_record  RECORD;
  v_version INTEGER;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION
      'AUTH_REQUIRED: se requiere una sesión autenticada.';
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

  IF v_record.origen <> 'MANUAL' THEN
    RAISE EXCEPTION
      'HISTORICAL_READ_ONLY: un histórico migrado no entra al flujo de corrección.';
  END IF;

  IF v_record.estatus <> 'OBSERVADO' THEN
    RAISE EXCEPTION
      'STATUS_NOT_OBSERVED: se esperaba OBSERVADO y se encontró %.',
      v_record.estatus;
  END IF;

  IF NOT v2_private.can_edit_record(p_registro_id) THEN
    RAISE EXCEPTION
      'CORRECTION_FORBIDDEN: no tienes permiso para corregir este registro.';
  END IF;

  IF p_expected_row_version IS NULL
     OR p_expected_row_version <> v_record.row_version THEN
    RAISE EXCEPTION
      'VERSION_CONFLICT: el registro cambió. Recarga antes de marcar la corrección.';
  END IF;

  PERFORM pg_catalog.set_config(
    'v2.validation_observation',
    'Correcciones registradas; el expediente queda listo para reenvío.',
    true
  );

  UPDATE v2.registros AS r
  SET
    estatus = 'CORREGIDO',
    updated_by = v_uid
  WHERE r.id = p_registro_id
  RETURNING r.row_version
  INTO v_version;

  RETURN QUERY
  SELECT
    p_registro_id,
    v_record.folio,
    'CORREGIDO'::TEXT,
    v_version;
END;
$$;


-- ============================================================================
-- 05. PERMISOS
-- ============================================================================

REVOKE ALL
ON FUNCTION v2.rpc_get_registro_validacion(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION v2.rpc_get_registro_validacion(UUID)
TO authenticated;


REVOKE ALL
ON FUNCTION v2.rpc_decide_validacion(UUID, INTEGER, TEXT, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION v2.rpc_decide_validacion(UUID, INTEGER, TEXT, TEXT)
TO authenticated;


REVOKE ALL
ON FUNCTION v2.rpc_mark_corregido(UUID, INTEGER)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION v2.rpc_mark_corregido(UUID, INTEGER)
TO authenticated;


-- ============================================================================
-- 06. REGISTRAR MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.12f',
  '12f_validation_workflow.sql - Bandeja de validación, decisión ADMIN/SUPERVISOR, observaciones persistentes y flujo OBSERVADO->CORREGIDO.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 07. VERIFICACIÓN
--
-- Esperado:
-- true | true | true | true | false | false | false | 1
-- ============================================================================

SELECT
  (
    to_regprocedure(
      'v2.rpc_get_registro_validacion(uuid)'
    ) IS NOT NULL
  ) AS rpc_detalle,

  (
    to_regprocedure(
      'v2.rpc_decide_validacion(uuid,integer,text,text)'
    ) IS NOT NULL
  ) AS rpc_decision,

  (
    to_regprocedure(
      'v2.rpc_mark_corregido(uuid,integer)'
    ) IS NOT NULL
  ) AS rpc_corregido,

  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.rpc_decide_validacion(uuid,integer,text,text)',
    'EXECUTE'
  ) AS authenticated_decision,

  pg_catalog.has_function_privilege(
    'anon',
    'v2.rpc_get_registro_validacion(uuid)',
    'EXECUTE'
  ) AS anon_detalle,

  pg_catalog.has_function_privilege(
    'anon',
    'v2.rpc_decide_validacion(uuid,integer,text,text)',
    'EXECUTE'
  ) AS anon_decision,

  pg_catalog.has_function_privilege(
    'anon',
    'v2.rpc_mark_corregido(uuid,integer)',
    'EXECUTE'
  ) AS anon_corregido,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12f'
  ) AS migracion_registrada;
