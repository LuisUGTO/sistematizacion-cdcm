-- ============================================================================
-- HOTFIX 7.7.7.1 - NOMBRE VISIBLE DE USUARIOS
-- Sólo SUPERADMIN puede modificar el nombre de un perfil.
-- El correo, rol, estatus y alcances no se modifican aquí.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.profiles') IS NULL
     OR to_regprocedure('v2_private.current_role()') IS NULL THEN
    RAISE EXCEPTION 'PRECONDICION: faltan profiles o helpers de seguridad V2.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION v2.rpc_superadmin_actualizar_nombre_usuario(
  p_user_id UUID,
  p_nombre TEXT
)
RETURNS TABLE (
  user_id UUID,
  email TEXT,
  nombre TEXT,
  updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_nombre TEXT := btrim(COALESCE(p_nombre, ''));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  IF v2_private.current_role() <> 'SUPERADMIN' THEN
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
$function$;

COMMENT ON FUNCTION v2.rpc_superadmin_actualizar_nombre_usuario(UUID, TEXT) IS
'Actualiza exclusivamente el nombre visible de un perfil. Sólo SUPERADMIN; el trigger de profiles conserva la auditoría.';

REVOKE ALL ON FUNCTION v2.rpc_superadmin_actualizar_nombre_usuario(UUID, TEXT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_superadmin_actualizar_nombre_usuario(UUID, TEXT)
TO authenticated;

INSERT INTO v2.schema_migrations(version, descripcion)
VALUES ('2.1.12ah', '12ah_superadmin_nombre_usuarios.sql - SUPERADMIN actualiza nombre visible de perfiles.')
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  to_regprocedure('v2.rpc_superadmin_actualizar_nombre_usuario(uuid,text)') IS NOT NULL AS rpc_existe,
  has_function_privilege('authenticated', 'v2.rpc_superadmin_actualizar_nombre_usuario(uuid,text)', 'EXECUTE') AS authenticated_execute,
  NOT has_function_privilege('anon', 'v2.rpc_superadmin_actualizar_nombre_usuario(uuid,text)', 'EXECUTE') AS anon_bloqueado,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12ah') AS migracion;
-- Esperado: true | true | true | 1
