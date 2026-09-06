-- ============================================================================
-- VINCULACION CULTURAL V2
-- 12m_import_multibatch_duplicates.sql
-- Etapa 6.5.5: permite continuar una importacion cuando un lote intermedio
-- contiene solamente duplicados.
-- ============================================================================

BEGIN;

DO $hotfix$
DECLARE
  v_definition TEXT;
  v_previous TEXT := 'j.estatus IN (''LEYENDO'', ''VALIDANDO'', ''LISTO'')';
  v_corrected TEXT := 'j.estatus IN (''LEYENDO'', ''VALIDANDO'', ''LISTO'', ''ERROR'')';
BEGIN
  IF to_regprocedure('v2.rpc_import_cargar_lote(uuid,jsonb)') IS NULL
     OR to_regclass('v2.schema_migrations') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION_FALLIDA: instale primero 12j_bulk_excel_import.sql.';
  END IF;

  v_definition := pg_catalog.pg_get_functiondef(
    'v2.rpc_import_cargar_lote(uuid,jsonb)'::REGPROCEDURE
  );

  IF pg_catalog.strpos(v_definition, v_corrected) = 0 THEN
    IF pg_catalog.strpos(v_definition, v_previous) = 0 THEN
      RAISE EXCEPTION
        'HOTFIX_ABORTADO: no se encontro la validacion de estatus esperada.';
    END IF;

    v_definition := pg_catalog.replace(
      v_definition,
      v_previous,
      v_corrected
    );
    EXECUTE v_definition;
  END IF;
END
$hotfix$;

COMMENT ON FUNCTION v2.rpc_import_cargar_lote(UUID, JSONB) IS
'Carga lotes de importacion y permite continuar despues de un lote compuesto solo por duplicados.';

REVOKE ALL ON FUNCTION v2.rpc_import_cargar_lote(UUID, JSONB)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION v2.rpc_import_cargar_lote(UUID, JSONB)
  TO authenticated;

INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12m',
  '12m_import_multibatch_duplicates.sql - Continuidad segura de cargas multibloque con lotes intermedios duplicados.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'v2.rpc_import_cargar_lote(uuid,jsonb)'::REGPROCEDURE
    ),
    'j.estatus IN (''LEYENDO'', ''VALIDANDO'', ''LISTO'', ''ERROR'')'
  ) > 0 AS admite_lote_duplicado_intermedio,
  COALESCE(
    has_function_privilege(
      'authenticated',
      'v2.rpc_import_cargar_lote(uuid,jsonb)',
      'EXECUTE'
    ),
    false
  ) AS authenticated_lote,
  COALESCE(
    has_function_privilege(
      'anon',
      'v2.rpc_import_cargar_lote(uuid,jsonb)',
      'EXECUTE'
    ),
    false
  ) AS anon_lote,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12m')
    AS migracion_registrada;

-- Resultado esperado:
-- true | true | false | 1
