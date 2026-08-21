-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 00_preflight.sql
-- Diagnóstico PREVIO a cualquier migración V2
-- Secretaría de Cultura de Guanajuato
--
-- OBJETIVO:
--   Obtener el estado REAL de la base Supabase actual antes de ejecutar
--   cualquier ALTER / DROP / CREATE de la arquitectura V2.
--
-- SEGURIDAD:
--   Este script se ejecuta dentro de una transacción READ ONLY.
--   NO crea tablas permanentes.
--   NO altera políticas.
--   NO borra datos.
--   NO cambia Storage.
--
-- USO:
--   1. Abrir Supabase > SQL Editor.
--   2. Crear una consulta nueva.
--   3. Pegar TODO este archivo.
--   4. Ejecutar.
--   5. Guardar / capturar los resultados para revisión.
--
-- IMPORTANTE:
--   No ejecutar todavía ninguno de los SQL históricos ni el futuro Super SQL.
-- ============================================================================

BEGIN;
SET TRANSACTION READ ONLY;

-- ============================================================================
-- 00. IDENTIDAD DEL ENTORNO
-- ============================================================================

SELECT
  '00_entorno' AS seccion,
  current_database() AS database_name,
  current_user AS database_user,
  current_setting('server_version') AS postgres_version,
  current_setting('TimeZone') AS timezone,
  now() AS fecha_diagnostico;


-- ============================================================================
-- 01. EXTENSIONES DISPONIBLES
-- Útil para UUID, criptografía y futuras funciones.
-- ============================================================================

SELECT
  '01_extensiones' AS seccion,
  extname AS extension,
  extversion AS version
FROM pg_extension
WHERE extname IN ('pgcrypto', 'uuid-ossp', 'pg_stat_statements')
ORDER BY extname;


-- ============================================================================
-- 02. EXISTENCIA DE OBJETOS CLAVE V1
-- ============================================================================

SELECT
  '02_objetos_clave' AS seccion,
  objeto,
  to_regclass(objeto) IS NOT NULL AS existe
FROM (
  VALUES
    ('public.registros_culturales'),
    ('public.cat_docentes'),
    ('public.cat_bibliotecas'),
    ('public.profiles'),
    ('storage.buckets'),
    ('storage.objects'),
    ('auth.users')
) AS t(objeto)
ORDER BY objeto;


-- ============================================================================
-- 03. TABLAS DEL ESQUEMA PUBLIC
-- Inventario general.
-- ============================================================================

SELECT
  '03_tablas_public' AS seccion,
  table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;


-- ============================================================================
-- 04. COLUMNAS DE LAS TABLAS PRINCIPALES
-- ============================================================================

SELECT
  '04_columnas' AS seccion,
  table_name,
  ordinal_position,
  column_name,
  data_type,
  udt_name,
  is_nullable,
  column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN (
    'registros_culturales',
    'cat_docentes',
    'cat_bibliotecas',
    'profiles'
  )
ORDER BY table_name, ordinal_position;


-- ============================================================================
-- 05. ESTADO RLS
-- relrowsecurity = RLS habilitado
-- relforcerowsecurity = FORCE RLS
-- ============================================================================

SELECT
  '05_rls' AS seccion,
  n.nspname AS schema_name,
  c.relname AS table_name,
  c.relrowsecurity AS rls_enabled,
  c.relforcerowsecurity AS force_rls
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
ORDER BY n.nspname, c.relname;


-- ============================================================================
-- 06. POLICIES RLS REALES
-- Ésta es una de las consultas más importantes.
-- ============================================================================

SELECT
  '06_policies' AS seccion,
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
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
ORDER BY schemaname, tablename, policyname;


-- ============================================================================
-- 07. DETECTOR DE POLICIES HISTÓRICAS CONOCIDAS
-- Busca específicamente nombres usados en los 11 SQL anteriores.
-- ============================================================================

SELECT
  '07_policies_historicas' AS seccion,
  schemaname,
  tablename,
  policyname,
  roles,
  cmd
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
ORDER BY schemaname, tablename, policyname;


-- ============================================================================
-- 08. GRANTS DIRECTOS A anon / authenticated / public
-- RLS no sustituye a los GRANT.
-- ============================================================================

