-- ============================================================================
-- ETAPA 7.2.1 - ADMINISTRACION SEGURA DE CATALOGOS OPERATIVOS
-- Ejecutar una sola vez en Supabase SQL Editor.
-- Requiere que 02_catalogs.sql, 06_rls.sql y 12i_admin_users_scopes.sql
-- ya se encuentren aplicados.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regnamespace('v2') IS NULL
     OR to_regprocedure('v2_private.is_admin()') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION: aplica primero la estructura V2 y sus politicas RLS.';
  END IF;
END;
$$;


CREATE OR REPLACE FUNCTION v2.rpc_admin_guardar_programa(
  p_id UUID,
  p_unidad_operativa_id UUID,
  p_clave TEXT,
  p_nombre TEXT,
  p_descripcion TEXT,
  p_orden INTEGER,
  p_activo BOOLEAN
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, v2, v2_private
AS $$
DECLARE
  v_id UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede modificar catalogos.';
  END IF;
  IF p_unidad_operativa_id IS NULL THEN
    RAISE EXCEPTION 'UNIDAD_REQUIRED: selecciona una unidad operativa.';
  END IF;
  IF NULLIF(btrim(p_clave), '') IS NULL OR NULLIF(btrim(p_nombre), '') IS NULL THEN
    RAISE EXCEPTION 'DATA_REQUIRED: clave y nombre son obligatorios.';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO v2.cat_programas (
      unidad_operativa_id, clave, nombre, descripcion, orden, activo
    ) VALUES (
      p_unidad_operativa_id,
      upper(btrim(p_clave)),
      btrim(p_nombre),
      NULLIF(btrim(p_descripcion), ''),
      GREATEST(COALESCE(p_orden, 0), 0),
      COALESCE(p_activo, true)
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE v2.cat_programas
    SET unidad_operativa_id = p_unidad_operativa_id,
        clave = upper(btrim(p_clave)),
        nombre = btrim(p_nombre),
        descripcion = NULLIF(btrim(p_descripcion), ''),
        orden = GREATEST(COALESCE(p_orden, 0), 0),
        activo = COALESCE(p_activo, true),
        updated_by = auth.uid(),
        updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: el programa ya no existe.';
  END IF;
  RETURN v_id;
END;
$$;


CREATE OR REPLACE FUNCTION v2.rpc_admin_guardar_comunidad(
  p_id UUID,
  p_municipio_id UUID,
  p_tipo_asentamiento_id UUID,
  p_clave TEXT,
  p_nombre TEXT,
  p_latitud DOUBLE PRECISION,
  p_longitud DOUBLE PRECISION,
  p_activo BOOLEAN
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, v2, v2_private
AS $$
DECLARE
  v_id UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede modificar catalogos.';
  END IF;
  IF p_municipio_id IS NULL OR NULLIF(btrim(p_nombre), '') IS NULL THEN
    RAISE EXCEPTION 'DATA_REQUIRED: municipio y comunidad son obligatorios.';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO v2.cat_comunidades (
      municipio_id, tipo_asentamiento_id, clave, nombre,
      latitud, longitud, activo
    ) VALUES (
      p_municipio_id, p_tipo_asentamiento_id,
      NULLIF(btrim(p_clave), ''), btrim(p_nombre),
      p_latitud, p_longitud, COALESCE(p_activo, true)
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE v2.cat_comunidades
    SET municipio_id = p_municipio_id,
        tipo_asentamiento_id = p_tipo_asentamiento_id,
        clave = NULLIF(btrim(p_clave), ''),
        nombre = btrim(p_nombre),
        latitud = p_latitud,
        longitud = p_longitud,
        activo = COALESCE(p_activo, true),
        updated_by = auth.uid(),
        updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: la comunidad ya no existe.';
  END IF;
  RETURN v_id;
END;
$$;


CREATE OR REPLACE FUNCTION v2.rpc_admin_guardar_espacio(
  p_id UUID,
  p_tipo_espacio_id UUID,
  p_unidad_operativa_id UUID,
  p_municipio_id UUID,
  p_comunidad_id UUID,
  p_clave TEXT,
  p_nombre TEXT,
  p_direccion TEXT,
  p_latitud DOUBLE PRECISION,
  p_longitud DOUBLE PRECISION,
  p_activo BOOLEAN
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, v2, v2_private
AS $$
DECLARE
  v_id UUID;
  v_comunidad_municipio UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede modificar catalogos.';
  END IF;
  IF p_tipo_espacio_id IS NULL OR p_municipio_id IS NULL
     OR NULLIF(btrim(p_nombre), '') IS NULL THEN
    RAISE EXCEPTION 'DATA_REQUIRED: tipo, municipio y nombre son obligatorios.';
  END IF;

  IF p_comunidad_id IS NOT NULL THEN
    SELECT municipio_id INTO v_comunidad_municipio
    FROM v2.cat_comunidades WHERE id = p_comunidad_id;
    IF v_comunidad_municipio IS DISTINCT FROM p_municipio_id THEN
      RAISE EXCEPTION
        'COMMUNITY_MUNICIPALITY_MISMATCH: la comunidad no pertenece al municipio.';
    END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO v2.cat_espacios (
      tipo_espacio_id, unidad_operativa_id, municipio_id, comunidad_id,
      clave, nombre, direccion, latitud, longitud, activo
    ) VALUES (
      p_tipo_espacio_id, p_unidad_operativa_id, p_municipio_id, p_comunidad_id,
      NULLIF(btrim(p_clave), ''), btrim(p_nombre), NULLIF(btrim(p_direccion), ''),
      p_latitud, p_longitud, COALESCE(p_activo, true)
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE v2.cat_espacios
    SET tipo_espacio_id = p_tipo_espacio_id,
        unidad_operativa_id = p_unidad_operativa_id,
        municipio_id = p_municipio_id,
        comunidad_id = p_comunidad_id,
        clave = NULLIF(btrim(p_clave), ''),
        nombre = btrim(p_nombre),
        direccion = NULLIF(btrim(p_direccion), ''),
        latitud = p_latitud,
        longitud = p_longitud,
        activo = COALESCE(p_activo, true),
        updated_by = auth.uid(),
        updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: el espacio ya no existe.';
  END IF;
  RETURN v_id;
END;
$$;


CREATE OR REPLACE FUNCTION v2.rpc_admin_guardar_accion(
  p_id UUID,
  p_unidad_operativa_id UUID,
  p_programa_id UUID,
  p_clave TEXT,
  p_nombre TEXT,
  p_descripcion TEXT,
  p_orden INTEGER,
  p_activo BOOLEAN,
  p_tipo_registro_clave TEXT,
  p_tipo_formulario TEXT,
  p_vigente_desde DATE,
  p_vigente_hasta DATE,
  p_requiere_comunidad BOOLEAN,
  p_requiere_espacio BOOLEAN,
  p_requiere_responsable BOOLEAN,
  p_requiere_docente BOOLEAN,
  p_requiere_beneficiarios BOOLEAN,
  p_requiere_demografia BOOLEAN,
  p_requiere_gps BOOLEAN,
  p_requiere_evidencia BOOLEAN,
  p_requiere_validacion BOOLEAN
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, v2, v2_private
AS $$
DECLARE
  v_id UUID;
  v_tipo_registro_id UUID;
  v_esquema_id UUID;
  v_programa_unidad UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede modificar catalogos.';
  END IF;
  IF p_unidad_operativa_id IS NULL OR p_programa_id IS NULL
     OR NULLIF(btrim(p_clave), '') IS NULL
     OR NULLIF(btrim(p_nombre), '') IS NULL
     OR NULLIF(btrim(p_tipo_registro_clave), '') IS NULL
     OR NULLIF(btrim(p_tipo_formulario), '') IS NULL
     OR p_vigente_desde IS NULL THEN
    RAISE EXCEPTION 'DATA_REQUIRED: completa clasificacion, clave, nombre y vigencia.';
  END IF;
  IF p_vigente_hasta IS NOT NULL AND p_vigente_hasta < p_vigente_desde THEN
    RAISE EXCEPTION 'DATE_RANGE_INVALID: la vigencia final no puede ser anterior.';
  END IF;

  SELECT unidad_operativa_id INTO v_programa_unidad
  FROM v2.cat_programas WHERE id = p_programa_id;
  IF v_programa_unidad IS DISTINCT FROM p_unidad_operativa_id THEN
    RAISE EXCEPTION 'PROGRAM_UNIT_MISMATCH: el programa no pertenece a la unidad.';
  END IF;

  SELECT id INTO v_tipo_registro_id
  FROM v2.cat_tipos_registro
  WHERE upper(btrim(clave)) = upper(btrim(p_tipo_registro_clave))
    AND activo = true
  LIMIT 1;
  IF v_tipo_registro_id IS NULL THEN
    RAISE EXCEPTION 'RECORD_TYPE_NOT_FOUND: el tipo de registro no existe o esta inactivo.';
  END IF;

  IF COALESCE(p_requiere_demografia, false) THEN
    SELECT id INTO v_esquema_id
    FROM v2.cat_esquemas_demograficos
    WHERE activo = true
    ORDER BY (upper(btrim(clave)) = 'OFICIAL_2026') DESC, vigente_desde DESC
    LIMIT 1;
    IF v_esquema_id IS NULL THEN
      RAISE EXCEPTION 'DEMOGRAPHIC_SCHEMA_REQUIRED: no existe un esquema demografico activo.';
    END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO v2.cat_acciones (
      unidad_operativa_id, programa_id, clave, nombre,
      descripcion, orden, activo
    ) VALUES (
      p_unidad_operativa_id, p_programa_id, upper(btrim(p_clave)),
      btrim(p_nombre), NULLIF(btrim(p_descripcion), ''),
      GREATEST(COALESCE(p_orden, 0), 0), COALESCE(p_activo, true)
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE v2.cat_acciones
    SET unidad_operativa_id = p_unidad_operativa_id,
        programa_id = p_programa_id,
        clave = upper(btrim(p_clave)),
        nombre = btrim(p_nombre),
        descripcion = NULLIF(btrim(p_descripcion), ''),
        orden = GREATEST(COALESCE(p_orden, 0), 0),
        activo = COALESCE(p_activo, true),
        updated_by = auth.uid(),
        updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: la accion ya no existe.';
  END IF;

  INSERT INTO v2.configuracion_acciones (
    accion_id, tipo_registro_id, tipo_formulario,
    requiere_municipio, requiere_comunidad, requiere_espacio,
    requiere_responsable, requiere_docente, requiere_beneficiarios,
    requiere_demografia, requiere_gps, requiere_evidencia,
    requiere_validacion, permite_offline, vigente_desde, vigente_hasta,
    activo, esquema_demografico_id
  ) VALUES (
    v_id, v_tipo_registro_id, upper(btrim(p_tipo_formulario)),
    true, COALESCE(p_requiere_comunidad, false), COALESCE(p_requiere_espacio, false),
    COALESCE(p_requiere_responsable, false), COALESCE(p_requiere_docente, false),
    COALESCE(p_requiere_beneficiarios, false), COALESCE(p_requiere_demografia, false),
    COALESCE(p_requiere_gps, false), COALESCE(p_requiere_evidencia, true),
    COALESCE(p_requiere_validacion, true), true,
    p_vigente_desde, p_vigente_hasta, COALESCE(p_activo, true), v_esquema_id
  )
  ON CONFLICT (accion_id, vigente_desde)
  DO UPDATE SET
    tipo_registro_id = EXCLUDED.tipo_registro_id,
    tipo_formulario = EXCLUDED.tipo_formulario,
    requiere_municipio = EXCLUDED.requiere_municipio,
    requiere_comunidad = EXCLUDED.requiere_comunidad,
    requiere_espacio = EXCLUDED.requiere_espacio,
    requiere_responsable = EXCLUDED.requiere_responsable,
    requiere_docente = EXCLUDED.requiere_docente,
    requiere_beneficiarios = EXCLUDED.requiere_beneficiarios,
    requiere_demografia = EXCLUDED.requiere_demografia,
    requiere_gps = EXCLUDED.requiere_gps,
    requiere_evidencia = EXCLUDED.requiere_evidencia,
    requiere_validacion = EXCLUDED.requiere_validacion,
    vigente_hasta = EXCLUDED.vigente_hasta,
    activo = EXCLUDED.activo,
    esquema_demografico_id = EXCLUDED.esquema_demografico_id,
    updated_by = auth.uid(),
    updated_at = now();

  RETURN v_id;
END;
$$;


CREATE OR REPLACE FUNCTION v2.rpc_admin_cambiar_estado_catalogo(
  p_catalogo TEXT,
  p_id UUID,
  p_activo BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, v2, v2_private
AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede modificar catalogos.';
  END IF;
  IF p_id IS NULL OR p_activo IS NULL THEN
    RAISE EXCEPTION 'DATA_REQUIRED: registro y estado son obligatorios.';
  END IF;

  CASE upper(btrim(p_catalogo))
    WHEN 'PROGRAMA' THEN
      UPDATE v2.cat_programas
      SET activo = p_activo, updated_by = auth.uid(), updated_at = now()
      WHERE id = p_id;
      GET DIAGNOSTICS v_count = ROW_COUNT;
    WHEN 'ACCION' THEN
      UPDATE v2.cat_acciones
      SET activo = p_activo, updated_by = auth.uid(), updated_at = now()
      WHERE id = p_id;
      GET DIAGNOSTICS v_count = ROW_COUNT;
      UPDATE v2.configuracion_acciones
      SET activo = p_activo, updated_by = auth.uid(), updated_at = now()
      WHERE accion_id = p_id;
    WHEN 'COMUNIDAD' THEN
      UPDATE v2.cat_comunidades
      SET activo = p_activo, updated_by = auth.uid(), updated_at = now()
      WHERE id = p_id;
      GET DIAGNOSTICS v_count = ROW_COUNT;
    WHEN 'ESPACIO' THEN
      UPDATE v2.cat_espacios
      SET activo = p_activo, updated_by = auth.uid(), updated_at = now()
      WHERE id = p_id;
      GET DIAGNOSTICS v_count = ROW_COUNT;
    ELSE
      RAISE EXCEPTION 'CATALOG_NOT_ALLOWED: catalogo no permitido.';
  END CASE;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'NOT_FOUND: el elemento ya no existe.';
  END IF;
END;
$$;


REVOKE ALL ON FUNCTION v2.rpc_admin_guardar_programa(
  UUID, UUID, TEXT, TEXT, TEXT, INTEGER, BOOLEAN
) FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_admin_guardar_comunidad(
  UUID, UUID, UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN
) FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_admin_guardar_espacio(
  UUID, UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT,
  DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN
) FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_admin_guardar_accion(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, INTEGER, BOOLEAN,
  TEXT, TEXT, DATE, DATE,
  BOOLEAN, BOOLEAN, BOOLEAN, BOOLEAN, BOOLEAN, BOOLEAN,
  BOOLEAN, BOOLEAN, BOOLEAN
) FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_admin_cambiar_estado_catalogo(TEXT, UUID, BOOLEAN)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION v2.rpc_admin_guardar_programa(
  UUID, UUID, TEXT, TEXT, TEXT, INTEGER, BOOLEAN
) TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_admin_guardar_comunidad(
  UUID, UUID, UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN
) TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_admin_guardar_espacio(
  UUID, UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT,
  DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN
) TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_admin_guardar_accion(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, INTEGER, BOOLEAN,
  TEXT, TEXT, DATE, DATE,
  BOOLEAN, BOOLEAN, BOOLEAN, BOOLEAN, BOOLEAN, BOOLEAN,
  BOOLEAN, BOOLEAN, BOOLEAN
) TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_admin_cambiar_estado_catalogo(TEXT, UUID, BOOLEAN)
TO authenticated;

COMMENT ON FUNCTION v2.rpc_admin_cambiar_estado_catalogo(TEXT, UUID, BOOLEAN) IS
'Activa o desactiva catalogos operativos sin borrar historia. Solo ADMIN.';

COMMIT;

SELECT
  'OK - Etapa 7.2.1 aplicada' AS resultado,
  to_regprocedure('v2.rpc_admin_guardar_programa(uuid,uuid,text,text,text,integer,boolean)') IS NOT NULL AS programas,
  to_regprocedure('v2.rpc_admin_guardar_comunidad(uuid,uuid,uuid,text,text,double precision,double precision,boolean)') IS NOT NULL AS comunidades,
  to_regprocedure('v2.rpc_admin_guardar_espacio(uuid,uuid,uuid,uuid,uuid,text,text,text,double precision,double precision,boolean)') IS NOT NULL AS espacios,
  to_regprocedure('v2.rpc_admin_guardar_accion(uuid,uuid,uuid,text,text,text,integer,boolean,text,text,date,date,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') IS NOT NULL AS acciones,
  to_regprocedure('v2.rpc_admin_cambiar_estado_catalogo(text,uuid,boolean)') IS NOT NULL AS estados;
