-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 11_tests.sql
-- Batería final de validación técnica V2.1
-- Secretaría de Cultura de Guanajuato
--
-- ESTE ARCHIVO ES 100% READ-ONLY.
--
-- OBJETIVO:
--   Validar de extremo a extremo:
--
--   ✓ arquitectura V2
--   ✓ RLS / grants / funciones sensibles
--   ✓ Auth y perfiles
--   ✓ Storage privado
--   ✓ vistas security_invoker + RPC
--   ✓ catálogos y regionalización
--   ✓ modelo demográfico versionado
--   ✓ indicadores y metas
--   ✓ reconciliación V1 -> staging -> V2
--   ✓ folios y trazabilidad
--   ✓ protección contra datos artificiales
--   ✓ población normalizada
--   ✓ detalle de talleres/formación
--   ✓ auditoría
--
-- RESULTADO:
--
--   PASS
--     = todas las pruebas críticas pasan y no hay advertencias.
--
--   PASS_WITH_WARNINGS
--     = arquitectura/migración correctas, con pendientes DELIBERADOS
--       (por ejemplo las 79 filas conservadas en staging).
--
--   FAIL
--     = al menos una prueba CRITICAL falla.
--
-- NO:
--   ✗ modifica V1
--   ✗ modifica V2
--   ✗ crea objetos
--   ✗ registra schema_migrations
-- ============================================================================

BEGIN TRANSACTION READ ONLY;

SET LOCAL statement_timeout = '240s';


-- ============================================================================
-- 00. PRECONDICIONES MÍNIMAS
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.import_jobs') IS NULL
     OR to_regclass('v2.import_staging') IS NULL
     OR to_regclass('v2.audit_log') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: V2 no está instalado completamente.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.10'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: 10_legacy_migration.sql no está registrado.';
  END IF;
END
$$;


-- ============================================================================
-- 01. MÉTRICAS
-- ============================================================================

WITH

required_migrations(version) AS (
  VALUES
    ('2.1.01'),
    ('2.1.02'),
    ('2.1.03'),
    ('2.1.04'),
    ('2.1.05'),
    ('2.1.05a'),
    ('2.1.06'),
    ('2.1.07'),
    ('2.1.08'),
    ('2.1.09'),
    ('2.1.09b'),
    ('2.1.09d'),
    ('2.1.09e'),
    ('2.1.10b'),
    ('2.1.10')
),

expected_views(nombre) AS (
  VALUES
    ('vw_registros_operativos'),
    ('vw_pendientes_validacion'),
    ('vw_calidad_datos'),
    ('vw_resumen_municipios'),
    ('vw_resumen_unidades'),
    ('vw_aportes_indicadores'),
    ('vw_avance_indicadores')
),

migration_job AS (
  SELECT *
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  ORDER BY created_at DESC
  LIMIT 1
),

stage AS (
  SELECT s.*
  FROM v2.import_staging s
  JOIN migration_job j
    ON j.id = s.import_job_id
),

migrados AS (
  SELECT r.*
  FROM v2.registros r
  JOIN migration_job j
    ON j.id = r.import_job_id
  WHERE r.origen = 'MIGRACION_V1'
),

