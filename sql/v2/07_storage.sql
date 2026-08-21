-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 07_storage.sql
-- Storage privado y aislado para evidencias V2
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   02_catalogs.sql
--   03_operation_modules.sql
--   04_indicators.sql
--   05_functions_triggers.sql
--   06_rls.sql
--
-- DECISIÓN DE SEGURIDAD:
--   V1 conserva el bucket "evidencias" y sus policies actuales durante la
--   transición. V2 utiliza un bucket independiente:
--
--       evidencias-v2
--
--   Esto evita romper V1 y evita que las policies históricas permisivas del
--   bucket V1 alcancen a los archivos nuevos de V2.
--
-- RUTA CANÓNICA V2:
--
--   {unidad_operativa_uuid}/{registro_uuid}/{archivo_uuid.ext}
--
-- Ejemplo:
--
--   11111111-1111-1111-1111-111111111111/
--   aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/
--   bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jpg
--
-- SEGURIDAD:
--   ✓ bucket privado
--   ✓ anon sin acceso
--   ✓ SELECT solo si puede leer el registro
--   ✓ INSERT solo si puede editar el registro
--   ✓ DELETE físico solo ADMIN/SUPERVISOR con alcance
--   ✓ path validado contra unidad_operativa_id del registro
--   ✓ Signed URLs dependerán de SELECT RLS
--
-- NO HACE:
--   ✗ no modifica el bucket V1 "evidencias"
--   ✗ no borra policies históricas V1
--   ✗ no mueve los 5 objetos históricos
--   ✗ no hace públicos los archivos
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.registro_evidencias') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan tablas operativas V2.';
  END IF;

  IF to_regprocedure('v2_private.can_read_record(uuid)') IS NULL
     OR to_regprocedure('v2_private.can_edit_record(uuid)') IS NULL
     OR to_regprocedure('v2_private.can_manage_record(uuid)') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: 06_rls.sql no está instalado.';
  END IF;
END
$$;


-- ============================================================================
-- 01. BUCKET V2 PRIVADO
--
-- No imponemos todavía límite de tamaño ni MIME types desde BD.
-- La validación de tipos/tamaño se añadirá al frontend y puede endurecerse
-- posteriormente sin afectar los objetos ya almacenados.
-- ============================================================================

INSERT INTO storage.buckets (
  id,
  name,
  public
)
VALUES (
  'evidencias-v2',
  'evidencias-v2',
  false
)
ON CONFLICT (id)
DO UPDATE SET
  name = EXCLUDED.name,
  public = false;


-- ============================================================================
-- 02. METADATOS DE EVIDENCIA V2
-- Se registra explícitamente el bucket.
-- ============================================================================

ALTER TABLE v2.registro_evidencias
  ADD COLUMN IF NOT EXISTS bucket_id TEXT
  NOT NULL
  DEFAULT 'evidencias-v2';

ALTER TABLE v2.registro_evidencias
  DROP CONSTRAINT IF EXISTS ck_v2_evidencia_bucket;

ALTER TABLE v2.registro_evidencias
  ADD CONSTRAINT ck_v2_evidencia_bucket
  CHECK (bucket_id = 'evidencias-v2');


-- No almacenar URLs públicas ni Signed URLs temporales.
ALTER TABLE v2.registro_evidencias
  DROP CONSTRAINT IF EXISTS ck_v2_evidencia_storage_path_relativo;

ALTER TABLE v2.registro_evidencias
  ADD CONSTRAINT ck_v2_evidencia_storage_path_relativo
  CHECK (
    storage_path !~* '^https?://'
    AND storage_path !~ '[?]'
    AND pg_catalog.btrim(storage_path) <> ''
  );


-- ============================================================================
-- 03. PARSER SEGURO DE PATH
--
-- Devuelve NULL si la ruta no cumple:
--   unidad_uuid/registro_uuid/archivo
-- ============================================================================

CREATE OR REPLACE FUNCTION v2_private.storage_v2_record_id(
  p_name TEXT
)
RETURNS UUID
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_parts TEXT[];
BEGIN
  IF p_name IS NULL OR pg_catalog.btrim(p_name) = '' THEN
    RETURN NULL;
  END IF;

  v_parts := pg_catalog.string_to_array(p_name, '/');

  IF pg_catalog.array_length(v_parts, 1) <> 3 THEN
    RETURN NULL;
  END IF;

  IF v_parts[1] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR v_parts[2] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR pg_catalog.btrim(v_parts[3]) = '' THEN
    RETURN NULL;
  END IF;

  RETURN v_parts[2]::UUID;

EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$;


CREATE OR REPLACE FUNCTION v2_private.storage_v2_unit_id(
  p_name TEXT
)
RETURNS UUID
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_parts TEXT[];
BEGIN
  IF p_name IS NULL OR pg_catalog.btrim(p_name) = '' THEN
    RETURN NULL;
  END IF;

  v_parts := pg_catalog.string_to_array(p_name, '/');

  IF pg_catalog.array_length(v_parts, 1) <> 3 THEN
    RETURN NULL;
  END IF;

  IF v_parts[1] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN NULL;
  END IF;

  RETURN v_parts[1]::UUID;

EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$;


-- ============================================================================
-- 04. VALIDAR QUE PATH Y REGISTRO COINCIDAN
-- SECURITY DEFINER para consultar la relación interna sin depender de RLS
-- recursivo sobre storage.objects.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2_private.storage_v2_path_valid(
  p_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_registro UUID;
  v_unidad   UUID;
BEGIN
  v_registro := v2_private.storage_v2_record_id(p_name);
  v_unidad   := v2_private.storage_v2_unit_id(p_name);

  IF v_registro IS NULL OR v_unidad IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM v2.registros r
    WHERE r.id = v_registro
      AND r.unidad_operativa_id = v_unidad
      AND r.deleted_at IS NULL
  );