SELECT
  '08_grants' AS seccion,
  table_schema,
  table_name,
  grantee,
  privilege_type
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
ORDER BY table_schema, table_name, grantee, privilege_type;


-- ============================================================================
-- 09. CONSTRAINTS
-- PK, FK, UNIQUE y CHECK.
-- ============================================================================

SELECT
  '09_constraints' AS seccion,
  tc.table_name,
  tc.constraint_name,
  tc.constraint_type,
  pg_get_constraintdef(pc.oid, true) AS definicion
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
ORDER BY tc.table_name, tc.constraint_type, tc.constraint_name;


-- ============================================================================
-- 10. ÍNDICES
-- ============================================================================

SELECT
  '10_indices' AS seccion,
  tablename AS table_name,
  indexname,
  indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename IN (
    'registros_culturales',
    'cat_docentes',
    'cat_bibliotecas',
    'profiles'
  )
ORDER BY tablename, indexname;


-- ============================================================================
-- 11. TRIGGERS
-- Excluye triggers internos de PostgreSQL.
-- ============================================================================

SELECT
  '11_triggers' AS seccion,
  event_object_schema AS schema_name,
  event_object_table AS table_name,
  trigger_name,
  event_manipulation,
  action_timing,
  action_statement
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN (
    'registros_culturales',
    'cat_docentes',
    'cat_bibliotecas',
    'profiles'
  )
ORDER BY event_object_table, trigger_name, event_manipulation;


-- ============================================================================
-- 12. FUNCIONES DE PUBLIC
-- Revisa SECURITY DEFINER y posibles helpers de permisos.
-- ============================================================================

SELECT
  '12_funciones_public' AS seccion,
  n.nspname AS schema_name,
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS argumentos,
  p.prosecdef AS security_definer,
  p.provolatile AS volatility,
  pg_get_userbyid(p.proowner) AS owner
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
ORDER BY p.proname, argumentos;


-- ============================================================================
-- 13. BUCKET EVIDENCIAS
-- Debe permitir confirmar si realmente está privado.
-- ============================================================================

SELECT
  '13_bucket_evidencias' AS seccion,
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types,
  created_at,
  updated_at
FROM storage.buckets
WHERE id = 'evidencias';


-- ============================================================================
-- 14. CONTEOS GENERALES
-- ============================================================================

SELECT
  '14_conteos' AS seccion,
  (SELECT count(*) FROM public.registros_culturales) AS registros_culturales,
  (SELECT count(*) FROM public.cat_docentes) AS docentes,
  (SELECT count(*) FROM public.cat_bibliotecas) AS bibliotecas,
  (SELECT count(*) FROM public.profiles) AS profiles,
  (SELECT count(*) FROM auth.users) AS auth_users,
  (SELECT count(*) FROM storage.objects WHERE bucket_id = 'evidencias') AS archivos_evidencias;


-- ============================================================================
-- 15. ROLES EN PROFILES
-- ============================================================================

SELECT
  '15_roles_profiles' AS seccion,
  rol,
  activo,
  count(*) AS cantidad
FROM public.profiles
GROUP BY rol, activo
ORDER BY rol, activo DESC;


-- ============================================================================
-- 16. VALIDACIÓN DE ROLES NO RECONOCIDOS
-- Idealmente debe devolver cero filas.
-- ============================================================================

SELECT
  '16_roles_invalidos' AS seccion,
  user_id,
  email,
  rol,
  activo
FROM public.profiles
WHERE rol IS NULL
   OR rol NOT IN ('ADMIN', 'SUPERVISOR', 'CAPTURISTA', 'DIRECTIVO')
ORDER BY email;


-- ============================================================================
-- 17. PROFILES SIN USUARIO AUTH
-- Idealmente cero.
-- ============================================================================

SELECT
  '17_profiles_huerfanos' AS seccion,
  p.user_id,
  p.email,
  p.rol,
  p.activo
FROM public.profiles p
LEFT JOIN auth.users u ON u.id = p.user_id
WHERE u.id IS NULL
ORDER BY p.email;


