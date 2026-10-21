-- Entorno sintético aislado, no reproduce Auth/Storage HTTP de Supabase.
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE SCHEMA auth;
CREATE SCHEMA v2;
CREATE SCHEMA v2_private;
CREATE SCHEMA storage;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
GRANT USAGE ON SCHEMA v2,v2_private,auth TO authenticated;
CREATE TABLE v2.schema_migrations(version text PRIMARY KEY,descripcion text);
CREATE TABLE v2.profiles(user_id uuid PRIMARY KEY,email text,nombre text,rol text,activo boolean,updated_at timestamptz);
CREATE TABLE v2.profile_unidades(user_id uuid,unidad_operativa_id uuid,activo boolean);
CREATE TABLE v2.profile_municipios(user_id uuid,municipio_id uuid,activo boolean);
CREATE TABLE v2.registros(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),folio text DEFAULT 'PRUEBA',
  estatus text DEFAULT 'BORRADOR',row_version integer DEFAULT 1,
  unidad_operativa_id uuid,municipio_id uuid,created_by uuid,updated_by uuid,
  deleted_at timestamptz,origen text DEFAULT 'MANUAL',metadata jsonb DEFAULT '{}',
  import_job_id uuid,archivo_origen text,fila_origen integer,updated_at timestamptz
);
CREATE TABLE v2.vw_calidad_datos(id uuid,incidencias text[]);
CREATE TABLE v2.import_jobs(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),archivo_nombre text,tipo_importacion text,
  usuario_id uuid,estatus text,metadata jsonb,total_filas integer DEFAULT 0,
  filas_validas integer DEFAULT 0,filas_error integer DEFAULT 0,
  filas_duplicadas integer DEFAULT 0,filas_importadas integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),updated_at timestamptz,completed_at timestamptz
);
CREATE TABLE v2.import_staging(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,import_job_id uuid,
  numero_fila integer,raw_data jsonb,normalized_data jsonb,estatus text,errores jsonb,
  updated_at timestamptz,
  CONSTRAINT uq_v2_import_staging_job_fila UNIQUE(import_job_id,numero_fila)
);
CREATE TABLE storage.buckets(id text PRIMARY KEY,public boolean,file_size_limit bigint,allowed_mime_types text[]);
INSERT INTO storage.buckets VALUES ('evidencias-v2',false,NULL,NULL);
INSERT INTO storage.buckets VALUES ('contenido-inicio',true,5242880,ARRAY['image/jpeg','image/png','image/webp']);

-- Sustituto del núcleo de captura: las pruebas de lote verifican autorización,
-- aislamiento por propietario, duplicados y estados, no la captura institucional.
CREATE FUNCTION v2.rpc_create_borrador(p jsonb)
RETURNS TABLE(id uuid,folio text) LANGUAGE plpgsql AS $$
DECLARE v_id uuid:=gen_random_uuid();
BEGIN
  INSERT INTO v2.registros(id,created_by) VALUES(v_id,auth.uid());
  RETURN QUERY SELECT v_id,'PRUEBA'::text;
END $$;
