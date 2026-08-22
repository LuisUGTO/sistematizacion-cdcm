-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 12c_rpc_create_borrador.sql
-- Escritura transaccional segura desde Frontend V2
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '90s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.registro_taller') IS NULL
     OR to_regclass('v2.registro_poblacion') IS NULL
     OR to_regprocedure('v2.next_folio(integer)') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos requeridos del Core V2.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.12b'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 12b_hotfix_registros_insert_rls.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. CERRAR INSERT DIRECTO DESDE DATA API
--
-- A partir de esta versión:
--
--   navegador -> RPC -> tablas
--
-- y NO:
--
--   navegador -> INSERT directo a v2.registros
--
-- Un SECURITY DEFINER correctamente validado escribe con el propietario
-- de la función y mantiene la lógica de autorización centralizada.
-- ============================================================================

DROP POLICY IF EXISTS registros_insert
ON v2.registros;


-- ============================================================================
-- 02. RPC TRANSACCIONAL
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_create_borrador(
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
  v_uid                   UUID := auth.uid();
  v_role                  TEXT;

  v_action_id             UUID;
  v_unit_requested        UUID;
  v_unit_id               UUID;

  v_program_requested     UUID;
  v_program_action        UUID;
  v_program_id            UUID;

  v_config_id             UUID;
  v_config_action_id      UUID;
  v_tipo_registro_id      UUID;
  v_esquema_id            UUID;
  v_tipo_formulario       TEXT;
  v_requiere_municipio    BOOLEAN;

  v_municipio_id          UUID;
  v_espacio_id            UUID;

  v_nombre                TEXT;
  v_descripcion           TEXT;

  v_fecha_inicio          DATE;
  v_fecha_fin             DATE;

  v_total_beneficiarios   INTEGER;
  v_total_participantes   INTEGER;
  v_total_accesos         INTEGER;

  v_metadata              JSONB;

  v_registro_id           UUID;
  v_folio                 TEXT;

  v_taller                JSONB;
  v_demo                  JSONB;
  v_demo_item             JSONB;

  v_opcion_id             UUID;
  v_universo              TEXT;
  v_cantidad              INTEGER;

  v_costo                 NUMERIC(14,2);
BEGIN
  -- --------------------------------------------------------------------------
  -- Sesión
  -- --------------------------------------------------------------------------

  IF v_uid IS NULL THEN
    RAISE EXCEPTION
      'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  SELECT p.rol
  INTO v_role
  FROM v2.profiles p
  WHERE p.user_id = v_uid
    AND p.activo = true
  LIMIT 1;

  IF v_role IS NULL THEN
    RAISE EXCEPTION
      'PROFILE_REQUIRED: no existe un perfil V2 activo.';
  END IF;

  IF v_role NOT IN ('ADMIN', 'CAPTURISTA') THEN
    RAISE EXCEPTION
      'ROLE_FORBIDDEN: el rol % no puede crear capturas.',
      v_role;
  END IF;


  -- --------------------------------------------------------------------------
  -- Payload núcleo
  -- --------------------------------------------------------------------------

  IF p_payload IS NULL
     OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION
      'PAYLOAD_INVALID: se esperaba un objeto JSON.';
  END IF;

  v_action_id :=
    NULLIF(p_payload ->> 'accion_id', '')::UUID;

  v_unit_requested :=
    NULLIF(
      p_payload ->> 'unidad_operativa_id',
      ''
    )::UUID;

  v_program_requested :=
    NULLIF(
      p_payload ->> 'programa_id',
      ''
    )::UUID;

  v_config_id :=
    NULLIF(
      p_payload ->> 'configuracion_accion_id',
      ''
    )::UUID;

  v_municipio_id :=
    NULLIF(
      p_payload ->> 'municipio_id',
      ''
    )::UUID;

  v_espacio_id :=
    NULLIF(
      p_payload ->> 'espacio_id',
      ''
    )::UUID;

  v_nombre :=
    NULLIF(
      pg_catalog.btrim(
        p_payload ->> 'nombre'
      ),
      ''
    );

  v_descripcion :=
    NULLIF(
      pg_catalog.btrim(
        p_payload ->> 'descripcion'
      ),
      ''
    );

  v_fecha_inicio :=
    NULLIF(
      p_payload ->> 'fecha_inicio',
      ''
    )::DATE;

  v_fecha_fin :=
    COALESCE(
      NULLIF(
        p_payload ->> 'fecha_fin',
        ''
      )::DATE,
      v_fecha_inicio
    );

  v_total_beneficiarios :=
    NULLIF(
      p_payload ->> 'total_beneficiarios',
      ''
    )::INTEGER;

  v_total_participantes :=
    NULLIF(
      p_payload ->> 'total_participantes',
      ''
    )::INTEGER;

  v_total_accesos :=
    NULLIF(
      p_payload ->> 'total_accesos',
      ''
    )::INTEGER;

  v_metadata :=
    COALESCE(
      p_payload -> 'metadata',
      '{}'::JSONB
    );


  IF v_action_id IS NULL
     OR v_config_id IS NULL
     OR v_nombre IS NULL
     OR v_fecha_inicio IS NULL THEN
    RAISE EXCEPTION
      'PAYLOAD_REQUIRED_FIELDS: acción, configuración, nombre y fecha son obligatorios.';
  END IF;

  IF v_fecha_fin < v_fecha_inicio THEN
    RAISE EXCEPTION
      'DATE_RANGE_INVALID: fecha_fin no puede ser anterior a fecha_inicio.';
  END IF;

  IF COALESCE(v_total_beneficiarios, 0) < 0
     OR COALESCE(v_total_participantes, 0) < 0
     OR COALESCE(v_total_accesos, 0) < 0 THEN
    RAISE EXCEPTION
      'TOTAL_INVALID: los totales no pueden ser negativos.';
  END IF;


  -- --------------------------------------------------------------------------
  -- Acción: unidad/programa autoritativos
  -- --------------------------------------------------------------------------

  SELECT
    a.unidad_operativa_id,
    a.programa_id
  INTO
    v_unit_id,
    v_program_action
  FROM v2.cat_acciones a
  WHERE a.id = v_action_id
    AND a.activo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'ACTION_INVALID: la acción no existe o está inactiva.';
  END IF;

  IF v_unit_requested IS NOT NULL
     AND v_unit_requested <> v_unit_id THEN
    RAISE EXCEPTION
      'ACTION_UNIT_MISMATCH: la acción no pertenece a la unidad solicitada.';
  END IF;

  v_program_id :=
    COALESCE(
      v_program_action,
      v_program_requested
    );

  IF v_program_action IS NOT NULL
     AND v_program_requested IS NOT NULL
     AND v_program_action <> v_program_requested THEN
    RAISE EXCEPTION
      'ACTION_PROGRAM_MISMATCH: la acción no pertenece al programa solicitado.';
  END IF;

  IF v_program_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM v2.cat_programas p
       WHERE p.id = v_program_id
         AND p.unidad_operativa_id = v_unit_id
         AND p.activo = true
     ) THEN
    RAISE EXCEPTION
      'PROGRAM_INVALID: el programa no pertenece a la unidad seleccionada.';
  END IF;


  -- --------------------------------------------------------------------------
  -- Configuración vigente
  -- --------------------------------------------------------------------------

  SELECT
    ca.accion_id,
    ca.tipo_registro_id,
    ca.esquema_demografico_id,
    ca.tipo_formulario,
    ca.requiere_municipio
  INTO
    v_config_action_id,
    v_tipo_registro_id,
    v_esquema_id,
    v_tipo_formulario,
    v_requiere_municipio
  FROM v2.configuracion_acciones ca
  WHERE ca.id = v_config_id
    AND ca.activo = true
    AND v_fecha_inicio BETWEEN
        ca.vigente_desde
        AND COALESCE(
          ca.vigente_hasta,
          DATE '9999-12-31'
        );

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'CONFIG_NOT_CURRENT: no existe configuración vigente para la fecha seleccionada.';
  END IF;

  IF v_config_action_id <> v_action_id THEN
    RAISE EXCEPTION
      'CONFIG_ACTION_MISMATCH: configuración y acción no coinciden.';
  END IF;


  -- --------------------------------------------------------------------------
  -- Territorio / alcance
  -- --------------------------------------------------------------------------

  IF v_requiere_municipio
     AND v_municipio_id IS NULL THEN
    RAISE EXCEPTION
      'MUNICIPALITY_REQUIRED: la acción requiere municipio.';
  END IF;

  IF v_municipio_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM v2.cat_municipios m
       WHERE m.id = v_municipio_id
         AND m.activo = true
     ) THEN
    RAISE EXCEPTION
      'MUNICIPALITY_INVALID: municipio inexistente o inactivo.';
  END IF;

  IF v_role = 'CAPTURISTA'
     AND NOT v2_private.has_scope(
       v_unit_id,
       v_municipio_id
     ) THEN
    RAISE EXCEPTION
      'SCOPE_FORBIDDEN: la captura queda fuera del alcance asignado.';
  END IF;

  IF v_espacio_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM v2.cat_espacios e
       WHERE e.id = v_espacio_id
         AND e.activo = true
         AND (
           v_municipio_id IS NULL
           OR e.municipio_id = v_municipio_id
         )
     ) THEN
    RAISE EXCEPTION
      'SPACE_INVALID: el espacio no corresponde al municipio.';
  END IF;


  -- --------------------------------------------------------------------------
  -- INSERT núcleo
  --
  -- No acepta folio, estatus, origen ni created_by del cliente.
  -- --------------------------------------------------------------------------

  INSERT INTO v2.registros (
    folio,

    unidad_operativa_id,
    programa_id,
    accion_id,
    tipo_registro_id,
    configuracion_accion_id,

    municipio_id,
    espacio_id,

    nombre,
    descripcion,

    fecha_inicio,
    fecha_fin,

    periodo_anio,
    periodo_mes,

    total_beneficiarios,
    total_participantes,
    total_accesos,

    esquema_demografico_id,

    estatus,
    origen,

    metadata,

    created_by,
    updated_by
  )
  VALUES (
    NULL,

    v_unit_id,
    v_program_id,
    v_action_id,
    v_tipo_registro_id,
    v_config_id,

    v_municipio_id,
    v_espacio_id,

    v_nombre,
    v_descripcion,

    v_fecha_inicio,
    v_fecha_fin,

    EXTRACT(
      YEAR FROM v_fecha_inicio
    )::INTEGER,

    EXTRACT(
      MONTH FROM v_fecha_inicio
    )::SMALLINT,

    v_total_beneficiarios,
    v_total_participantes,
    v_total_accesos,

    v_esquema_id,

    'BORRADOR',
    'MANUAL',

    v_metadata,

    v_uid,
    v_uid
  )
  RETURNING
    v2.registros.id,
    v2.registros.folio
  INTO
    v_registro_id,
    v_folio;


  -- --------------------------------------------------------------------------
  -- Taller / capacitación
  -- --------------------------------------------------------------------------

  v_taller :=
    p_payload -> 'taller';

  IF v_taller IS NOT NULL
     AND jsonb_typeof(v_taller) = 'object'
     AND upper(
       COALESCE(v_tipo_formulario, '')
     ) IN ('TALLER', 'CAPACITACION') THEN

    v_costo :=
      NULLIF(
        v_taller ->> 'costo',
        ''
      )::NUMERIC(14,2);

    IF v_costo IS NOT NULL
       AND v_costo < 0 THEN
      RAISE EXCEPTION
        'COST_INVALID: el costo no puede ser negativo.';
    END IF;

    INSERT INTO v2.registro_taller (
      registro_id,
      disciplina,
      programacion,
      modalidad_cuota,
      costo,
      moneda,
      observaciones,
      created_by,
      updated_by
    )
    VALUES (
      v_registro_id,

      NULLIF(
        pg_catalog.btrim(
          v_taller ->> 'disciplina'
        ),
        ''
      ),

      NULLIF(
        pg_catalog.btrim(
          v_taller ->> 'programacion'
        ),
        ''
      ),

      NULLIF(
        pg_catalog.btrim(
          v_taller ->> 'modalidad_cuota'
        ),
        ''
      ),

      v_costo,

      'MXN',

      NULLIF(
        pg_catalog.btrim(
          v_taller ->> 'observaciones'
        ),
        ''
      ),

      v_uid,
      v_uid
    );
  END IF;


  -- --------------------------------------------------------------------------
  -- Demografía
  -- --------------------------------------------------------------------------

  v_demo :=
    COALESCE(
      p_payload -> 'demografia',
      '[]'::JSONB
    );

  IF jsonb_typeof(v_demo) <> 'array' THEN
    RAISE EXCEPTION
      'DEMOGRAPHY_INVALID: demografia debe ser un arreglo JSON.';
  END IF;

  IF jsonb_array_length(v_demo) > 0
     AND v_esquema_id IS NULL THEN
    RAISE EXCEPTION
      'DEMOGRAPHY_SCHEMA_REQUIRED: la configuración no tiene esquema demográfico.';
  END IF;

  FOR v_demo_item
  IN
    SELECT value
    FROM jsonb_array_elements(v_demo)
  LOOP
    v_opcion_id :=
      NULLIF(
        v_demo_item ->> 'opcion_poblacion_id',
        ''
      )::UUID;

    v_universo :=
      upper(
        NULLIF(
          pg_catalog.btrim(
            v_demo_item ->> 'universo'
          ),
          ''
        )
      );

    v_cantidad :=
      NULLIF(
        v_demo_item ->> 'cantidad',
        ''
      )::INTEGER;

    IF v_opcion_id IS NULL
       OR v_universo IS NULL
       OR v_cantidad IS NULL THEN
      RAISE EXCEPTION
        'DEMOGRAPHY_ROW_INVALID: faltan opción, universo o cantidad.';
    END IF;

    IF v_universo NOT IN (
      'BENEFICIARIOS',
      'PARTICIPANTES',
      'ACCESOS'
    ) THEN
      RAISE EXCEPTION
        'DEMOGRAPHY_UNIVERSE_INVALID: universo % no permitido.',
        v_universo;
    END IF;

    IF v_cantidad <= 0 THEN
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM v2.esquema_opciones_poblacion eo
      WHERE eo.esquema_id = v_esquema_id
        AND eo.opcion_poblacion_id =
            v_opcion_id
        AND eo.activo = true
    ) THEN
      RAISE EXCEPTION
        'DEMOGRAPHY_OPTION_INVALID: opción fuera del esquema vigente.';
    END IF;

    INSERT INTO v2.registro_poblacion (
      registro_id,
      opcion_poblacion_id,
      universo,
      cantidad,
      observaciones,
      created_by
    )
    VALUES (
      v_registro_id,
      v_opcion_id,
      v_universo,
      v_cantidad,
      'Captura directa V2 mediante RPC; valor no inferido.',
      v_uid
    )
    ON CONFLICT (
      registro_id,
      opcion_poblacion_id,
      universo
    )
    DO UPDATE SET
      cantidad = EXCLUDED.cantidad,
      observaciones =
        EXCLUDED.observaciones,
      updated_at =
        pg_catalog.now();
  END LOOP;


  -- --------------------------------------------------------------------------
  -- Resultado
  -- --------------------------------------------------------------------------

  RETURN QUERY
  SELECT
    v_registro_id,
    v_folio,
    'BORRADOR'::TEXT;