-- ============================================================================
-- 18. USUARIOS AUTH SIN PROFILE
-- Nos ayudará a diseñar el bootstrap/trigger V2.
-- ============================================================================

SELECT
  '18_auth_sin_profile' AS seccion,
  u.id AS user_id,
  u.email,
  u.created_at
FROM auth.users u
LEFT JOIN public.profiles p ON p.user_id = u.id
WHERE p.user_id IS NULL
ORDER BY u.created_at;


-- ============================================================================
-- 19. FOLIOS: RESUMEN
-- ============================================================================

SELECT
  '19_folios_resumen' AS seccion,
  count(*) AS total_registros,
  count(*) FILTER (WHERE folio IS NULL OR btrim(folio) = '') AS sin_folio,
  count(DISTINCT folio) FILTER (WHERE folio IS NOT NULL AND btrim(folio) <> '') AS folios_distintos,
  count(*) FILTER (
    WHERE folio IS NOT NULL
      AND btrim(folio) <> ''
      AND folio !~ '^SC-V[0-9]+$'
  ) AS formato_no_v1
FROM public.registros_culturales;


-- ============================================================================
-- 20. FOLIOS DUPLICADOS
-- CRÍTICO para la migración.
-- ============================================================================

SELECT
  '20_folios_duplicados' AS seccion,
  folio,
  count(*) AS repeticiones
FROM public.registros_culturales
WHERE folio IS NOT NULL
  AND btrim(folio) <> ''
GROUP BY folio
HAVING count(*) > 1
ORDER BY repeticiones DESC, folio;


-- ============================================================================
-- 21. DETALLE DE REGISTROS CON FOLIOS DUPLICADOS
-- ============================================================================

SELECT
  '21_detalle_folios_duplicados' AS seccion,
  r.folio,
  r.municipio,
  r.sede,
  r.disciplina,
  r.usuario,
  r.created_at
FROM public.registros_culturales r
JOIN (
  SELECT folio
  FROM public.registros_culturales
  WHERE folio IS NOT NULL
    AND btrim(folio) <> ''
  GROUP BY folio
  HAVING count(*) > 1
) d ON d.folio = r.folio
ORDER BY r.folio, r.created_at;


-- ============================================================================
-- 22. MUNICIPIOS: INVENTARIO ACTUAL
-- Útil para diseñar alias / normalización.
-- ============================================================================

SELECT
  '22_municipios_actuales' AS seccion,
  municipio,
  count(*) AS registros
FROM public.registros_culturales
GROUP BY municipio
ORDER BY municipio NULLS FIRST;


-- ============================================================================
-- 23. MUNICIPIOS SOSPECHOSOS
-- No borra nada: solamente identifica señales conocidas.
-- ============================================================================

SELECT
  '23_municipios_sospechosos' AS seccion,
  municipio,
  count(*) AS registros
FROM public.registros_culturales
WHERE municipio IS NULL
   OR btrim(municipio) = ''
   OR municipio ~ '^[0-9.]+$'
   OR municipio ILIKE '%nan%'
   OR municipio IN (
      'Cueramaro',
      'Stgo Mtío'
   )
GROUP BY municipio
ORDER BY municipio NULLS FIRST;


-- ============================================================================
-- 24. REGISTROS CON POSIBLE DESPLAZAMIENTO / CALIDAD
-- Señales detectadas durante la revisión del CSV histórico.
-- ============================================================================

SELECT
  '24_calidad_campos' AS seccion,
  count(*) FILTER (
    WHERE costo ILIKE 'Col.%'
       OR costo ILIKE 'Com.%'
  ) AS costo_parece_localidad,
  count(*) FILTER (
    WHERE disciplina ~ '^[0-9]+$'
  ) AS disciplina_solo_numeros,
  count(*) FILTER (
    WHERE municipio ~ '^[0-9.]+$'
       OR municipio ILIKE '%nan%'
  ) AS municipio_numerico_o_nan,
  count(*) FILTER (
    WHERE usuario IS NULL OR btrim(usuario) = ''
  ) AS sin_usuario,
  count(*) FILTER (
    WHERE created_at IS NULL
  ) AS sin_created_at
FROM public.registros_culturales;


-- ============================================================================
-- 25. TOTAL BENEFICIARIOS
-- ============================================================================

