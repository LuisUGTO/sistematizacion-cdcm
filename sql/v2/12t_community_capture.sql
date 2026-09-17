-- ============================================================================
-- ETAPA 7.2.2 - COMUNIDADES EN CAPTURA Y EDICION DE BORRADORES
-- Ejecutar una sola vez en Supabase SQL Editor.
-- No sustituye ni requiere volver a ejecutar 02_catalogs.sql.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('v2.rpc_create_borrador(jsonb)') IS NULL
     OR to_regprocedure('v2.rpc_get_registro_editor(uuid)') IS NULL
     OR to_regprocedure('v2.rpc_update_borrador(uuid,integer,jsonb)') IS NULL
     OR to_regclass('v2.cat_comunidades') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION: aplica primero las etapas de captura, editor y catalogos V2.';
  END IF;
END;
$$;


-- Valida una comunidad del payload contra el municipio y la configuración.
CREATE OR REPLACE FUNCTION v2_private.validar_comunidad_payload(
  p_payload JSONB,
  p_configuracion_accion_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_comunidad_id UUID;
  v_municipio_id UUID;
  v_requiere BOOLEAN := false;
  v_comunidad_municipio UUID;
BEGIN
  v_comunidad_id := NULLIF(p_payload ->> 'comunidad_id', '')::UUID;
  v_municipio_id := NULLIF(p_payload ->> 'municipio_id', '')::UUID;

  SELECT ca.requiere_comunidad
  INTO v_requiere
  FROM v2.configuracion_acciones ca
  WHERE ca.id = p_configuracion_accion_id
    AND ca.activo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'CONFIG_INVALID: la configuración de la acción no existe o está inactiva.';
  END IF;

  IF v_requiere AND v_comunidad_id IS NULL THEN
    RAISE EXCEPTION
      'COMMUNITY_REQUIRED: selecciona la comunidad / localidad.';
  END IF;

  IF v_comunidad_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c.municipio_id
  INTO v_comunidad_municipio
  FROM v2.cat_comunidades c
  WHERE c.id = v_comunidad_id
    AND c.activo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'COMMUNITY_INVALID: la comunidad no existe o está inactiva.';
  END IF;

  IF v_municipio_id IS NULL
     OR v_comunidad_municipio IS DISTINCT FROM v_municipio_id THEN
    RAISE EXCEPTION
      'COMMUNITY_MUNICIPALITY_MISMATCH: la comunidad no pertenece al municipio seleccionado.';
  END IF;

  RETURN v_comunidad_id;
END;
$$;


CREATE OR REPLACE FUNCTION v2.rpc_create_borrador_con_comunidad(
  p_payload JSONB
)
RETURNS TABLE (
  id UUID,
  folio TEXT,
  estatus TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_config_id UUID;
  v_comunidad_id UUID;
  v_id UUID;
  v_folio TEXT;
  v_estatus TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  v_config_id :=
    NULLIF(p_payload ->> 'configuracion_accion_id', '')::UUID;

  v_comunidad_id :=
    v2_private.validar_comunidad_payload(
      p_payload,
      v_config_id
    );

  SELECT c.id, c.folio, c.estatus
  INTO v_id, v_folio, v_estatus
  FROM v2.rpc_create_borrador(p_payload) c;

  UPDATE v2.registros
  SET comunidad_id = v_comunidad_id,
      updated_by = auth.uid(),
      updated_at = now()
  WHERE v2.registros.id = v_id;

  RETURN QUERY
  SELECT v_id, v_folio, v_estatus;
END;
$$;


CREATE OR REPLACE FUNCTION v2.rpc_update_borrador_con_comunidad(
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
  v_config_id UUID;
  v_comunidad_id UUID;
  v_id UUID;
  v_folio TEXT;
  v_estatus TEXT;
  v_old_version INTEGER;
  v_final_version INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  SELECT r.configuracion_accion_id
  INTO v_config_id
  FROM v2.registros r
  WHERE r.id = p_registro_id
    AND r.deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RECORD_NOT_FOUND: registro inexistente.';
  END IF;

  v_comunidad_id :=
    v2_private.validar_comunidad_payload(
      p_payload,
      v_config_id
    );

  SELECT u.id, u.folio, u.estatus, u.row_version
  INTO v_id, v_folio, v_estatus, v_old_version
  FROM v2.rpc_update_borrador(
    p_registro_id,
    p_expected_row_version,
    p_payload
  ) u;

  UPDATE v2.registros
  SET comunidad_id = v_comunidad_id,
      updated_by = auth.uid(),
      updated_at = now()
  WHERE v2.registros.id = v_id;

  SELECT r.row_version
  INTO v_final_version
  FROM v2.registros r
  WHERE r.id = v_id;

  RETURN QUERY
  SELECT v_id, v_folio, v_estatus,
         COALESCE(v_final_version, v_old_version);
END;
$$;


CREATE OR REPLACE FUNCTION v2.rpc_get_registro_editor_con_comunidad(
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
  v_payload JSONB;
  v_comunidad_id UUID;
  v_comunidad_nombre TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  SELECT e.payload
  INTO v_payload
  FROM v2.rpc_get_registro_editor(p_registro_id) e;

  SELECT r.comunidad_id, c.nombre
  INTO v_comunidad_id, v_comunidad_nombre
  FROM v2.registros r
  LEFT JOIN v2.cat_comunidades c
    ON c.id = r.comunidad_id
  WHERE r.id = p_registro_id;

  v_payload := pg_catalog.jsonb_set(
    v_payload,
    '{record,comunidad_id}',
    COALESCE(pg_catalog.to_jsonb(v_comunidad_id), 'null'::JSONB),
    true
  );

  v_payload := pg_catalog.jsonb_set(
    v_payload,
    '{record,comunidad_nombre}',
    COALESCE(pg_catalog.to_jsonb(v_comunidad_nombre), 'null'::JSONB),
    true
  );

  RETURN QUERY SELECT v_payload;
END;
$$;


REVOKE ALL ON FUNCTION v2_private.validar_comunidad_payload(JSONB, UUID)
FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_create_borrador_con_comunidad(JSONB)
FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_update_borrador_con_comunidad(UUID, INTEGER, JSONB)
FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_get_registro_editor_con_comunidad(UUID)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION v2.rpc_create_borrador_con_comunidad(JSONB)
TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_update_borrador_con_comunidad(UUID, INTEGER, JSONB)
TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_get_registro_editor_con_comunidad(UUID)
TO authenticated;

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.12t',
  '12t_community_capture.sql - Comunidad dependiente de municipio en captura y edición de borradores.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;


-- Verificación esperada: true | true | true | true | false | 1
SELECT
  to_regprocedure('v2.rpc_create_borrador_con_comunidad(jsonb)') IS NOT NULL
    AS crear,
  to_regprocedure('v2.rpc_update_borrador_con_comunidad(uuid,integer,jsonb)') IS NOT NULL
    AS actualizar,
  to_regprocedure('v2.rpc_get_registro_editor_con_comunidad(uuid)') IS NOT NULL
    AS consultar,
  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.rpc_create_borrador_con_comunidad(jsonb)',
    'EXECUTE'
  ) AS authenticated_execute,
  pg_catalog.has_function_privilege(
    'anon',
    'v2.rpc_create_borrador_con_comunidad(jsonb)',
    'EXECUTE'
  ) AS anon_execute,
  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12t'
  ) AS migracion_registrada;
