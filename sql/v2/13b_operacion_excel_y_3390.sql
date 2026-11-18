-- ============================================================================
-- 13b_operacion_excel_y_3390.sql
-- RPCs seguras para:
--   1) Alta de comunidades/colonias en cascada desde captura municipal.
--   2) Baja lógica de borradores propios manuales al quitar una fila.
-- ADITIVO: no elimina ni altera datos existentes.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_registrar_asentamiento_captura(
  p_municipio_id UUID,
  p_tipo_clave   TEXT,
  p_nombre       TEXT
)
RETURNS TABLE (
  id             UUID,
  municipio_id   UUID,
  tipo_clave     TEXT,
  nombre         TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid           UUID := auth.uid();
  v_role          TEXT;
  v_nombre        TEXT := pg_catalog.btrim(COALESCE(p_nombre, ''));
  v_tipo_clave    TEXT := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_tipo_clave, 'COLONIA')));
  v_tipo_id       UUID;
  v_has_muni      BOOLEAN;
  v_muni_ok       BOOLEAN;
  v_existing      v2.cat_comunidades%ROWTYPE;
  v_created       v2.cat_comunidades%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR NOT v2_private.is_active_user() THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión activa.';
  END IF;

  IF p_municipio_id IS NULL OR pg_catalog.length(v_nombre) < 2 THEN
    RAISE EXCEPTION 'DATA_REQUIRED: municipio y nombre de comunidad o colonia son obligatorios.';
  END IF;

  v_role := v2_private.current_role();
  IF v_role NOT IN ('SUPERADMIN', 'ADMIN') THEN
    IF v_role <> 'CAPTURISTA' THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: tu rol no puede registrar comunidades o colonias.';
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM v2.profile_municipios pm
      WHERE pm.user_id = v_uid AND pm.activo = TRUE
    ) INTO v_has_muni;

    IF NOT v_has_muni THEN
      SELECT EXISTS (
        SELECT 1 FROM v2.profile_unidades pu
        WHERE pu.user_id = v_uid AND pu.activo = TRUE
      ) INTO v_muni_ok;
    ELSE
      SELECT EXISTS (
        SELECT 1 FROM v2.profile_municipios pm
        WHERE pm.user_id = v_uid
          AND pm.municipio_id = p_municipio_id
          AND pm.activo = TRUE
      ) INTO v_muni_ok;
    END IF;

    IF NOT COALESCE(v_muni_ok, FALSE) THEN
      RAISE EXCEPTION 'SCOPE_DENIED: el municipio seleccionado está fuera de tu alcance.';
    END IF;
  END IF;

  SELECT ta.id
  INTO v_tipo_id
  FROM v2.cat_tipos_asentamiento ta
  WHERE pg_catalog.upper(ta.clave) = v_tipo_clave
    AND ta.activo = TRUE
  LIMIT 1;

  IF v_tipo_id IS NULL THEN
    SELECT ta.id
    INTO v_tipo_id
    FROM v2.cat_tipos_asentamiento ta
    WHERE pg_catalog.upper(ta.clave) IN ('COLONIA', 'COMUNIDAD', 'OTRO')
      AND ta.activo = TRUE
    ORDER BY ta.orden
    LIMIT 1;
  END IF;

  SELECT c.*
  INTO v_existing
  FROM v2.cat_comunidades c
  WHERE c.municipio_id = p_municipio_id
    AND pg_catalog.lower(pg_catalog.btrim(c.nombre)) = pg_catalog.lower(v_nombre)
  LIMIT 1;

  IF FOUND THEN
    IF v_existing.activo = FALSE THEN
      UPDATE v2.cat_comunidades c
      SET activo = TRUE,
          tipo_asentamiento_id = COALESCE(c.tipo_asentamiento_id, v_tipo_id),
          updated_by = v_uid,
          updated_at = pg_catalog.now()
      WHERE c.id = v_existing.id
      RETURNING * INTO v_existing;
    END IF;

    RETURN QUERY
    SELECT
      v_existing.id,
      v_existing.municipio_id,
      v_tipo_clave,
      v_existing.nombre;
    RETURN;
  END IF;

  INSERT INTO v2.cat_comunidades (
    municipio_id,
    tipo_asentamiento_id,
    nombre,
    activo,
    created_by,
    updated_by
  ) VALUES (
    p_municipio_id,
    v_tipo_id,
    v_nombre,
    TRUE,
    v_uid,
    v_uid
  )
  RETURNING * INTO v_created;

  RETURN QUERY
  SELECT
    v_created.id,
    v_created.municipio_id,
    v_tipo_clave,
    v_created.nombre;
END;
$$;

REVOKE ALL ON FUNCTION v2.rpc_registrar_asentamiento_captura(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION v2.rpc_registrar_asentamiento_captura(UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION v2.rpc_cancelar_borrador_propio(
  p_registro_id UUID
)
RETURNS TABLE (
  id         UUID,
  folio      TEXT,
  deleted_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_record  v2.registros%ROWTYPE;
  v_retired v2.registros%ROWTYPE;
BEGIN
  IF v_uid IS NULL OR NOT v2_private.is_active_user() THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión activa.';
  END IF;

  SELECT r.*
  INTO v_record
  FROM v2.registros r
  WHERE r.id = p_registro_id
    AND r.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RECORD_NOT_FOUND: el registro no existe o ya fue retirado.';
  END IF;

  IF v_record.origen <> 'MANUAL' OR v_record.estatus <> 'BORRADOR' THEN
    RAISE EXCEPTION 'DRAFT_ONLY: solo se pueden retirar borradores manuales antes de validación.';
  END IF;

  IF NOT v2_private.is_admin() THEN
    IF v_record.created_by IS DISTINCT FROM v_uid
       OR NOT v2_private.has_scope(v_record.unidad_operativa_id, v_record.municipio_id) THEN
      RAISE EXCEPTION 'PERMISSION_DENIED: solo puedes retirar borradores propios dentro de tu alcance.';
    END IF;
  END IF;

  UPDATE v2.registros r
  SET deleted_at = pg_catalog.now(),
      deleted_by = v_uid,
      updated_by = v_uid,
      updated_at = pg_catalog.now()
  WHERE r.id = v_record.id
  RETURNING * INTO v_retired;

  RETURN QUERY
  SELECT
    v_retired.id,
    v_retired.folio,
    v_retired.deleted_at;
END;
$$;

REVOKE ALL ON FUNCTION v2.rpc_cancelar_borrador_propio(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION v2.rpc_cancelar_borrador_propio(UUID) TO authenticated;