metrics AS (
  SELECT

    -- ------------------------------------------------------------------------
    -- Arquitectura / migraciones
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM required_migrations rm
      WHERE EXISTS (
        SELECT 1
        FROM v2.schema_migrations sm
        WHERE sm.version = rm.version
      )
    )::INTEGER
      AS required_migrations_present,

    (
      SELECT count(*)
      FROM required_migrations
    )::INTEGER
      AS required_migrations_expected,

    (
      SELECT count(*)
      FROM information_schema.tables
      WHERE table_schema = 'v2'
        AND table_type = 'BASE TABLE'
    )::INTEGER
      AS v2_tables,

    (
      SELECT count(*)
      FROM pg_class c
      JOIN pg_namespace n
        ON n.oid = c.relnamespace
      WHERE n.nspname = 'v2'
        AND c.relkind = 'r'
        AND c.relrowsecurity = true
    )::INTEGER
      AS v2_tables_rls,

    (
      SELECT count(*)
      FROM pg_policies p
      WHERE p.schemaname = 'v2'
        AND (
          'anon' = ANY(p.roles)
          OR 'public' = ANY(p.roles)
        )
    )::INTEGER
      AS v2_policies_anon_public,

    (
      SELECT count(*)
      FROM information_schema.role_table_grants g
      WHERE g.table_schema = 'v2'
        AND lower(g.grantee) IN (
          'anon',
          'public'
        )
    )::INTEGER
      AS v2_grants_anon_public,

    (
      SELECT count(*)
      FROM pg_proc p
      JOIN pg_namespace n
        ON n.oid = p.pronamespace
      WHERE n.nspname IN (
        'v2',
        'v2_private'
      )
        AND p.prosecdef = true
        AND NOT EXISTS (
          SELECT 1
          FROM unnest(
            COALESCE(
              p.proconfig,
              ARRAY[]::TEXT[]
            )
          ) cfg
          WHERE cfg LIKE 'search_path=%'
        )
    )::INTEGER
      AS security_definer_without_search_path,

    (
      SELECT count(*)
      FROM pg_proc p
      JOIN pg_namespace n
        ON n.oid = p.pronamespace
      WHERE n.nspname = 'v2'
        AND p.proname IN (
          'audit_catalog_change',
          'audit_profile_change',
          'audit_registro_change',
          'audit_operational_change',
          'audit_evidence_change',
          'audit_import_change'
        )
        AND pg_get_functiondef(p.oid)
            ILIKE '%pg_catalog.current_user%'
    )::INTEGER
      AS audit_functions_with_old_bug,

    -- ------------------------------------------------------------------------
    -- Auth / perfiles
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM auth.users u
      LEFT JOIN v2.profiles p
        ON p.user_id = u.id
      WHERE p.user_id IS NULL
    )::INTEGER
      AS auth_without_v2_profile,

    (
      SELECT count(*)
      FROM v2.profiles p
      LEFT JOIN auth.users u
        ON u.id = p.user_id
      WHERE u.id IS NULL
    )::INTEGER
      AS orphan_v2_profiles,

    (
      SELECT count(*)
      FROM v2.profiles
      WHERE rol = 'ADMIN'
        AND activo = true
    )::INTEGER
      AS active_admins,

    -- ------------------------------------------------------------------------
    -- Storage
    -- ------------------------------------------------------------------------

    EXISTS (
      SELECT 1
      FROM storage.buckets
      WHERE id = 'evidencias-v2'
    )
      AS storage_v2_exists,

    COALESCE(
      (
        SELECT public
        FROM storage.buckets
        WHERE id = 'evidencias-v2'
        LIMIT 1
      ),
      true
    )
      AS storage_v2_public,

    (
      SELECT count(*)
      FROM pg_policies
      WHERE schemaname = 'storage'
        AND tablename = 'objects'
        AND policyname IN (
          'v2_evidencias_select',
          'v2_evidencias_insert',
          'v2_evidencias_delete'
        )
    )::INTEGER
      AS storage_v2_policies,

    (
      SELECT count(*)
      FROM pg_policies
      WHERE schemaname = 'storage'
        AND tablename = 'objects'
        AND policyname IN (
          'v2_evidencias_select',
          'v2_evidencias_insert',
          'v2_evidencias_delete'
        )
        AND (
          'anon' = ANY(roles)
          OR 'public' = ANY(roles)
        )
    )::INTEGER
      AS storage_v2_anon_public_policies,

    EXISTS (
      SELECT 1
      FROM storage.buckets
      WHERE id = 'evidencias'
    )
      AS storage_v1_exists,

    -- ------------------------------------------------------------------------
    -- Views / RPC
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM expected_views ev
      WHERE to_regclass(
        'v2.' || ev.nombre
      ) IS NOT NULL
    )::INTEGER
      AS expected_views_present,

    (
      SELECT count(*)
      FROM expected_views ev
      JOIN pg_class c
        ON c.oid = to_regclass(
          'v2.' || ev.nombre
        )
      WHERE COALESCE(
        c.reloptions,
        ARRAY[]::TEXT[]
      ) @> ARRAY[
        'security_invoker=true'
      ]::TEXT[]
    )::INTEGER
      AS expected_views_security_invoker,

    (
      to_regprocedure(
        'v2.rpc_dashboard_resumen(integer,uuid,uuid)'
      ) IS NOT NULL
    )
      AS dashboard_rpc_exists,

    -- ------------------------------------------------------------------------
    -- Catálogos base
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM v2.cat_unidades_operativas
      WHERE upper(btrim(clave)) IN (
        'CDCM',
        'BIBLIOTECAS'
      )
        AND activo = true
    )::INTEGER
      AS base_units,

    (
      SELECT count(*)
      FROM v2.cat_municipios
      WHERE activo = true
    )::INTEGER
      AS active_municipalities,

    (
      SELECT count(*)
      FROM v2.cat_municipios m
      JOIN v2.cat_regiones r
        ON r.id = m.region_id
      WHERE m.activo = true
        AND r.activo = true
        AND upper(btrim(r.clave)) IN (
          'RI',
          'RII',
          'RIII',
          'RIV'
        )
    )::INTEGER
      AS municipalities_with_cdcm_region,

    (
      SELECT count(*)
      FROM v2.cat_regiones
      WHERE upper(btrim(clave)) IN (
        'RI',
        'RII',
        'RIII',
        'RIV'
      )
        AND activo = true
    )::INTEGER
      AS cdcm_regions,

    -- ------------------------------------------------------------------------
    -- Demografía
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM v2.cat_esquemas_demograficos
      WHERE upper(btrim(clave)) IN (
        'HISTORICO_V1_2025',
        'OFICIAL_2026'
      )
        AND activo = true
    )::INTEGER
      AS demographic_schemes,

    (
      SELECT count(*)
      FROM v2.esquema_opciones_poblacion eo
      JOIN v2.cat_esquemas_demograficos e
        ON e.id = eo.esquema_id
      WHERE upper(btrim(e.clave))
            = 'HISTORICO_V1_2025'
        AND eo.activo = true
    )::INTEGER
      AS historical_demographic_options,

    (
      SELECT count(*)
      FROM v2.esquema_opciones_poblacion eo
      JOIN v2.cat_esquemas_demograficos e
        ON e.id = eo.esquema_id
      WHERE upper(btrim(e.clave))
            = 'OFICIAL_2026'
        AND eo.activo = true
    )::INTEGER
      AS demographic_options_2026,

    -- ------------------------------------------------------------------------
    -- Indicadores
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM v2.indicadores_version
      WHERE ejercicio = 2025
        AND upper(btrim(clave)) IN (
          'I10465',
          'I10689',
          'I12430',
          'I12431',
          'I09194'
        )
    )::INTEGER
      AS indicator_versions_2025,

    (
      SELECT count(*)
      FROM v2.indicadores_version
      WHERE ejercicio = 2026
        AND upper(btrim(clave)) IN (
          'QC4102.2601',
          'PB3562.2601',
          'PB3562.2602',
          'PB3562.2603',
          'PB3562.2604',
          'PB3562.2605',
          'PB3563.2601',
          'PB3563.2602',
          'PB3563.2603',
          'PB3563.2604',
          'PB3563.2605',
          'PB3564.2601',
          'PB3564.2602',
          'PB3564.2603'
        )
    )::INTEGER
      AS indicator_versions_2026,

    (
      SELECT count(*)
      FROM v2.metas_indicador m
      JOIN v2.indicadores_version iv
        ON iv.id = m.indicador_version_id
      WHERE iv.ejercicio = 2026
        AND m.alcance = 'ESTATAL'
        AND m.activo = true
        AND upper(btrim(iv.clave)) IN (
          'QC4102.2601',
          'PB3562.2601',
          'PB3562.2602',
          'PB3562.2603',
          'PB3562.2604',
          'PB3562.2605',
          'PB3563.2601',
          'PB3563.2602',
          'PB3563.2603',
          'PB3563.2604',
          'PB3563.2605',
          'PB3564.2601',
          'PB3564.2602',
          'PB3564.2603'
        )
    )::INTEGER
      AS goals_2026,

    (
      SELECT count(*)
      FROM v2.accion_indicador ai
      JOIN v2.indicadores_version iv
        ON iv.id = ai.indicador_version_id
      WHERE iv.ejercicio = 2026
        AND ai.regla_aporte = 'UNO_POR_REGISTRO'
        AND ai.activo = true
        AND upper(btrim(iv.clave)) LIKE 'PB356%'
    )::INTEGER
      AS automatic_rules_pb_2026,

    (
      SELECT count(*)
      FROM v2.accion_indicador ai
      JOIN v2.indicadores_version iv
        ON iv.id = ai.indicador_version_id
      WHERE iv.ejercicio = 2026
        AND upper(btrim(iv.clave))
            = 'QC4102.2601'
        AND ai.activo = true
    )::INTEGER
      AS automatic_rules_qc4102,

    -- ------------------------------------------------------------------------
    -- Migración / reconciliación
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM public.registros_culturales
    )::INTEGER
      AS v1_rows,

    (
      SELECT count(*)
      FROM migration_job
    )::INTEGER
      AS migration_jobs,

    (
      SELECT count(*)
      FROM stage
    )::INTEGER
      AS stage_rows,

    (
      SELECT count(*)
      FROM stage
      WHERE estatus = 'IMPORTADO'
    )::INTEGER
      AS stage_imported,

    (
      SELECT count(*)
      FROM stage
      WHERE estatus = 'ERROR'
    )::INTEGER
      AS stage_pending,

    (
      SELECT count(*)
      FROM migrados
    )::INTEGER
      AS migrated_rows,

    (
      SELECT count(*)
      FROM migrados
      WHERE estatus = 'BORRADOR'
    )::INTEGER
      AS migrated_drafts,

    (
      SELECT count(*)
      FROM migrados
      WHERE folio IS NOT NULL
        AND btrim(folio) <> ''
    )::INTEGER
      AS migrated_with_v2_folio,

    (
      SELECT count(*)
      FROM migrados
      WHERE legacy_folio IS NOT NULL
        AND btrim(legacy_folio) <> ''
    )::INTEGER
      AS migrated_with_legacy_folio,

    (
      SELECT count(*)
      FROM migrados
      WHERE metadata
            #>> '{migration,configuracion_por_fallback}'
            = 'true'
    )::INTEGER
      AS migrated_config_fallback,

    (
      SELECT count(*)
      FROM (
        SELECT folio
        FROM migrados
        GROUP BY folio
        HAVING count(*) > 1
      ) q
    )::INTEGER
      AS duplicate_v2_folios,

    (
      SELECT count(*)
      FROM migrados
      WHERE folio !~
        '^SC-V-[0-9]{4}-[0-9]{6}$'
    )::INTEGER
      AS invalid_v2_folio_format,

    (
      SELECT count(*)
      FROM migrados
      WHERE split_part(
              folio,
              '-',
              3
            )::INTEGER
            <> periodo_anio
    )::INTEGER
      AS folio_year_mismatch,

    (
      SELECT count(*)
      FROM (
        SELECT
          import_job_id,
          fila_origen
        FROM migrados
        GROUP BY
          import_job_id,
          fila_origen
        HAVING count(*) > 1
      ) q
    )::INTEGER
      AS duplicate_import_row_links,

    (
      SELECT count(*)
      FROM migrados
      WHERE import_job_id IS NULL
         OR fila_origen IS NULL
         OR legacy_payload = '{}'::jsonb
         OR metadata
            #>> '{migration,staging_id}'
            IS NULL
    )::INTEGER
      AS migrated_without_traceability,

    (
      SELECT count(*)
      FROM migrados r
      LEFT JOIN stage s
        ON s.import_job_id = r.import_job_id
       AND s.numero_fila = r.fila_origen
      WHERE s.id IS NULL
    )::INTEGER
      AS migrated_without_stage_row,

    (
      SELECT count(*)
      FROM stage s
      WHERE s.estatus = 'IMPORTADO'
        AND NOT EXISTS (
          SELECT 1
          FROM migrados r
          WHERE r.import_job_id
                = s.import_job_id
            AND r.fila_origen
                = s.numero_fila
            AND r.id::TEXT
                = s.normalized_data
                  ->> 'target_registro_id'
        )
    )::INTEGER
      AS imported_stage_without_matching_target,

    (
      SELECT count(*)
      FROM migrados r
      JOIN v2.configuracion_acciones ca
        ON ca.id = r.configuracion_accion_id
      WHERE ca.accion_id <> r.accion_id
    )::INTEGER
      AS record_config_action_mismatch,

    (
      SELECT count(*)
      FROM migrados
      WHERE unidad_operativa_id IS NULL
         OR accion_id IS NULL
         OR tipo_registro_id IS NULL
         OR configuracion_accion_id IS NULL
         OR municipio_id IS NULL
    )::INTEGER
      AS migrated_missing_core_fk,

    -- ------------------------------------------------------------------------
    -- Protección contra inferencias / calidad histórica
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM migrados
      WHERE metadata
            #>> '{migration,total_uno_artificial}'
            = 'true'
        AND total_beneficiarios IS NOT NULL
    )::INTEGER
      AS copied_artificial_ones,

    (
      SELECT count(*)
      FROM migrados
      WHERE total_participantes IS NOT NULL
         OR total_accesos IS NOT NULL
    )::INTEGER
      AS inferred_participation_access,

    (
      SELECT count(*)
      FROM migrados m
      JOIN stage s
        ON s.import_job_id = m.import_job_id
       AND s.numero_fila = m.fila_origen
      WHERE COALESCE(
              (
                s.normalized_data
                  ->> 'migrar_demografia'
              )::BOOLEAN,
              false
            ) = false
        AND EXISTS (
          SELECT 1
          FROM v2.registro_poblacion rp
          WHERE rp.registro_id = m.id
        )
    )::INTEGER
      AS demography_created_when_forbidden,

    (
      SELECT count(*)
      FROM v2.registro_poblacion rp
      JOIN migrados m
        ON m.id = rp.registro_id
      WHERE rp.universo <> 'BENEFICIARIOS'
    )::INTEGER
      AS migrated_population_wrong_universe,

    (
      SELECT count(*)
      FROM v2.registro_poblacion rp
      JOIN migrados m
        ON m.id = rp.registro_id
      WHERE rp.cantidad <= 0
    )::INTEGER
      AS migrated_population_nonpositive,

    (
      SELECT count(DISTINCT rp.registro_id)
      FROM v2.registro_poblacion rp
      JOIN migrados m
        ON m.id = rp.registro_id
    )::INTEGER
      AS migrated_with_normalized_demography,

    -- ------------------------------------------------------------------------
    -- Talleres / detalle especializado
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM migrados m
      JOIN v2.configuracion_acciones ca
        ON ca.id = m.configuracion_accion_id
      WHERE ca.tipo_formulario IN (
        'TALLER',
        'CAPACITACION'
      )
    )::INTEGER
      AS migrated_formacion_expected,

    (
      SELECT count(*)
      FROM v2.registro_taller rt
      JOIN migrados m
        ON m.id = rt.registro_id
    )::INTEGER
      AS migrated_taller_details,

    (
      SELECT count(*)
      FROM migrados m
      JOIN v2.configuracion_acciones ca
        ON ca.id = m.configuracion_accion_id
      WHERE ca.tipo_formulario IN (
        'TALLER',
        'CAPACITACION'
      )
        AND NOT EXISTS (
          SELECT 1
          FROM v2.registro_taller rt
          WHERE rt.registro_id = m.id
        )
    )::INTEGER
      AS missing_taller_details,

    (
      SELECT count(*)
      FROM v2.registro_taller rt
      JOIN migrados m
        ON m.id = rt.registro_id
      JOIN v2.configuracion_acciones ca
        ON ca.id = m.configuracion_accion_id
      WHERE ca.tipo_formulario NOT IN (
        'TALLER',
        'CAPACITACION'
      )
    )::INTEGER
      AS unexpected_taller_details,

    -- ------------------------------------------------------------------------
    -- Evidencias
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM v2.registro_evidencias re
      JOIN migrados m
        ON m.id = re.registro_id
    )::INTEGER
      AS migrated_v2_evidences,

    (
      SELECT count(*)
      FROM migrados m
      WHERE NULLIF(
              btrim(
                m.legacy_payload
                  ->> 'foto_url'
              ),
              ''
            ) IS NOT NULL
        AND COALESCE(
              m.metadata
                #>> '{legacy,foto_url_original}',
              ''
            )
            <> COALESCE(
              m.legacy_payload
                ->> 'foto_url',
              ''
            )
    )::INTEGER
      AS legacy_evidence_metadata_mismatch,

    -- ------------------------------------------------------------------------
    -- Auditoría
    -- ------------------------------------------------------------------------

    (
      SELECT count(*)
      FROM v2.audit_log al
      JOIN migrados m
        ON al.record_id = m.id::TEXT
      WHERE al.schema_name = 'v2'
        AND al.table_name = 'registros'
        AND al.accion = 'INSERT'
    )::INTEGER
      AS migrated_insert_audit_rows,

    EXISTS (
      SELECT 1
      FROM pg_trigger t
      WHERE t.tgrelid = 'v2.audit_log'::regclass
        AND t.tgname =
            'trg_v2_audit_log_immutable'
        AND NOT t.tgisinternal
    )
      AS audit_immutable_trigger,

    -- ------------------------------------------------------------------------
    -- Job
    -- ------------------------------------------------------------------------

    COALESCE(
      (
        SELECT estatus
        FROM migration_job
      ),
      '[SIN_JOB]'
    )
      AS migration_job_status,

    COALESCE(
      (
        SELECT filas_importadas
        FROM migration_job
      ),
      -1
    )::INTEGER
      AS migration_job_imported,

    COALESCE(
      (
        SELECT filas_error
        FROM migration_job
      ),
      -1
    )::INTEGER
      AS migration_job_errors

),


