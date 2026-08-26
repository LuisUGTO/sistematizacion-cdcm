-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 12e_hotfix_submit_ambiguous_id.sql
-- Corrige referencias ambiguas en rpc_submit_borrador
-- Secretaría de Cultura de Guanajuato
--
-- CAUSA:
--   rpc_submit_borrador RETURNS TABLE incluye columnas de salida:
--     id, folio, estatus, row_version
--
--   En PL/pgSQL esos nombres también son variables de salida. Por eso:
--     WHERE id = ...
--     RETURNING row_version
--   pueden ser ambiguos frente a v2.registros.id / v2.registros.row_version.
--
-- CORRECCIÓN:
--   Se califican todas las columnas con alias de tabla.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';


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

  SELECT r.*
  INTO v_record
  FROM v2.registros AS r
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

  SELECT ca.*
  INTO v_config
  FROM v2.configuracion_acciones AS ca
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
         FROM v2.registro_poblacion AS rp
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
         FROM v2.registro_evidencias AS re
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

    UPDATE v2.registros AS r
    SET
      estatus = 'CAPTURADO',
      updated_by = v_uid
    WHERE r.id = p_registro_id;

    UPDATE v2.registros AS r
    SET
      estatus = 'EN_REVISION',
      updated_by = v_uid
    WHERE r.id = p_registro_id
    RETURNING r.row_version
    INTO v_version;

  ELSE

    UPDATE v2.registros AS r
    SET
      estatus = 'EN_REVISION',
      updated_by = v_uid
    WHERE r.id = p_registro_id
    RETURNING r.row_version
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


REVOKE ALL
ON FUNCTION v2.rpc_submit_borrador(UUID, INTEGER)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION v2.rpc_submit_borrador(UUID, INTEGER)
TO authenticated;


INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.12e',
  '12e_hotfix_submit_ambiguous_id.sql - Califica id y row_version en rpc_submit_borrador para eliminar ambigüedad PL/pgSQL.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- VERIFICACIÓN
--
-- Esperado:
-- true | true | false | 1
-- ============================================================================

SELECT
  (
    to_regprocedure(
      'v2.rpc_submit_borrador(uuid,integer)'
    ) IS NOT NULL
  ) AS rpc_submit_existe,

  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.rpc_submit_borrador(uuid,integer)',
    'EXECUTE'
  ) AS authenticated_execute,

  pg_catalog.has_function_privilege(
    'anon',
    'v2.rpc_submit_borrador(uuid,integer)',
    'EXECUTE'
  ) AS anon_execute,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12e'
  ) AS migracion_registrada;
