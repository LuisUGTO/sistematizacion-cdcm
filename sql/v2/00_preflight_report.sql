-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 00_preflight_report.sql
-- Reporte consolidado de diagnóstico V1
--
-- Este script es SOLO LECTURA.
-- Devuelve un único conjunto de resultados:
--   seccion | detalle (JSON)
--
-- Después de ejecutarlo en Supabase, exporta/descarga el resultado como CSV
-- o copia las filas y compártelas para revisar el estado real antes de V2.1.
-- ============================================================================

BEGIN;
SET TRANSACTION READ ONLY;

WITH report AS (

  -- 01. Objetos clave
  SELECT
    10 AS orden,
    '01_objetos_clave'::text AS seccion,
    jsonb_agg(
      jsonb_build_object(
        'objeto', objeto,
        'existe', to_regclass(objeto) IS NOT NULL
      )
      ORDER BY objeto
    ) AS detalle
  FROM (
    VALUES
      ('public.registros_culturales'),
      ('public.cat_docentes'),
      ('public.cat_bibliotecas'),
      ('public.profiles'),
      ('storage.buckets'),
      ('storage.objects'),
      ('auth.users')
  ) t(objeto)

  UNION ALL

  -- 02. Tablas public
  SELECT
    20,
    '02_tablas_public',
    COALESCE(
      jsonb_agg(table_name ORDER BY table_name),
      '[]'::jsonb
    )
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_type = 'BASE TABLE'

  UNION ALL

  -- 03. Columnas clave
  SELECT
    30,
    '03_columnas_clave',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'tabla', table_name,
          'posicion', ordinal_position,
          'columna', column_name,
          'tipo', data_type,
          'nullable', is_nullable,
          'default', column_default
        )
        ORDER BY table_name, ordinal_position
      ),
      '[]'::jsonb
    )
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN (
      'registros_culturales',
      'cat_docentes',
      'cat_bibliotecas',
      'profiles'
    )

  UNION ALL

  -- 04. RLS
  SELECT
    40,
    '04_rls',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'schema', n.nspname,
          'tabla', c.relname,
          'rls_enabled', c.relrowsecurity,
          'force_rls', c.relforcerowsecurity
        )
        ORDER BY n.nspname, c.relname
      ),
      '[]'::jsonb
    )
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r'
    AND (
      (n.nspname = 'public'
       AND c.relname IN (
         'registros_culturales',
         'cat_docentes',
         'cat_bibliotecas',
         'profiles'
       ))
      OR
      (n.nspname = 'storage' AND c.relname = 'objects')
    )

  UNION ALL

  -- 05. Policies completas
  SELECT
    50,
    '05_policies',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'schema', schemaname,
          'tabla', tablename,
          'policy', policyname,
          'permissive', permissive,
          'roles', roles,
          'cmd', cmd,
          'using', qual,
          'with_check', with_check
        )
        ORDER BY schemaname, tablename, policyname
      ),
      '[]'::jsonb
    )
  FROM pg_policies
  WHERE
       (schemaname = 'public'
        AND tablename IN (
          'registros_culturales',
          'cat_docentes',
          'cat_bibliotecas',
          'profiles'
        ))
    OR (schemaname = 'storage' AND tablename = 'objects')

  UNION ALL

  -- 06. Policies históricas conocidas
  SELECT
    60,
    '06_policies_historicas',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'schema', schemaname,
          'tabla', tablename,
          'policy', policyname,
          'roles', roles,
          'cmd', cmd
        )
        ORDER BY schemaname, tablename, policyname
      ),
      '[]'::jsonb
    )
  FROM pg_policies
  WHERE policyname IN (
    'Permitir subida en evidencias',
    'Permitir lectura en evidencias',
    'Permitir lectura publica de bibliotecas',
    'Permitir insercion de bibliotecas',
    'Permitir eliminacion de bibliotecas',
    'Permitir lectura publica de registros',
    'Permitir insercion a usuarios autenticados y anonimos',
    'Permitir borrado a usuarios autenticados',
    'Lectura de catalogos docentes',
    'Modificacion de catalogos docentes',
    'Lectura de catalogos bibliotecas',
    'Modificacion de catalogos bibliotecas',
    'Lectura de perfiles para autenticados',
    'Edición de perfiles',
    'Subida de evidencias para usuarios autenticados',
    'Lectura de evidencias para usuarios autenticados',
    'Eliminacion de evidencias para administradores',
    'Permitir subida de evidencias',
    'Permitir lectura y signed URLs de evidencias'
  )

  UNION ALL

  -- 07. Grants
  SELECT
    70,
    '07_grants',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'schema', table_schema,
          'tabla', table_name,
          'grantee', grantee,
          'privilegio', privilege_type
        )
        ORDER BY table_schema, table_name, grantee, privilege_type
      ),
      '[]'::jsonb
    )
  FROM information_schema.role_table_grants
  WHERE table_schema IN ('public', 'storage')
    AND table_name IN (
      'registros_culturales',
      'cat_docentes',
      'cat_bibliotecas',
      'profiles',
      'objects'
    )
    AND grantee IN ('anon', 'authenticated', 'PUBLIC')

  UNION ALL

  -- 08. Constraints
  SELECT
    80,
    '08_constraints',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'tabla', tc.table_name,
          'constraint', tc.constraint_name,
          'tipo', tc.constraint_type,
          'definicion', pg_get_constraintdef(pc.oid, true)
        )
        ORDER BY tc.table_name, tc.constraint_type, tc.constraint_name
      ),
      '[]'::jsonb
    )
  FROM information_schema.table_constraints tc
  JOIN pg_constraint pc
    ON pc.conname = tc.constraint_name
  JOIN pg_namespace pn
    ON pn.oid = pc.connamespace
  WHERE tc.table_schema = 'public'
    AND tc.table_name IN (
      'registros_culturales',
      'cat_docentes',
      'cat_bibliotecas',
      'profiles'
    )
    AND pn.nspname = 'public'

  UNION ALL

  -- 09. Índices
  SELECT
    90,
    '09_indices',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'tabla', tablename,
          'indice', indexname,
          'definicion', indexdef
        )
        ORDER BY tablename, indexname
      ),
      '[]'::jsonb
    )
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename IN (
      'registros_culturales',
      'cat_docentes',
      'cat_bibliotecas',
      'profiles'
    )

  UNION ALL

  -- 10. Triggers
  SELECT
    100,
    '10_triggers',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'tabla', event_object_table,
          'trigger', trigger_name,
          'evento', event_manipulation,
          'timing', action_timing,
          'accion', action_statement
        )
        ORDER BY event_object_table, trigger_name, event_manipulation
      ),
      '[]'::jsonb
    )
  FROM information_schema.triggers
  WHERE event_object_schema = 'public'
    AND event_object_table IN (
      'registros_culturales',
      'cat_docentes',
      'cat_bibliotecas',
      'profiles'
    )

  UNION ALL

  -- 11. Funciones public
  SELECT
    110,
    '11_funciones_public',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'funcion', p.proname,
          'argumentos', pg_get_function_identity_arguments(p.oid),
          'security_definer', p.prosecdef,
          'volatility', p.provolatile,
          'owner', pg_get_userbyid(p.proowner)
        )
        ORDER BY p.proname
      ),
      '[]'::jsonb
    )
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'

  UNION ALL

  -- 12. Bucket evidencias
  SELECT
    120,
    '12_bucket_evidencias',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', id,
          'name', name,
          'public', public,
          'file_size_limit', file_size_limit,
          'allowed_mime_types', allowed_mime_types,
          'created_at', created_at,
          'updated_at', updated_at
        )
      ),
      '[]'::jsonb
    )
  FROM storage.buckets
  WHERE id = 'evidencias'

  UNION ALL

  -- 13. Conteos
  SELECT
    130,
    '13_conteos',
    jsonb_build_object(
      'registros_culturales', (SELECT count(*) FROM public.registros_culturales),
      'cat_docentes', (SELECT count(*) FROM public.cat_docentes),
      'cat_bibliotecas', (SELECT count(*) FROM public.cat_bibliotecas),
      'profiles', (SELECT count(*) FROM public.profiles),
      'auth_users', (SELECT count(*) FROM auth.users),
      'evidencias_storage', (
        SELECT count(*) FROM storage.objects WHERE bucket_id = 'evidencias'
      )
    )

  UNION ALL

  -- 14. Roles
  SELECT
    140,
    '14_roles_profiles',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'rol', rol,
          'activo', activo,
          'cantidad', cantidad
        )
        ORDER BY rol, activo DESC
      ),
      '[]'::jsonb
    )
  FROM (
    SELECT rol, activo, count(*) AS cantidad
    FROM public.profiles
    GROUP BY rol, activo
  ) x

  UNION ALL

  -- 15. Auth sin profile
  SELECT
    150,
    '15_auth_sin_profile',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'user_id', u.id,
          'email', u.email,
          'created_at', u.created_at
        )
        ORDER BY u.created_at
      ),
      '[]'::jsonb
    )
  FROM auth.users u
  LEFT JOIN public.profiles p ON p.user_id = u.id
  WHERE p.user_id IS NULL

  UNION ALL

  -- 16. Profiles huérfanos
  SELECT
    160,
    '16_profiles_huerfanos',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'user_id', p.user_id,
          'email', p.email,
          'rol', p.rol,
          'activo', p.activo
        )
        ORDER BY p.email
      ),
      '[]'::jsonb
    )
  FROM public.profiles p
  LEFT JOIN auth.users u ON u.id = p.user_id
  WHERE u.id IS NULL

  UNION ALL

  -- 17. Folios
  SELECT
    170,
    '17_folios',
    jsonb_build_object(
      'total_registros', count(*),
      'sin_folio', count(*) FILTER (
        WHERE folio IS NULL OR btrim(folio) = ''
      ),
      'folios_distintos', count(DISTINCT folio) FILTER (
        WHERE folio IS NOT NULL AND btrim(folio) <> ''
      ),
      'folios_duplicados', (
        SELECT count(*)
        FROM (
          SELECT folio
          FROM public.registros_culturales
          WHERE folio IS NOT NULL AND btrim(folio) <> ''
          GROUP BY folio
          HAVING count(*) > 1
        ) d
      )
    )
  FROM public.registros_culturales

  UNION ALL

  -- 18. Detalle folios duplicados
  SELECT
    180,
    '18_folios_duplicados',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'folio', folio,
          'repeticiones', repeticiones
        )
        ORDER BY repeticiones DESC, folio
      ),
      '[]'::jsonb
    )
  FROM (
    SELECT folio, count(*) AS repeticiones
    FROM public.registros_culturales
    WHERE folio IS NOT NULL AND btrim(folio) <> ''
    GROUP BY folio
    HAVING count(*) > 1
  ) d

  UNION ALL

  -- 19. Municipios actuales
  SELECT
    190,
    '19_municipios_actuales',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'municipio', municipio,
          'registros', registros
        )
        ORDER BY municipio NULLS FIRST
      ),
      '[]'::jsonb
    )
  FROM (
    SELECT municipio, count(*) AS registros
    FROM public.registros_culturales
    GROUP BY municipio
  ) m

  UNION ALL

  -- 20. Calidad resumida
  SELECT
    200,
    '20_calidad_resumen',
    jsonb_build_object(
      'municipio_vacio', count(*) FILTER (
        WHERE municipio IS NULL OR btrim(municipio) = ''
      ),
      'municipio_numerico_o_nan', count(*) FILTER (
        WHERE municipio ~ '^[0-9.]+$' OR municipio ILIKE '%nan%'
      ),
      'alias_cueramaro', count(*) FILTER (
        WHERE municipio = 'Cueramaro'
      ),
      'alias_stgo_mtio', count(*) FILTER (
        WHERE municipio = 'Stgo Mtío'
      ),
      'costo_parece_localidad', count(*) FILTER (
        WHERE costo ILIKE 'Col.%' OR costo ILIKE 'Com.%'
      ),
      'disciplina_solo_numeros', count(*) FILTER (
        WHERE disciplina ~ '^[0-9]+$'
      ),
      'sin_usuario', count(*) FILTER (
        WHERE usuario IS NULL OR btrim(usuario) = ''
      ),
      'sin_created_at', count(*) FILTER (
        WHERE created_at IS NULL
      )
    )
  FROM public.registros_culturales

  UNION ALL

  -- 21. Beneficiarios
  SELECT
    210,
    '21_beneficiarios',
    jsonb_build_object(
      'null', count(*) FILTER (WHERE total_beneficiarios IS NULL),
      'cero', count(*) FILTER (WHERE total_beneficiarios = 0),
      'uno', count(*) FILTER (WHERE total_beneficiarios = 1),
      'negativos', count(*) FILTER (WHERE total_beneficiarios < 0),
      'uno_posiblemente_artificial', count(*) FILTER (
        WHERE total_beneficiarios = 1
          AND COALESCE(mujeres, 0) = 0
          AND COALESCE(hombres, 0) = 0
          AND COALESCE(ninez, 0) = 0
          AND COALESCE(adolescencia, 0) = 0
          AND COALESCE(juventudes, 0) = 0
          AND COALESCE(adultos_mayores, 0) = 0
          AND COALESCE(discapacidad, 0) = 0
          AND COALESCE(indigenas, 0) = 0
          AND COALESCE(afromexicanas, 0) = 0
          AND COALESCE(lgbtq, 0) = 0
      )
    )
  FROM public.registros_culturales

  UNION ALL

  -- 22. Evidencias
  SELECT
    220,
    '22_evidencias',
    jsonb_build_object(
      'sin_evidencia', count(*) FILTER (
        WHERE foto_url IS NULL OR btrim(foto_url) = ''
      ),
      'url_completa', count(*) FILTER (
        WHERE foto_url ILIKE 'http%'
      ),
      'url_publica_historica', count(*) FILTER (
        WHERE foto_url ILIKE '%/storage/v1/object/public/evidencias/%'
      ),
      'ruta_storage', count(*) FILTER (
        WHERE foto_url IS NOT NULL
          AND btrim(foto_url) <> ''
          AND foto_url NOT ILIKE 'http%'
      )
    )
  FROM public.registros_culturales

  UNION ALL

  -- 23. Docentes
  SELECT
    230,
    '23_docentes',
    jsonb_build_object(
      'total', count(*),
      'sin_nombre', count(*) FILTER (
        WHERE nombre_docente IS NULL OR btrim(nombre_docente) = ''
      ),
      'nombres_normalizados_distintos',
        count(DISTINCT lower(btrim(nombre_docente))) FILTER (
          WHERE nombre_docente IS NOT NULL
            AND btrim(nombre_docente) <> ''
        ),
      'grupos_duplicados', (
        SELECT count(*)
        FROM (
          SELECT lower(btrim(nombre_docente))
          FROM public.cat_docentes
          WHERE nombre_docente IS NOT NULL
            AND btrim(nombre_docente) <> ''
          GROUP BY lower(btrim(nombre_docente))
          HAVING count(*) > 1
        ) d
      )
    )
  FROM public.cat_docentes

  UNION ALL

  -- 24. Bibliotecas
  SELECT
    240,
    '24_bibliotecas',
    jsonb_build_object(
      'total', count(*),
      'sin_municipio', count(*) FILTER (
        WHERE municipio IS NULL OR btrim(municipio) = ''
      ),
      'sin_nombre', count(*) FILTER (
        WHERE nombre_biblioteca IS NULL OR btrim(nombre_biblioteca) = ''
      ),
      'sin_responsable', count(*) FILTER (
        WHERE responsable IS NULL OR btrim(responsable) = ''
      ),
      'grupos_duplicados', (
        SELECT count(*)
        FROM (
          SELECT
            lower(btrim(municipio)),
            lower(btrim(nombre_biblioteca))
          FROM public.cat_bibliotecas
          WHERE municipio IS NOT NULL
            AND btrim(municipio) <> ''
            AND nombre_biblioteca IS NOT NULL
            AND btrim(nombre_biblioteca) <> ''
          GROUP BY
            lower(btrim(municipio)),
            lower(btrim(nombre_biblioteca))
          HAVING count(*) > 1
        ) b
      )
    )
  FROM public.cat_bibliotecas

  UNION ALL

  -- 25. Tipos actividad
  SELECT
    250,
    '25_tipos_actividad',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'tipo', tipo_actividad,
          'registros', registros
        )
        ORDER BY registros DESC, tipo_actividad NULLS FIRST
      ),
      '[]'::jsonb
    )
  FROM (
    SELECT tipo_actividad, count(*) AS registros
    FROM public.registros_culturales
    GROUP BY tipo_actividad
  ) t

  UNION ALL

  -- 26. Áreas
  SELECT
    260,
    '26_areas_programa',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'area', area_programa,
          'registros', registros
        )
        ORDER BY registros DESC, area_programa NULLS FIRST
      ),
      '[]'::jsonb
    )
  FROM (
    SELECT area_programa, count(*) AS registros
    FROM public.registros_culturales
    GROUP BY area_programa
  ) a

  UNION ALL

  -- 27. Fechas
  SELECT
    270,
    '27_fechas',
    jsonb_build_object(
      'primer_created_at', min(created_at),
      'ultimo_created_at', max(created_at),
      'primera_fecha_actividad', min(fecha_actividad),
      'ultima_fecha_actividad', max(fecha_actividad),
      'sin_fecha_actividad', count(*) FILTER (
        WHERE fecha_actividad IS NULL
      )
    )
  FROM public.registros_culturales

  UNION ALL

  SELECT
    999,
    '99_estado',
    jsonb_build_object(
      'resultado', 'PRE-FLIGHT REPORT COMPLETADO',
      'solo_lectura', true,
      'fecha', now()
    )
)

SELECT
  seccion,
  jsonb_pretty(detalle) AS detalle
FROM report
ORDER BY orden;

COMMIT;

-- ============================================================================
-- FIN
-- ============================================================================