-- ============================================================================
-- 02. PRUEBAS
-- ============================================================================

tests AS (

  -- ------------------------------------------------------------------------
  -- Arquitectura / seguridad
  -- ------------------------------------------------------------------------

  SELECT
    10 AS orden,
    'CRITICAL'::TEXT AS severidad,
    'Migrations requeridas instaladas'::TEXT AS prueba,
    (
      m.required_migrations_present
      = m.required_migrations_expected
    ) AS pasa,
    m.required_migrations_present::TEXT AS observado,
    m.required_migrations_expected::TEXT AS esperado
  FROM metrics m

  UNION ALL

  SELECT
    20,
    'CRITICAL',
    'Todas las tablas V2 tienen RLS',
    (
      m.v2_tables >= 47
      AND m.v2_tables_rls = m.v2_tables
    ),
    m.v2_tables_rls::TEXT
      || '/' || m.v2_tables::TEXT,
    'todas / mínimo 47 tablas'
  FROM metrics m

  UNION ALL

  SELECT
    30,
    'CRITICAL',
    'Sin policies V2 para anon/public',
    m.v2_policies_anon_public = 0,
    m.v2_policies_anon_public::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    40,
    'CRITICAL',
    'Sin grants V2 para anon/public',
    m.v2_grants_anon_public = 0,
    m.v2_grants_anon_public::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    50,
    'CRITICAL',
    'SECURITY DEFINER con search_path fijado',
    m.security_definer_without_search_path = 0,
    m.security_definer_without_search_path::TEXT,
    '0 funciones inseguras'
  FROM metrics m

  UNION ALL

  SELECT
    60,
    'CRITICAL',
    'Hotfix audit current_user aplicado',
    m.audit_functions_with_old_bug = 0,
    m.audit_functions_with_old_bug::TEXT,
    '0 funciones con pg_catalog.current_user'
  FROM metrics m

  UNION ALL

  SELECT
    70,
    'CRITICAL',
    'Auth users tienen profile V2',
    m.auth_without_v2_profile = 0,
    m.auth_without_v2_profile::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    80,
    'CRITICAL',
    'Profiles V2 sin usuarios huérfanos',
    m.orphan_v2_profiles = 0,
    m.orphan_v2_profiles::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    90,
    'CRITICAL',
    'Existe al menos un ADMIN activo',
    m.active_admins >= 1,
    m.active_admins::TEXT,
    '>= 1'
  FROM metrics m

  -- ------------------------------------------------------------------------
  -- Storage
  -- ------------------------------------------------------------------------

  UNION ALL

  SELECT
    100,
    'CRITICAL',
    'Bucket evidencias-v2 existe y es privado',
    (
      m.storage_v2_exists
      AND NOT m.storage_v2_public
    ),
    pg_catalog.jsonb_build_object(
      'exists', m.storage_v2_exists,
      'public', m.storage_v2_public
    )::TEXT,
    '{"exists":true,"public":false}'
  FROM metrics m

  UNION ALL

  SELECT
    110,
    'CRITICAL',
    'Storage V2 tiene 3 policies controladas',
    m.storage_v2_policies = 3,
    m.storage_v2_policies::TEXT,
    '3'
  FROM metrics m

  UNION ALL

  SELECT
    120,
    'CRITICAL',
    'Storage V2 sin policies anon/public',
    m.storage_v2_anon_public_policies = 0,
    m.storage_v2_anon_public_policies::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    130,
    'CRITICAL',
    'Bucket V1 evidencias sigue preservado',
    m.storage_v1_exists,
    m.storage_v1_exists::TEXT,
    'true'
  FROM metrics m

  -- ------------------------------------------------------------------------
  -- Views / RPC
  -- ------------------------------------------------------------------------

  UNION ALL

  SELECT
    140,
    'CRITICAL',
    '7 vistas V2 presentes',
    m.expected_views_present = 7,
    m.expected_views_present::TEXT,
    '7'
  FROM metrics m

  UNION ALL

  SELECT
    150,
    'CRITICAL',
    '7 vistas usan security_invoker',
    m.expected_views_security_invoker = 7,
    m.expected_views_security_invoker::TEXT,
    '7'
  FROM metrics m

  UNION ALL

  SELECT
    160,
    'CRITICAL',
    'RPC dashboard existe',
    m.dashboard_rpc_exists,
    m.dashboard_rpc_exists::TEXT,
    'true'
  FROM metrics m

  -- ------------------------------------------------------------------------
  -- Catálogos / demografía / indicadores
  -- ------------------------------------------------------------------------

  UNION ALL

  SELECT
    170,
    'CRITICAL',
    'Unidades base CDCM/Bibliotecas',
    m.base_units = 2,
    m.base_units::TEXT,
    '2'
  FROM metrics m

  UNION ALL

  SELECT
    180,
    'CRITICAL',
    '46 municipios oficiales activos',
    m.active_municipalities = 46,
    m.active_municipalities::TEXT,
    '46'
  FROM metrics m

  UNION ALL

  SELECT
    190,
    'CRITICAL',
    '46 municipios asignados a región CDCM',
    m.municipalities_with_cdcm_region = 46,
    m.municipalities_with_cdcm_region::TEXT,
    '46'
  FROM metrics m

  UNION ALL

  SELECT
    200,
    'CRITICAL',
    '4 regiones CDCM',
    m.cdcm_regions = 4,
    m.cdcm_regions::TEXT,
    '4'
  FROM metrics m

  UNION ALL

  SELECT
    210,
    'CRITICAL',
    '2 esquemas demográficos',
    m.demographic_schemes = 2,
    m.demographic_schemes::TEXT,
    '2'
  FROM metrics m

  UNION ALL

  SELECT
    220,
    'CRITICAL',
    '10 opciones demográficas históricas',
    m.historical_demographic_options = 10,
    m.historical_demographic_options::TEXT,
    '10'
  FROM metrics m

  UNION ALL

  SELECT
    230,
    'CRITICAL',
    '23 opciones demográficas oficiales 2026',
    m.demographic_options_2026 = 23,
    m.demographic_options_2026::TEXT,
    '23'
  FROM metrics m

  UNION ALL

  SELECT
    240,
    'CRITICAL',
    '5 indicadores históricos 2025',
    m.indicator_versions_2025 = 5,
    m.indicator_versions_2025::TEXT,
    '5'
  FROM metrics m

  UNION ALL

  SELECT
    250,
    'CRITICAL',
    '14 metas/versiones de proceso 2026',
    m.indicator_versions_2026 = 14,
    m.indicator_versions_2026::TEXT,
    '14'
  FROM metrics m

  UNION ALL

  SELECT
    260,
    'CRITICAL',
    '14 metas anuales 2026',
    m.goals_2026 = 14,
    m.goals_2026::TEXT,
    '14'
  FROM metrics m

  UNION ALL

  SELECT
    270,
    'CRITICAL',
    '13 reglas automáticas PB seguras',
    m.automatic_rules_pb_2026 = 13,
    m.automatic_rules_pb_2026::TEXT,
    '13'
  FROM metrics m

  UNION ALL

  SELECT
    280,
    'CRITICAL',
    'QC4102 sin regla automática inferida',
    m.automatic_rules_qc4102 = 0,
    m.automatic_rules_qc4102::TEXT,
    '0'
  FROM metrics m

  -- ------------------------------------------------------------------------
  -- Migración
  -- ------------------------------------------------------------------------

  UNION ALL

  SELECT
    300,
    'CRITICAL',
    'V1 permanece con 317 filas',
    m.v1_rows = 317,
    m.v1_rows::TEXT,
    '317'
  FROM metrics m

  UNION ALL

  SELECT
    310,
    'CRITICAL',
    'Existe un único migration job',
    m.migration_jobs = 1,
    m.migration_jobs::TEXT,
    '1'
  FROM metrics m

  UNION ALL

  SELECT
    320,
    'CRITICAL',
    'Staging contiene 317 filas',
    m.stage_rows = 317,
    m.stage_rows::TEXT,
    '317'
  FROM metrics m

  UNION ALL

  SELECT
    330,
    'CRITICAL',
    'Reconciliación staging 238 + 79 = 317',
    (
      m.stage_imported = 238
      AND m.stage_pending = 79
      AND m.stage_imported
          + m.stage_pending
          = m.stage_rows
    ),
    pg_catalog.jsonb_build_object(
      'imported', m.stage_imported,
      'pending', m.stage_pending,
      'total', m.stage_rows
    )::TEXT,
    '{"imported":238,"pending":79,"total":317}'
  FROM metrics m

  UNION ALL

  SELECT
    340,
    'CRITICAL',
    '238 registros migrados a V2',
    m.migrated_rows = 238,
    m.migrated_rows::TEXT,
    '238'
  FROM metrics m

  UNION ALL

  SELECT
    350,
    'CRITICAL',
    'Todos los migrados están en BORRADOR',
    m.migrated_drafts = m.migrated_rows,
    m.migrated_drafts::TEXT
      || '/' || m.migrated_rows::TEXT,
    '238/238'
  FROM metrics m

  UNION ALL

  SELECT
    360,
    'CRITICAL',
    'Todos los migrados tienen folio V2',
    m.migrated_with_v2_folio = m.migrated_rows,
    m.migrated_with_v2_folio::TEXT
      || '/' || m.migrated_rows::TEXT,
    '238/238'
  FROM metrics m

  UNION ALL

  SELECT
    370,
    'CRITICAL',
    'Folios V2 únicos',
    m.duplicate_v2_folios = 0,
    m.duplicate_v2_folios::TEXT,
    '0 duplicados'
  FROM metrics m

  UNION ALL

  SELECT
    380,
    'CRITICAL',
    'Formato folio SC-V-AAAA-000000',
    m.invalid_v2_folio_format = 0,
    m.invalid_v2_folio_format::TEXT,
    '0 inválidos'
  FROM metrics m

  UNION ALL

  SELECT
    390,
    'CRITICAL',
    'Año del folio coincide con periodo_anio',
    m.folio_year_mismatch = 0,
    m.folio_year_mismatch::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    400,
    'CRITICAL',
    'Import job/fila no duplicado',
    m.duplicate_import_row_links = 0,
    m.duplicate_import_row_links::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    410,
    'CRITICAL',
    'Trazabilidad completa de migrados',
    m.migrated_without_traceability = 0,
    m.migrated_without_traceability::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    420,
    'CRITICAL',
    'Cada migrado tiene fila staging',
    m.migrated_without_stage_row = 0,
    m.migrated_without_stage_row::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    430,
    'CRITICAL',
    'Cada staging IMPORTADO enlaza target correcto',
    m.imported_stage_without_matching_target = 0,
    m.imported_stage_without_matching_target::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    440,
    'CRITICAL',
    'Acción del registro coincide con configuración',
    m.record_config_action_mismatch = 0,
    m.record_config_action_mismatch::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    450,
    'CRITICAL',
    'Migrados sin FK núcleo faltante',
    m.migrated_missing_core_fk = 0,
    m.migrated_missing_core_fk::TEXT,
    '0'
  FROM metrics m

  -- ------------------------------------------------------------------------
  -- Calidad / población
  -- ------------------------------------------------------------------------

  UNION ALL

  SELECT
    460,
    'CRITICAL',
    'No se copiaron beneficiarios artificiales = 1',
    m.copied_artificial_ones = 0,
    m.copied_artificial_ones::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    470,
    'CRITICAL',
    'No se infirió Participación/Acceso',
    m.inferred_participation_access = 0,
    m.inferred_participation_access::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    480,
    'CRITICAL',
    'No se normalizó demografía prohibida',
    m.demography_created_when_forbidden = 0,
    m.demography_created_when_forbidden::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    490,
    'CRITICAL',
    'Población histórica solo universo BENEFICIARIOS',
    m.migrated_population_wrong_universe = 0,
    m.migrated_population_wrong_universe::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    500,
    'CRITICAL',
    'Población normalizada solo cantidades > 0',
    m.migrated_population_nonpositive = 0,
    m.migrated_population_nonpositive::TEXT,
    '0'
  FROM metrics m

  -- ------------------------------------------------------------------------
  -- Detalle talleres
  -- ------------------------------------------------------------------------

  UNION ALL

  SELECT
    510,
    'CRITICAL',
    'Formación migrada tiene detalle registro_taller',
    (
      m.missing_taller_details = 0
      AND m.migrated_taller_details
          = m.migrated_formacion_expected
    ),
    pg_catalog.jsonb_build_object(
      'expected',
        m.migrated_formacion_expected,
      'details',
        m.migrated_taller_details,
      'missing',
        m.missing_taller_details
    )::TEXT,
    'missing = 0'
  FROM metrics m

  UNION ALL

  SELECT
    520,
    'CRITICAL',
    'Sin detalles taller en formularios ajenos',
    m.unexpected_taller_details = 0,
    m.unexpected_taller_details::TEXT,
    '0'
  FROM metrics m

  -- ------------------------------------------------------------------------
  -- Evidencia
  -- ------------------------------------------------------------------------

  UNION ALL

  SELECT
    530,
    'CRITICAL',
    'Migración no fingió evidencias en bucket V2',
    m.migrated_v2_evidences = 0,
    m.migrated_v2_evidences::TEXT,
    '0'
  FROM metrics m

  UNION ALL

  SELECT
    540,
    'CRITICAL',
    'Referencia histórica de evidencia preservada',
    m.legacy_evidence_metadata_mismatch = 0,
    m.legacy_evidence_metadata_mismatch::TEXT,
    '0 discrepancias'
  FROM metrics m

  -- ------------------------------------------------------------------------
  -- Auditoría
  -- ------------------------------------------------------------------------

  UNION ALL

  SELECT
    550,
    'CRITICAL',
    'Cada INSERT migrado quedó auditado',
    m.migrated_insert_audit_rows
      >= m.migrated_rows,
    m.migrated_insert_audit_rows::TEXT,
    '>= 238'
  FROM metrics m

  UNION ALL

  SELECT
    560,
    'CRITICAL',
    'audit_log tiene trigger inmutable',
    m.audit_immutable_trigger,
    m.audit_immutable_trigger::TEXT,
    'true'
  FROM metrics m

  -- ------------------------------------------------------------------------
  -- Job
  -- ------------------------------------------------------------------------

  UNION ALL

  SELECT
    570,
    'CRITICAL',
    'Migration job cerrado correctamente',
    (
      m.migration_job_status
        = 'COMPLETADO_CON_ERRORES'
      AND m.migration_job_imported = 238
      AND m.migration_job_errors = 79
    ),
    pg_catalog.jsonb_build_object(
      'status',
        m.migration_job_status,
      'imported',
        m.migration_job_imported,
      'errors',
        m.migration_job_errors
    )::TEXT,
    '{"status":"COMPLETADO_CON_ERRORES","imported":238,"errors":79}'
  FROM metrics m

  -- ------------------------------------------------------------------------
  -- WARNINGS DELIBERADOS
  -- Estas pruebas "pasan" solo si no hay pendiente, pero NO convierten el
  -- resultado global en FAIL.
  -- ------------------------------------------------------------------------

  UNION ALL

  SELECT
    800,
    'WARNING',
    'Filas V1 pendientes en staging',
    m.stage_pending = 0,
    m.stage_pending::TEXT,
    '0 ideal; 79 esperadas en esta fase'
  FROM metrics m

  UNION ALL

  SELECT
    810,
    'WARNING',
    'Configuraciones resueltas por fallback',
    m.migrated_config_fallback = 0,
    m.migrated_config_fallback::TEXT,
    '0 ideal; fallback documentado permitido para históricos'
  FROM metrics m

  UNION ALL

  SELECT
    820,
    'WARNING',
    'Migrados sin legacy_folio',
    m.migrated_with_legacy_folio
      = m.migrated_rows,
    (
      m.migrated_rows
      - m.migrated_with_legacy_folio
    )::TEXT,
    '0 ideal; filas V1 sin folio conservan trazabilidad por staging'
  FROM metrics m

),


