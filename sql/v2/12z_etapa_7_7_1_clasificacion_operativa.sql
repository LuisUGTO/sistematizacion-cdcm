-- ============================================================================
-- ETAPA 7.7.1 - CLASIFICACIÓN OPERATIVA DE ACTIVIDADES
-- Ejecutar una sola vez en Supabase SQL Editor.
-- Requiere las etapas 7.2.2 y 7.2.3.
--
-- Conserva los registros históricos sin modificación y añade una clasificación
-- opcional, trazable y editable para nuevas capturas y borradores.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regprocedure('v2.rpc_create_borrador_con_comunidad(jsonb)') IS NULL
     OR to_regprocedure('v2.rpc_update_borrador(jsonb)') IS NOT NULL THEN
    NULL;
  END IF;

  IF to_regprocedure('v2.rpc_create_borrador_con_comunidad(jsonb)') IS NULL
     OR to_regprocedure('v2.rpc_update_borrador(uuid,integer,jsonb)') IS NULL
     OR to_regprocedure('v2.rpc_get_registro_editor(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PRECONDICION: aplica primero las etapas de borradores, comunidad y captura integral.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION v2_private.normalizar_clasificacion_operativa(
  p_metadata JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_raw JSONB := COALESCE(p_metadata -> 'clasificacion_operativa', '{}'::JSONB);
  v_formato TEXT;
  v_temporalidad TEXT;
  v_sesiones INTEGER;
BEGIN
  IF jsonb_typeof(v_raw) <> 'object' THEN
    RAISE EXCEPTION 'CLASSIFICATION_INVALID: la clasificación operativa debe ser un objeto.';
  END IF;

  v_formato := NULLIF(upper(pg_catalog.btrim(v_raw ->> 'formato')), '');
  v_temporalidad := NULLIF(upper(pg_catalog.btrim(v_raw ->> 'temporalidad')), '');
  v_sesiones := NULLIF(v_raw ->> 'total_sesiones', '')::INTEGER;

  IF v_formato IS NOT NULL AND v_formato NOT IN ('PRESENCIAL', 'VIRTUAL', 'HIBRIDO') THEN
    RAISE EXCEPTION 'FORMAT_INVALID: formato permitido: presencial, virtual o híbrido.';
  END IF;

  IF v_temporalidad IS NOT NULL AND v_temporalidad NOT IN ('UNICA', 'SEMANAL', 'MENSUAL', 'TEMPORAL', 'PERMANENTE', 'OTRA') THEN
    RAISE EXCEPTION 'TEMPORALITY_INVALID: temporalidad no reconocida.';
  END IF;

  IF v_sesiones IS NOT NULL AND (v_sesiones < 1 OR v_sesiones > 1000) THEN
    RAISE EXCEPTION 'SESSIONS_INVALID: el número de sesiones debe estar entre 1 y 1000.';
  END IF;

  RETURN pg_catalog.jsonb_strip_nulls(
    pg_catalog.jsonb_build_object(
      'tipo_actividad', NULLIF(pg_catalog.left(pg_catalog.btrim(v_raw ->> 'tipo_actividad'), 160), ''),
      'formato', v_formato,
      'temporalidad', v_temporalidad,
      'total_sesiones', v_sesiones,
      'disciplina', NULLIF(pg_catalog.left(pg_catalog.btrim(v_raw ->> 'disciplina'), 160), ''),
      'subdisciplina', NULLIF(pg_catalog.left(pg_catalog.btrim(v_raw ->> 'subdisciplina'), 160), '')
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION v2.rpc_create_borrador_integral(
  p_payload JSONB
)
RETURNS TABLE (id UUID, folio TEXT, estatus TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id UUID;
  v_folio TEXT;
  v_estatus TEXT;
  v_municipio_id UUID;
  v_responsable_id UUID;
  v_metadata JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;
  IF p_payload IS NULL OR pg_catalog.jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'PAYLOAD_INVALID: se esperaba un objeto JSON.';
  END IF;

  v_metadata := COALESCE(p_payload -> 'metadata', '{}'::JSONB);
  p_payload := pg_catalog.jsonb_set(
    p_payload,
    '{metadata,clasificacion_operativa}',
    v2_private.normalizar_clasificacion_operativa(v_metadata),
    true
  );
  v_municipio_id := NULLIF(p_payload ->> 'municipio_id', '')::UUID;

  SELECT c.id, c.folio, c.estatus INTO v_id, v_folio, v_estatus
  FROM v2.rpc_create_borrador_con_comunidad(p_payload) c;

  v_responsable_id := v2_private.resolver_responsable_captura(
    COALESCE(p_payload -> 'responsable', '{}'::JSONB), v_municipio_id
  );

  UPDATE v2.registros r
  SET responsable_id = v_responsable_id,
      metadata = COALESCE(r.metadata, '{}'::JSONB) || pg_catalog.jsonb_build_object(
        'captura_integral', pg_catalog.jsonb_build_object(
          'version', '7.7.1',
          'responsable_capturado', v_responsable_id IS NOT NULL,
          'guardado_en', now()
        )
      ),
      updated_by = auth.uid(), updated_at = now()
  WHERE r.id = v_id;

  RETURN QUERY SELECT v_id, v_folio, v_estatus;
END;
$$;

CREATE OR REPLACE FUNCTION v2.rpc_update_borrador_con_comunidad(
  p_registro_id UUID,
  p_expected_row_version INTEGER,
  p_payload JSONB
)
RETURNS TABLE (id UUID, folio TEXT, estatus TEXT, row_version INTEGER)
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
  v_classification JSONB;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.'; END IF;

  SELECT r.configuracion_accion_id INTO v_config_id
  FROM v2.registros r WHERE r.id = p_registro_id AND r.deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'RECORD_NOT_FOUND: registro inexistente.'; END IF;

  v_comunidad_id := v2_private.validar_comunidad_payload(p_payload, v_config_id);
  v_classification := v2_private.normalizar_clasificacion_operativa(COALESCE(p_payload -> 'metadata', '{}'::JSONB));

  SELECT u.id, u.folio, u.estatus, u.row_version INTO v_id, v_folio, v_estatus, v_old_version
  FROM v2.rpc_update_borrador(p_registro_id, p_expected_row_version, p_payload) u;

  UPDATE v2.registros
  SET comunidad_id = v_comunidad_id,
      metadata = pg_catalog.jsonb_set(COALESCE(metadata, '{}'::JSONB), '{clasificacion_operativa}', v_classification, true),
      updated_by = auth.uid(), updated_at = now()
  WHERE id = v_id;

  SELECT r.row_version INTO v_final_version FROM v2.registros r WHERE r.id = v_id;
  RETURN QUERY SELECT v_id, v_folio, v_estatus, COALESCE(v_final_version, v_old_version);
END;
$$;

CREATE OR REPLACE FUNCTION v2.rpc_get_registro_editor_con_comunidad(
  p_registro_id UUID
)
RETURNS TABLE (payload JSONB)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_payload JSONB;
  v_comunidad_id UUID;
  v_comunidad_nombre TEXT;
  v_metadata JSONB;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.'; END IF;
  SELECT e.payload INTO v_payload FROM v2.rpc_get_registro_editor(p_registro_id) e;
  SELECT r.comunidad_id, c.nombre, r.metadata INTO v_comunidad_id, v_comunidad_nombre, v_metadata
  FROM v2.registros r LEFT JOIN v2.cat_comunidades c ON c.id = r.comunidad_id WHERE r.id = p_registro_id;
  v_payload := pg_catalog.jsonb_set(v_payload, '{record,comunidad_id}', COALESCE(pg_catalog.to_jsonb(v_comunidad_id), 'null'::JSONB), true);
  v_payload := pg_catalog.jsonb_set(v_payload, '{record,comunidad_nombre}', COALESCE(pg_catalog.to_jsonb(v_comunidad_nombre), 'null'::JSONB), true);
  v_payload := pg_catalog.jsonb_set(v_payload, '{record,metadata}', COALESCE(v_metadata, '{}'::JSONB), true);
  RETURN QUERY SELECT v_payload;
END;
$$;

REVOKE ALL ON FUNCTION v2_private.normalizar_clasificacion_operativa(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_create_borrador_integral(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_update_borrador_con_comunidad(UUID, INTEGER, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_get_registro_editor_con_comunidad(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION v2.rpc_create_borrador_integral(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_update_borrador_con_comunidad(UUID, INTEGER, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_get_registro_editor_con_comunidad(UUID) TO authenticated;

INSERT INTO v2.schema_migrations (version, descripcion)
VALUES ('2.1.12z', '12z_etapa_7_7_1_clasificacion_operativa.sql - Clasificación operativa opcional para actividades.')
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  to_regprocedure('v2.rpc_create_borrador_integral(jsonb)') IS NOT NULL AS captura_integral_lista,
  to_regprocedure('v2.rpc_update_borrador_con_comunidad(uuid,integer,jsonb)') IS NOT NULL AS edicion_lista,
  to_regprocedure('v2.rpc_get_registro_editor_con_comunidad(uuid)') IS NOT NULL AS lectura_lista,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12z') AS migracion_registrada;
