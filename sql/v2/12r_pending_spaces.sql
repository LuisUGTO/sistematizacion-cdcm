-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 12r_pending_spaces.sql
-- Registro controlado de espacios reportados durante la captura
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.cat_espacios') IS NULL
     OR to_regclass('v2.cat_tipos_espacio') IS NULL
     OR to_regclass('v2.cat_municipios') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan catálogos territoriales V2.';
  END IF;

  IF to_regprocedure('v2_private.is_active_user()') IS NULL
     OR to_regprocedure('v2_private.has_scope(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan helpers de autorización V2.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.12q'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 12q_hotfix_submit_imported.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. RESOLVER O REGISTRAR SEDE REPORTADA
--
-- Si el nombre ya existe en el municipio, reutiliza su identificador.
-- Si todavía no existe, lo incorpora como tipo OTRO y lo marca dentro de
-- metadata como pendiente de catalogación. El registro queda relacionado con
-- un espacio válido y puede avanzar por el flujo normal de revisión.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_resolve_espacio_captura(
  p_municipio_id UUID,
  p_unidad_operativa_id UUID,
  p_nombre TEXT
)
RETURNS TABLE (
  id UUID,
  nombre TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid             UUID := auth.uid();
  v_nombre          TEXT;
  v_tipo_espacio_id UUID;
  v_espacio_id      UUID;
  v_espacio_nombre  TEXT;
BEGIN
  IF v_uid IS NULL
     OR NOT v2_private.is_active_user() THEN
    RAISE EXCEPTION
      'AUTH_REQUIRED: se requiere una cuenta institucional activa.';
  END IF;

  v_nombre :=
    NULLIF(
      pg_catalog.btrim(
        pg_catalog.regexp_replace(
          COALESCE(p_nombre, ''),
          '\s+',
          ' ',
          'g'
        )
      ),
      ''
    );

  IF p_municipio_id IS NULL THEN
    RAISE EXCEPTION
      'MUNICIPALITY_REQUIRED: selecciona el municipio.';
  END IF;

  IF v_nombre IS NULL
     OR pg_catalog.char_length(v_nombre) < 3
     OR pg_catalog.char_length(v_nombre) > 180 THEN
    RAISE EXCEPTION
      'SPACE_NAME_INVALID: escribe un nombre de espacio entre 3 y 180 caracteres.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.cat_municipios AS m
    WHERE m.id = p_municipio_id
      AND m.activo = true
  ) THEN
    RAISE EXCEPTION
      'MUNICIPALITY_INVALID: municipio inexistente o inactivo.';
  END IF;

  IF p_unidad_operativa_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM v2.cat_unidades_operativas AS u
       WHERE u.id = p_unidad_operativa_id
         AND u.activo = true
     ) THEN
    RAISE EXCEPTION
      'UNIT_INVALID: unidad operativa inexistente o inactiva.';
  END IF;

  IF NOT v2_private.has_scope(
    p_unidad_operativa_id,
    p_municipio_id
  ) THEN
    RAISE EXCEPTION
      'SCOPE_FORBIDDEN: el municipio o la unidad están fuera de tu alcance.';
  END IF;

  SELECT t.id
  INTO v_tipo_espacio_id
  FROM v2.cat_tipos_espacio AS t
  WHERE upper(pg_catalog.btrim(t.clave)) = 'OTRO'
    AND t.activo = true
  ORDER BY t.orden, t.created_at
  LIMIT 1;

  IF v_tipo_espacio_id IS NULL THEN
    RAISE EXCEPTION
      'SPACE_TYPE_MISSING: no existe el tipo de espacio OTRO.';
  END IF;

  SELECT e.id, e.nombre
  INTO v_espacio_id, v_espacio_nombre
  FROM v2.cat_espacios AS e
  WHERE e.municipio_id = p_municipio_id
    AND e.tipo_espacio_id = v_tipo_espacio_id
    AND lower(pg_catalog.btrim(e.nombre)) = lower(v_nombre)
  ORDER BY e.activo DESC, e.created_at
  LIMIT 1
  FOR UPDATE;

  IF v_espacio_id IS NULL THEN
    BEGIN
      INSERT INTO v2.cat_espacios (
        tipo_espacio_id,
        unidad_operativa_id,
        municipio_id,
        nombre,
        metadata,
        activo,
        created_by,
        updated_by
      )
      VALUES (
        v_tipo_espacio_id,
        NULL,
        p_municipio_id,
        v_nombre,
        pg_catalog.jsonb_build_object(
          'pendiente_catalogacion', true,
          'origen', 'CAPTURA_OPERATIVA',
          'nombre_reportado', v_nombre,
          'unidad_reportada_id', p_unidad_operativa_id,
          'reportado_por', v_uid,
          'reportado_at', pg_catalog.now()
        ),
        true,
        v_uid,
        v_uid
      )
      RETURNING
        v2.cat_espacios.id,
        v2.cat_espacios.nombre
      INTO
        v_espacio_id,
        v_espacio_nombre;

    EXCEPTION
      WHEN unique_violation THEN
        SELECT e.id, e.nombre
        INTO v_espacio_id, v_espacio_nombre
        FROM v2.cat_espacios AS e
        WHERE e.municipio_id = p_municipio_id
          AND e.tipo_espacio_id = v_tipo_espacio_id
          AND lower(pg_catalog.btrim(e.nombre)) = lower(v_nombre)
        ORDER BY e.created_at
        LIMIT 1;
    END;
  ELSE
    UPDATE v2.cat_espacios AS e
    SET
      activo = true,
      updated_by = v_uid,
      updated_at = pg_catalog.now()
    WHERE e.id = v_espacio_id;
  END IF;

  RETURN QUERY
  SELECT
    v_espacio_id,
    v_espacio_nombre;
END;
$$;


REVOKE ALL
ON FUNCTION v2.rpc_resolve_espacio_captura(UUID, UUID, TEXT)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION v2.rpc_resolve_espacio_captura(UUID, UUID, TEXT)
TO authenticated;


INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.12r',
  '12r_pending_spaces.sql - Permite registrar sedes reportadas y marcarlas como pendientes de catalogación.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- VERIFICACIÓN
--
-- Esperado: true | true | false | 1
-- ============================================================================

SELECT
  (
    to_regprocedure(
      'v2.rpc_resolve_espacio_captura(uuid,uuid,text)'
    ) IS NOT NULL
  ) AS rpc_existe,

  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.rpc_resolve_espacio_captura(uuid,uuid,text)',
    'EXECUTE'
  ) AS authenticated_execute,

  pg_catalog.has_function_privilege(
    'anon',
    'v2.rpc_resolve_espacio_captura(uuid,uuid,text)',
    'EXECUTE'
  ) AS anon_execute,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12r'
  ) AS migracion_registrada;