-- ============================================================================
-- 03. RESUMEN
-- ============================================================================

summary AS (
  SELECT
    count(*)::INTEGER
      AS tests_total,

    count(*) FILTER (
      WHERE severidad = 'CRITICAL'
    )::INTEGER
      AS critical_total,

    count(*) FILTER (
      WHERE severidad = 'CRITICAL'
        AND pasa
    )::INTEGER
      AS critical_passed,

    count(*) FILTER (
      WHERE severidad = 'CRITICAL'
        AND NOT pasa
    )::INTEGER
      AS critical_failed,

    count(*) FILTER (
      WHERE severidad = 'WARNING'
        AND NOT pasa
    )::INTEGER
      AS warnings_triggered,

    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'test', prueba,
          'observed', observado,
          'expected', esperado
        )
        ORDER BY orden
      ) FILTER (
        WHERE severidad = 'CRITICAL'
          AND NOT pasa
      ),
      '[]'::jsonb
    )
      AS critical_failures,

    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'warning', prueba,
          'observed', observado,
          'expected', esperado
        )
        ORDER BY orden
      ) FILTER (
        WHERE severidad = 'WARNING'
          AND NOT pasa
      ),
      '[]'::jsonb
    )
      AS warnings,

    jsonb_agg(
      jsonb_build_object(
        'severity', severidad,
        'test', prueba,
        'pass', pasa,
        'observed', observado,
        'expected', esperado
      )
      ORDER BY orden
    )
      AS all_test_results

  FROM tests
)