END;
$$;


-- ============================================================================
-- 03. PERMISOS DE RPC
-- ============================================================================

REVOKE ALL
ON FUNCTION v2.rpc_create_borrador(JSONB)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION v2.rpc_create_borrador(JSONB)
TO authenticated;


-- ============================================================================
-- 04. REGISTRO
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.12c',
  '12c_rpc_create_borrador.sql - Cierra INSERT directo y crea RPC transaccional segura para borradores V2.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;


-- ============================================================================
-- 05. VERIFICACIÓN
--
-- Esperado:
-- true | true | false | 0 | 1
-- ============================================================================

SELECT
  (
    to_regprocedure(
      'v2.rpc_create_borrador(jsonb)'
    ) IS NOT NULL
  ) AS rpc_existe,

  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.rpc_create_borrador(jsonb)',
    'EXECUTE'
  ) AS authenticated_rpc,

  pg_catalog.has_function_privilege(
    'anon',
    'v2.rpc_create_borrador(jsonb)',
    'EXECUTE'
  ) AS anon_rpc,

  (
    SELECT count(*)
    FROM pg_policies
    WHERE schemaname = 'v2'
      AND tablename = 'registros'
      AND cmd = 'INSERT'
  ) AS policies_insert_directo,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12c'
  ) AS migracion_registrada;