SELECT
  '25_beneficiarios_resumen' AS seccion,
  count(*) AS total_registros,
  count(*) FILTER (WHERE total_beneficiarios IS NULL) AS total_null,
  count(*) FILTER (WHERE total_beneficiarios = 0) AS total_cero,
  count(*) FILTER (WHERE total_beneficiarios = 1) AS total_uno,
  count(*) FILTER (WHERE total_beneficiarios < 0) AS total_negativo
FROM public.registros_culturales;


-- ============================================================================
-- 26. POSIBLES "1" ARTIFICIALES
-- Registros donde todas las dimensiones conocidas son 0/null
-- pero total_beneficiarios quedó en 1 por el SQL histórico.
-- ============================================================================

SELECT
  '26_beneficiarios_uno_artificial' AS seccion,
  folio,
  municipio,
  sede,
  disciplina,
  total_beneficiarios,
  created_at
FROM public.registros_culturales
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
ORDER BY created_at, folio;


-- ============================================================================
-- 27. VALORES DEMOGRÁFICOS NEGATIVOS
-- Idealmente cero.
-- ============================================================================

SELECT
  '27_demografia_negativa' AS seccion,
  folio,
  municipio,
  mujeres,
  hombres,
  ninez,
  adolescencia,
  juventudes,
  adultos_mayores,
  discapacidad,
  indigenas,
  afromexicanas,
  lgbtq,
  total_beneficiarios
FROM public.registros_culturales
WHERE COALESCE(total_beneficiarios, 0) < 0
   OR COALESCE(mujeres, 0) < 0
   OR COALESCE(hombres, 0) < 0
   OR COALESCE(ninez, 0) < 0
   OR COALESCE(adolescencia, 0) < 0
   OR COALESCE(juventudes, 0) < 0
   OR COALESCE(adultos_mayores, 0) < 0
   OR COALESCE(discapacidad, 0) < 0
   OR COALESCE(indigenas, 0) < 0
   OR COALESCE(afromexicanas, 0) < 0
   OR COALESCE(lgbtq, 0) < 0
ORDER BY folio;


-- ============================================================================
-- 28. EVIDENCIAS: FORMATO ALMACENADO EN registros_culturales
-- Detecta URLs públicas históricas frente a rutas privadas.
-- ============================================================================

SELECT
  '28_evidencias_formato' AS seccion,
  count(*) FILTER (
    WHERE foto_url IS NULL OR btrim(foto_url) = ''
  ) AS sin_evidencia,
  count(*) FILTER (
    WHERE foto_url ILIKE 'http%'
  ) AS url_completa,
  count(*) FILTER (
    WHERE foto_url ILIKE '%/storage/v1/object/public/evidencias/%'
  ) AS url_publica_historica,
  count(*) FILTER (
    WHERE foto_url IS NOT NULL
      AND btrim(foto_url) <> ''
      AND foto_url NOT ILIKE 'http%'
  ) AS ruta_storage
FROM public.registros_culturales;


-- ============================================================================
-- 29. DETALLE DE URLs PÚBLICAS HISTÓRICAS
-- ============================================================================

SELECT
  '29_urls_publicas_historicas' AS seccion,
  folio,
  municipio,
  foto_url,
  created_at
FROM public.registros_culturales
WHERE foto_url ILIKE '%/storage/v1/object/public/evidencias/%'
ORDER BY created_at, folio;


-- ============================================================================
-- 30. OBJETOS STORAGE DE EVIDENCIAS
-- No muestra contenido, únicamente metadatos.
-- ============================================================================

SELECT
  '30_storage_evidencias' AS seccion,
  name AS storage_path,
  created_at,
  updated_at,
  last_accessed_at,
  metadata
FROM storage.objects
WHERE bucket_id = 'evidencias'
ORDER BY created_at DESC
LIMIT 100;


-- ============================================================================
-- 31. CATÁLOGO DOCENTES: RESUMEN
-- ============================================================================