-- ============================================================================
-- 04. SALIDA ÚNICA
-- ============================================================================

SELECT
  'V2.1 - 11 final tests' AS suite,

  CASE
    WHEN s.critical_failed > 0
      THEN 'FAIL'

    WHEN s.warnings_triggered > 0
      THEN 'PASS_WITH_WARNINGS'

    ELSE 'PASS'
  END
    AS overall_status,

  s.tests_total,
  s.critical_total,
  s.critical_passed,
  s.critical_failed,
  s.warnings_triggered,

  s.critical_failures,
  s.warnings,

  -- KPIs técnicos para lectura rápida
  m.v2_tables,
  m.v2_tables_rls,

  m.v1_rows,
  m.stage_rows,
  m.stage_imported,
  m.stage_pending,
  m.migrated_rows,
  m.migrated_drafts,

  m.migrated_with_v2_folio,
  m.migrated_with_legacy_folio,

  m.migrated_config_fallback,

  m.migrated_with_normalized_demography,
  m.migrated_taller_details,

  m.migrated_insert_audit_rows,

  m.storage_v2_policies,
  m.expected_views_security_invoker,

  m.indicator_versions_2025,
  m.indicator_versions_2026,
  m.goals_2026,
  m.automatic_rules_pb_2026,

  s.all_test_results

