-- ============================================================================
-- ETAPA 7.2.3 - CAPTURA INTEGRAL, RESPONSABLE Y POBLACION DECLARADA
-- Ejecutar una sola vez en Supabase SQL Editor.
-- Requiere la Etapa 7.2.2 (12t_community_capture.sql).
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('v2.rpc_create_borrador_con_comunidad(jsonb)') IS NULL
     OR to_regclass('v2.cat_personas') IS NULL
     OR to_regclass('v2.registros') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION: aplica primero la Etapa 7.2.2 y el flujo de borradores V2.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION v2_private.resolver_responsable_captura(
  p_responsable JSONB,
  p_municipio_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_nombre TEXT;
  v_correo TEXT;
  v_telefono TEXT;
  v_id UUID;
BEGIN
  v_nombre := NULLIF(pg_catalog.btrim(p_responsable ->> 'nombre'), '');
  v_correo := NULLIF(lower(pg_catalog.btrim(p_responsable ->> 'correo')), '');
  v_telefono := NULLIF(pg_catalog.btrim(p_responsable ->> 'telefono'), '');

  IF v_nombre IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_correo IS NOT NULL THEN
    SELECT p.id INTO v_id
    FROM v2.cat_personas p
    WHERE p.activo = true
      AND lower(pg_catalog.btrim(p.correo)) = v_correo
    ORDER BY p.created_at
    LIMIT 1;
  END IF;

  IF v_id IS NULL THEN
    SELECT p.id INTO v_id
    FROM v2.cat_personas p
    WHERE p.activo = true
      AND lower(pg_catalog.btrim(p.nombre)) = lower(v_nombre)
      AND (
        p.municipio_id IS NOT DISTINCT FROM p_municipio_id
        OR p.municipio_id IS NULL
      )
    ORDER BY
      CASE WHEN p.municipio_id IS NOT DISTINCT FROM p_municipio_id THEN 0 ELSE 1 END,
      p.created_at
    LIMIT 1;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO v2.cat_personas (
      nombre, correo, telefono, municipio_id,
      activo, created_by, updated_by
    ) VALUES (
      v_nombre, v_correo, v_telefono, p_municipio_id,
      true, v_uid, v_uid
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE v2.cat_personas p
    SET correo = COALESCE(v_correo, p.correo),
        telefono = COALESCE(v_telefono, p.telefono),
        updated_by = v_uid,
        updated_at = now()
    WHERE p.id = v_id;
  END IF;

  RETURN v_id;
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  IF p_payload IS NULL OR pg_catalog.jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'PAYLOAD_INVALID: se esperaba un objeto JSON.';
  END IF;

  v_municipio_id := NULLIF(p_payload ->> 'municipio_id', '')::UUID;

  SELECT c.id, c.folio, c.estatus
  INTO v_id, v_folio, v_estatus
  FROM v2.rpc_create_borrador_con_comunidad(p_payload) c;

  v_responsable_id := v2_private.resolver_responsable_captura(
    COALESCE(p_payload -> 'responsable', '{}'::JSONB),
    v_municipio_id
  );

  UPDATE v2.registros r
  SET responsable_id = v_responsable_id,
      metadata = COALESCE(r.metadata, '{}'::JSONB) ||
        pg_catalog.jsonb_build_object(
          'captura_integral',
          pg_catalog.jsonb_build_object(
            'version', '7.2.3',
            'responsable_capturado', v_responsable_id IS NOT NULL,
            'guardado_en', now()
          )
        ),
      updated_by = auth.uid(),
      updated_at = now()
  WHERE r.id = v_id;

  RETURN QUERY SELECT v_id, v_folio, v_estatus;
END;
$$;

REVOKE ALL ON FUNCTION v2_private.resolver_responsable_captura(JSONB, UUID)
FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_create_borrador_integral(JSONB)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION v2.rpc_create_borrador_integral(JSONB)
TO authenticated;

INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12u',
  '12u_integral_capture.sql - Captura inicial integral con responsable y metadatos de poblacion declarada.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- Verificación esperada: true | true | false | 1
SELECT
  to_regprocedure('v2.rpc_create_borrador_integral(jsonb)') IS NOT NULL AS crear_integral,
  pg_catalog.has_function_privilege(
    'authenticated', 'v2.rpc_create_borrador_integral(jsonb)', 'EXECUTE'
  ) AS authenticated_execute,
  pg_catalog.has_function_privilege(
    'anon', 'v2.rpc_create_borrador_integral(jsonb)', 'EXECUTE'
  ) AS anon_execute,
  (
    SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12u'
  ) AS migracion_registrada;
