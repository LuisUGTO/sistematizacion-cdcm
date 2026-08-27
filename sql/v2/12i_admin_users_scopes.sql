-- ============================================================================
-- VINCULACION CULTURAL 2.0
-- 12i_admin_users_scopes.sql
-- Etapa 6.3: administración segura de usuarios, roles y alcances V2
-- Secretaria de Cultura de Guanajuato
--
-- CREA:
--   v2.rpc_admin_listar_usuarios()
--   v2.rpc_admin_guardar_acceso(uuid,text,boolean,uuid[],uuid[])
--
-- SEGURIDAD:
--   - Solo ADMIN autenticado puede consultar o modificar.
--   - No usa service_role ni secretos en el navegador.
--   - Impide que un ADMIN se desactive o se quite su propio rol.
--   - CAPTURISTA requiere al menos una unidad y un municipio activos.
--   - Conserva las filas históricas de alcance; las desactiva/reactiva.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.profiles') IS NULL
     OR to_regclass('v2.profile_unidades') IS NULL
     OR to_regclass('v2.profile_municipios') IS NULL
     OR to_regprocedure('v2_private.is_admin()') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION FALLIDA: faltan perfiles, alcances o seguridad V2.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM v2.schema_migrations WHERE version = '2.1.12h'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICION FALLIDA: primero debe instalarse 12h_admin_test_cleanup.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. BANDEJA ADMINISTRATIVA DE USUARIOS V2
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_admin_listar_usuarios()
RETURNS TABLE (
  user_id                    UUID,
  email                      TEXT,
  nombre                     TEXT,
  rol                        TEXT,
  activo                     BOOLEAN,
  created_at                 TIMESTAMPTZ,
  updated_at                 TIMESTAMPTZ,
  unidad_ids                 UUID[],
  municipio_ids              UUID[],
  unidad_principal_id        UUID,
  municipio_principal_id     UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = ''
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  IF NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede consultar usuarios.';
  END IF;

  RETURN QUERY
  SELECT
    p.user_id,
    p.email,
    p.nombre,
    p.rol,
    p.activo,
    p.created_at,
    p.updated_at,
    COALESCE(
      ARRAY(
        SELECT pu.unidad_operativa_id
        FROM v2.profile_unidades pu
        WHERE pu.user_id = p.user_id AND pu.activo = true
        ORDER BY pu.es_principal DESC, pu.created_at, pu.unidad_operativa_id
      ), ARRAY[]::UUID[]
    ) AS unidad_ids,
    COALESCE(
      ARRAY(
        SELECT pm.municipio_id
        FROM v2.profile_municipios pm
        WHERE pm.user_id = p.user_id AND pm.activo = true
        ORDER BY pm.es_principal DESC, pm.created_at, pm.municipio_id
      ), ARRAY[]::UUID[]
    ) AS municipio_ids,
    (
      SELECT pu.unidad_operativa_id
      FROM v2.profile_unidades pu
      WHERE pu.user_id = p.user_id AND pu.activo = true
      ORDER BY pu.es_principal DESC, pu.created_at, pu.unidad_operativa_id
      LIMIT 1
    ) AS unidad_principal_id,
    (
      SELECT pm.municipio_id
      FROM v2.profile_municipios pm
      WHERE pm.user_id = p.user_id AND pm.activo = true
      ORDER BY pm.es_principal DESC, pm.created_at, pm.municipio_id
      LIMIT 1
    ) AS municipio_principal_id
  FROM v2.profiles p
  ORDER BY p.activo DESC, p.created_at DESC, p.email;
END;
$function$;


COMMENT ON FUNCTION v2.rpc_admin_listar_usuarios() IS
'Bandeja administrativa V2 con perfiles y alcances activos. Solo ADMIN.';


-- ============================================================================
-- 02. GUARDADO TRANSACCIONAL DE ROL, ESTATUS Y ALCANCES
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_admin_guardar_acceso(
  p_user_id          UUID,
  p_rol              TEXT,
  p_activo           BOOLEAN,
  p_unidad_ids       UUID[] DEFAULT ARRAY[]::UUID[],
  p_municipio_ids    UUID[] DEFAULT ARRAY[]::UUID[]
)
RETURNS TABLE (
  user_id             UUID,
  email               TEXT,
  rol                 TEXT,
  activo              BOOLEAN,
  unidades_activas    INTEGER,
  municipios_activos  INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid                 UUID := auth.uid();
  v_role                TEXT := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_rol, '')));
  v_target              v2.profiles%ROWTYPE;
  v_unit_ids            UUID[];
  v_municipality_ids    UUID[];
  v_unit_count          INTEGER;
  v_municipality_count  INTEGER;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  IF NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede modificar usuarios.';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'USER_REQUIRED: selecciona un usuario.';
  END IF;

  IF v_role NOT IN ('ADMIN', 'SUPERVISOR', 'DIRECTIVO', 'CAPTURISTA') THEN
    RAISE EXCEPTION 'ROLE_INVALID: el rol seleccionado no es válido.';
  END IF;

  SELECT p.* INTO v_target
  FROM v2.profiles p
  WHERE p.user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'USER_NOT_FOUND: el perfil V2 no existe.';
  END IF;

  IF p_user_id = v_uid AND (v_role <> 'ADMIN' OR p_activo IS NOT TRUE) THEN
    RAISE EXCEPTION
      'SELF_ADMIN_PROTECTED: no puedes desactivar ni retirar tu propio rol ADMIN.';
  END IF;

  SELECT COALESCE(
    pg_catalog.array_agg(x.id ORDER BY x.first_ordinality),
    ARRAY[]::UUID[]
  )
  INTO v_unit_ids
  FROM (
    SELECT item.id, pg_catalog.min(item.ordinality) AS first_ordinality
    FROM pg_catalog.unnest(COALESCE(p_unidad_ids, ARRAY[]::UUID[]))
      WITH ORDINALITY AS item(id, ordinality)
    JOIN v2.cat_unidades_operativas cu
      ON cu.id = item.id AND cu.activo = true
    GROUP BY item.id
  ) x;

  SELECT COALESCE(
    pg_catalog.array_agg(x.id ORDER BY x.first_ordinality),
    ARRAY[]::UUID[]
  )
  INTO v_municipality_ids
  FROM (
    SELECT item.id, pg_catalog.min(item.ordinality) AS first_ordinality
    FROM pg_catalog.unnest(COALESCE(p_municipio_ids, ARRAY[]::UUID[]))
      WITH ORDINALITY AS item(id, ordinality)
    JOIN v2.cat_municipios cm
      ON cm.id = item.id AND cm.activo = true
    GROUP BY item.id
  ) x;

  -- COALESCE es una expresión especial de PostgreSQL: no se califica con
  -- pg_catalog. Esta forma también cubre correctamente los arreglos vacíos.
  v_unit_count := COALESCE(pg_catalog.array_length(v_unit_ids, 1), 0);
  v_municipality_count := COALESCE(
    pg_catalog.array_length(v_municipality_ids, 1),
    0
  );

  IF p_activo IS TRUE AND v_role = 'CAPTURISTA' AND v_unit_count = 0 THEN
    RAISE EXCEPTION
      'CAPTURE_UNIT_REQUIRED: un CAPTURISTA activo necesita al menos una unidad.';
  END IF;

  IF p_activo IS TRUE AND v_role = 'CAPTURISTA' AND v_municipality_count = 0 THEN
    RAISE EXCEPTION
      'CAPTURE_MUNICIPALITY_REQUIRED: un CAPTURISTA activo necesita al menos un municipio.';
  END IF;

  UPDATE v2.profiles p
  SET rol = v_role,
      activo = COALESCE(p_activo, false),
      updated_at = pg_catalog.now()
  WHERE p.user_id = p_user_id;

  UPDATE v2.profile_unidades pu
  SET activo = false,
      es_principal = false
  WHERE pu.user_id = p_user_id;

  INSERT INTO v2.profile_unidades (
    user_id, unidad_operativa_id, es_principal, activo, created_by
  )
  SELECT
    p_user_id,
    ids.id,
    ids.ordinality = 1,
    true,
    v_uid
  FROM pg_catalog.unnest(v_unit_ids) WITH ORDINALITY AS ids(id, ordinality)
  ON CONFLICT (user_id, unidad_operativa_id)
  DO UPDATE SET
    activo = true,
    es_principal = EXCLUDED.es_principal;

  UPDATE v2.profile_municipios pm
  SET activo = false,
      es_principal = false
  WHERE pm.user_id = p_user_id;

  INSERT INTO v2.profile_municipios (
    user_id, municipio_id, es_principal, activo, created_by
  )
  SELECT
    p_user_id,
    ids.id,
    ids.ordinality = 1,
    true,
    v_uid
  FROM pg_catalog.unnest(v_municipality_ids) WITH ORDINALITY AS ids(id, ordinality)
  ON CONFLICT (user_id, municipio_id)
  DO UPDATE SET
    activo = true,
    es_principal = EXCLUDED.es_principal;

  RETURN QUERY
  SELECT
    p.user_id,
    p.email,
    p.rol,
    p.activo,
    v_unit_count,
    v_municipality_count
  FROM v2.profiles p
  WHERE p.user_id = p_user_id;