FROM summary s
CROSS JOIN metrics m;


COMMIT;


-- ============================================================================
-- RESULTADO ESPERADO CON EL ESTADO ACTUAL
-- ============================================================================
--
-- overall_status:
--
--   PASS_WITH_WARNINGS
--
-- porque esperamos deliberadamente:
--
--   WARNING 1:
--     stage_pending = 79
--
--   WARNING 2:
--     configuraciones por fallback > 0
--     (en la migración observada fueron 237)
--
--   WARNING 3:
--     algunos registros V1 no tenían folio histórico
--     (en la migración observada: 238 migrados / 235 con legacy_folio)
--
-- LOS VALORES CRÍTICOS DEBEN SER:
--
--   critical_failed = 0
--
-- y:
--
--   v1_rows          = 317
--   stage_rows       = 317
--   stage_imported   = 238
--   stage_pending    = 79
--   migrated_rows    = 238
--   migrated_drafts  = 238
--
-- También deben permanecer en cero:
--
--   folios V2 duplicados
--   folios con formato inválido
--   artificiales = 1 copiados
--   Participación/Acceso inferidos
--   demografía creada cuando estaba prohibida
--   evidencias V2 ficticias
--   fallos de trazabilidad
--
-- IMPORTANTE:
--
-- PASS_WITH_WARNINGS NO significa que la migración falló.
-- Significa:
--
--   ✓ V2 está íntegro y la migración aprobada es consistente.
--   ✓ 238 históricos están preservados como BORRADOR.
--   ✓ 79 históricos siguen aislados para saneamiento posterior.
--   ✓ ninguna inferencia dudosa se convirtió en dato validado.
--
-- SI overall_status = PASS_WITH_WARNINGS Y critical_failed = 0:
--
--   LA FASE DE BASE DE DATOS V2.1 SE CONSIDERA CERRADA.
--
-- SIGUIENTE FASE:
--
--   FRONTEND V2
--
--   01. config.js / supabase-client.js
--   02. auth.js / permissions.js
--   03. catalogs.js
--   04. shell institucional index.html
--   05. captura dinámica
--   06. bitácora
--   07. validación
--   08. dashboard
--   09. admin
--   10. offline/PWA
--
-- Posteriormente:
--   99_vinculacion_v2_super.sql
-- será el paquete consolidado reproducible para instalaciones limpias.
-- ============================================================================