END;
$$;


-- ============================================================================
-- 05. HELPERS DE AUTORIZACIÓN STORAGE
-- ============================================================================

CREATE OR REPLACE FUNCTION v2_private.storage_v2_can_read(
  p_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_registro UUID;
BEGIN
  IF NOT v2_private.storage_v2_path_valid(p_name) THEN
    RETURN false;
  END IF;

  v_registro := v2_private.storage_v2_record_id(p_name);

  RETURN v2_private.can_read_record(v_registro);
END;
$$;


CREATE OR REPLACE FUNCTION v2_private.storage_v2_can_write(
  p_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_registro UUID;
BEGIN
  IF NOT v2_private.storage_v2_path_valid(p_name) THEN
    RETURN false;
  END IF;

  v_registro := v2_private.storage_v2_record_id(p_name);

  RETURN v2_private.can_edit_record(v_registro);
END;
$$;


CREATE OR REPLACE FUNCTION v2_private.storage_v2_can_delete(
  p_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_registro UUID;
BEGIN
  IF NOT v2_private.storage_v2_path_valid(p_name) THEN
    RETURN false;
  END IF;

  v_registro := v2_private.storage_v2_record_id(p_name);

  RETURN v2_private.can_manage_record(v_registro);
END;
$$;


-- ============================================================================
-- 06. PERMISOS DE FUNCIONES
-- ============================================================================

REVOKE ALL ON FUNCTION v2_private.storage_v2_record_id(TEXT)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2_private.storage_v2_unit_id(TEXT)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2_private.storage_v2_path_valid(TEXT)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2_private.storage_v2_can_read(TEXT)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2_private.storage_v2_can_write(TEXT)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2_private.storage_v2_can_delete(TEXT)
FROM PUBLIC, anon, authenticated;


GRANT EXECUTE ON FUNCTION v2_private.storage_v2_record_id(TEXT)
TO authenticated;

GRANT EXECUTE ON FUNCTION v2_private.storage_v2_unit_id(TEXT)
TO authenticated;

GRANT EXECUTE ON FUNCTION v2_private.storage_v2_path_valid(TEXT)
TO authenticated;

GRANT EXECUTE ON FUNCTION v2_private.storage_v2_can_read(TEXT)
TO authenticated;

GRANT EXECUTE ON FUNCTION v2_private.storage_v2_can_write(TEXT)
TO authenticated;

GRANT EXECUTE ON FUNCTION v2_private.storage_v2_can_delete(TEXT)
TO authenticated;


-- ============================================================================
-- 07. POLICIES STORAGE V2
--
-- Se eliminan SOLAMENTE policies con nombres V2.
-- No se toca ninguna policy histórica del bucket "evidencias".
-- ============================================================================

DROP POLICY IF EXISTS "v2_evidencias_select"
ON storage.objects;

DROP POLICY IF EXISTS "v2_evidencias_insert"
ON storage.objects;

DROP POLICY IF EXISTS "v2_evidencias_delete"
ON storage.objects;


-- Lectura / Signed URL.
CREATE POLICY "v2_evidencias_select"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'evidencias-v2'
  AND v2_private.storage_v2_can_read(name)
);


-- Subida.
CREATE POLICY "v2_evidencias_insert"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'evidencias-v2'
  AND auth.uid() IS NOT NULL
  AND v2_private.storage_v2_can_write(name)
);


-- Borrado físico deliberadamente restringido a gestión:
-- ADMIN global o SUPERVISOR dentro de alcance.
-- CAPTURISTA usará baja lógica del metadata; no borra el objeto directamente.
CREATE POLICY "v2_evidencias_delete"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'evidencias-v2'
  AND v2_private.storage_v2_can_delete(name)
);


-- No se crea UPDATE policy.
-- Los archivos son inmutables: reemplazar evidencia = nuevo objeto + metadata.


-- ============================================================================
-- 08. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.07',
  '07_storage.sql - Bucket privado evidencias-v2 y RLS aislado de Storage V1.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 09. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

SELECT
  'V2.1 - 07_storage' AS instalacion,

  EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'evidencias-v2'
  ) AS bucket_v2_existe,

  COALESCE((
    SELECT public
    FROM storage.buckets
    WHERE id = 'evidencias-v2'
  ), true) AS bucket_v2_public,

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
  ) AS policies_storage_v2,

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
        'anon' = ANY (roles)
        OR 'public' = ANY (roles)
      )
  ) AS policies_storage_v2_anon_public,

  EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'evidencias'
  ) AS bucket_v1_sigue_existiendo,

  (
    SELECT count(*)
    FROM storage.objects
    WHERE bucket_id = 'evidencias'
  ) AS objetos_v1_preservados,

  (
    SELECT count(*)
    FROM storage.objects
    WHERE bucket_id = 'evidencias-v2'
  ) AS objetos_v2_actuales,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.07'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO EN ESTE MOMENTO:
--
-- bucket_v2_existe                    = true
-- bucket_v2_public                    = false
-- policies_storage_v2                 = 3
-- policies_storage_v2_anon_public     = 0
-- bucket_v1_sigue_existiendo          = true
-- objetos_v1_preservados              = 5   (según preflight; puede variar)
-- objetos_v2_actuales                 = 0
-- migracion_registrada                = 1
--
-- IMPORTANTE:
-- El bucket V1 "evidencias" y sus policies históricas NO se han modificado.
--
-- Próximo archivo:
--   08_views_rpc.sql
--
-- Allí construiremos:
--   - vistas operativas
--   - calidad de datos
--   - resumen territorial
--   - pendientes de validación
--   - avance de indicadores
--   - RPCs controlados para dashboard
-- ============================================================================