SELECT
  '31_docentes_resumen' AS seccion,
  count(*) AS total,
  count(*) FILTER (
    WHERE nombre_docente IS NULL OR btrim(nombre_docente) = ''
  ) AS sin_nombre,
  count(DISTINCT lower(btrim(nombre_docente))) FILTER (
    WHERE nombre_docente IS NOT NULL AND btrim(nombre_docente) <> ''
  ) AS nombres_normalizados_distintos
FROM public.cat_docentes;


-- ============================================================================
-- 32. DOCENTES POSIBLEMENTE DUPLICADOS POR NOMBRE
-- ============================================================================

SELECT
  '32_docentes_duplicados' AS seccion,
  lower(btrim(nombre_docente)) AS nombre_normalizado,
  count(*) AS repeticiones,
  string_agg(nombre_docente, ' | ' ORDER BY nombre_docente) AS variantes
FROM public.cat_docentes
WHERE nombre_docente IS NOT NULL
  AND btrim(nombre_docente) <> ''
GROUP BY lower(btrim(nombre_docente))
HAVING count(*) > 1
ORDER BY repeticiones DESC, nombre_normalizado;


-- ============================================================================
-- 33. BIBLIOTECAS: RESUMEN
-- ============================================================================

SELECT
  '33_bibliotecas_resumen' AS seccion,
  count(*) AS total,
  count(*) FILTER (
    WHERE municipio IS NULL OR btrim(municipio) = ''
  ) AS sin_municipio,
  count(*) FILTER (
    WHERE nombre_biblioteca IS NULL OR btrim(nombre_biblioteca) = ''
  ) AS sin_nombre,
  count(*) FILTER (
    WHERE responsable IS NULL OR btrim(responsable) = ''
  ) AS sin_responsable
FROM public.cat_bibliotecas;


-- ============================================================================
-- 34. BIBLIOTECAS POSIBLEMENTE DUPLICADAS
-- ============================================================================

SELECT
  '34_bibliotecas_duplicadas' AS seccion,
  lower(btrim(municipio)) AS municipio_normalizado,
  lower(btrim(nombre_biblioteca)) AS biblioteca_normalizada,
  count(*) AS repeticiones
FROM public.cat_bibliotecas
WHERE municipio IS NOT NULL
  AND btrim(municipio) <> ''
  AND nombre_biblioteca IS NOT NULL
  AND btrim(nombre_biblioteca) <> ''
GROUP BY
  lower(btrim(municipio)),
  lower(btrim(nombre_biblioteca))
HAVING count(*) > 1
ORDER BY repeticiones DESC, municipio_normalizado, biblioteca_normalizada;


-- ============================================================================
-- 35. FECHAS / ORIGEN TEMPORAL
-- Ayuda a distinguir captura histórica vs actividad.
-- ============================================================================

SELECT
  '35_fechas' AS seccion,
  min(created_at) AS primer_created_at,
  max(created_at) AS ultimo_created_at,
  min(fecha_actividad) AS primera_fecha_actividad,
  max(fecha_actividad) AS ultima_fecha_actividad,
  count(*) FILTER (
    WHERE fecha_actividad IS NULL
  ) AS sin_fecha_actividad
FROM public.registros_culturales;


-- ============================================================================
-- 36. TIPOS DE ACTIVIDAD ACTUALES
-- ============================================================================

SELECT
  '36_tipos_actividad' AS seccion,
  tipo_actividad,
  count(*) AS registros
FROM public.registros_culturales
GROUP BY tipo_actividad
ORDER BY registros DESC, tipo_actividad NULLS FIRST;


-- ============================================================================
-- 37. ÁREAS / PROGRAMAS ACTUALES
-- ============================================================================

SELECT
  '37_areas_programa' AS seccion,
  area_programa,
  count(*) AS registros
FROM public.registros_culturales
GROUP BY area_programa
ORDER BY registros DESC, area_programa NULLS FIRST;


-- ============================================================================
-- 38. CIERRE
-- Si todo llegó hasta aquí, la transacción solo realizó lecturas.
-- ============================================================================

SELECT
  '38_fin' AS seccion,
  'PRE-FLIGHT COMPLETADO: ninguna modificación permanente fue ejecutada.' AS resultado,
  now() AS fecha_fin;

COMMIT;

-- ============================================================================
-- FIN DE 00_preflight.sql
-- ============================================================================