END;
$function$;


COMMENT ON FUNCTION v2.rpc_admin_guardar_acceso(UUID, TEXT, BOOLEAN, UUID[], UUID[]) IS
'Actualiza rol, estatus y alcances V2 en una transacción. Solo ADMIN; protege al ADMIN actual.';


-- ============================================================================
-- 03. PERMISOS
-- ============================================================================

REVOKE ALL ON FUNCTION v2.rpc_admin_listar_usuarios()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2.rpc_admin_guardar_acceso(UUID, TEXT, BOOLEAN, UUID[], UUID[])
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION v2.rpc_admin_listar_usuarios()
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_admin_guardar_acceso(UUID, TEXT, BOOLEAN, UUID[], UUID[])
  TO authenticated;


-- ============================================================================
-- 04. REGISTRO DE MIGRACION
-- ============================================================================

INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12i',
  '12i_admin_users_scopes.sql - Administración transaccional de perfiles, roles, unidades y municipios V2 solo para ADMIN.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;


-- ============================================================================
-- 05. VERIFICACION POST-INSTALACION
-- ============================================================================

SELECT
  to_regprocedure('v2.rpc_admin_listar_usuarios()') IS NOT NULL
    AS rpc_listado_existe,
  to_regprocedure('v2.rpc_admin_guardar_acceso(uuid,text,boolean,uuid[],uuid[])') IS NOT NULL
    AS rpc_guardado_existe,
  COALESCE(has_function_privilege(
    'authenticated', 'v2.rpc_admin_listar_usuarios()', 'EXECUTE'
  ), false) AS authenticated_listado,
  COALESCE(has_function_privilege(
    'authenticated',
    'v2.rpc_admin_guardar_acceso(uuid,text,boolean,uuid[],uuid[])',
    'EXECUTE'
  ), false) AS authenticated_guardado,
  COALESCE(has_function_privilege(
    'anon', 'v2.rpc_admin_listar_usuarios()', 'EXECUTE'
  ), false) AS anon_listado,
  COALESCE(has_function_privilege(
    'anon',
    'v2.rpc_admin_guardar_acceso(uuid,text,boolean,uuid[],uuid[])',
    'EXECUTE'
  ), false) AS anon_guardado,
  (
    SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12i'
  ) AS migracion_registrada;

-- RESULTADO ESPERADO:
-- true | true | true | true | false | false | 1
