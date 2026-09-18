-- ETAPA 7.5 - CONTENIDO INSTITUCIONAL DEL INICIO
-- Ejecutar una sola vez en Supabase SQL Editor.
BEGIN;

CREATE TABLE IF NOT EXISTS v2.configuracion_inicio (
  id BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),
  contenido JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS v2.auditoria_contenido_inicio (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contenido JSONB NOT NULL,
  actualizado_por UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE v2.configuracion_inicio ENABLE ROW LEVEL SECURITY;
ALTER TABLE v2.auditoria_contenido_inicio ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON v2.configuracion_inicio TO authenticated;
GRANT SELECT ON v2.auditoria_contenido_inicio TO authenticated;

DROP POLICY IF EXISTS configuracion_inicio_read_authenticated ON v2.configuracion_inicio;
CREATE POLICY configuracion_inicio_read_authenticated ON v2.configuracion_inicio
  FOR SELECT TO authenticated USING (auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS configuracion_inicio_write_superadmin ON v2.configuracion_inicio;
CREATE POLICY configuracion_inicio_write_superadmin ON v2.configuracion_inicio
  FOR INSERT TO authenticated WITH CHECK (v2_private.is_superadmin());
DROP POLICY IF EXISTS configuracion_inicio_update_superadmin ON v2.configuracion_inicio;
CREATE POLICY configuracion_inicio_update_superadmin ON v2.configuracion_inicio
  FOR UPDATE TO authenticated USING (v2_private.is_superadmin()) WITH CHECK (v2_private.is_superadmin());

DROP POLICY IF EXISTS auditoria_contenido_inicio_read_superadmin ON v2.auditoria_contenido_inicio;
CREATE POLICY auditoria_contenido_inicio_read_superadmin ON v2.auditoria_contenido_inicio
  FOR SELECT TO authenticated USING (v2_private.is_superadmin());

CREATE OR REPLACE FUNCTION v2_private.touch_configuracion_inicio()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  NEW.updated_at := now();
  NEW.updated_by := auth.uid();
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION v2_private.audit_configuracion_inicio()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  INSERT INTO v2.auditoria_contenido_inicio(contenido, actualizado_por)
  VALUES (NEW.contenido, auth.uid());
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_configuracion_inicio_touch ON v2.configuracion_inicio;
CREATE TRIGGER trg_configuracion_inicio_touch
  BEFORE INSERT OR UPDATE ON v2.configuracion_inicio
  FOR EACH ROW EXECUTE FUNCTION v2_private.touch_configuracion_inicio();
DROP TRIGGER IF EXISTS trg_configuracion_inicio_audit ON v2.configuracion_inicio;
CREATE TRIGGER trg_configuracion_inicio_audit
  AFTER INSERT OR UPDATE ON v2.configuracion_inicio
  FOR EACH ROW EXECUTE FUNCTION v2_private.audit_configuracion_inicio();

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('contenido-inicio', 'contenido-inicio', true, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = true, file_size_limit = 5242880,
  allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp'];

DROP POLICY IF EXISTS contenido_inicio_public_read ON storage.objects;
CREATE POLICY contenido_inicio_public_read ON storage.objects
  FOR SELECT USING (bucket_id = 'contenido-inicio');
DROP POLICY IF EXISTS contenido_inicio_write_superadmin ON storage.objects;
CREATE POLICY contenido_inicio_write_superadmin ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (bucket_id = 'contenido-inicio' AND v2_private.is_superadmin());
DROP POLICY IF EXISTS contenido_inicio_update_superadmin ON storage.objects;
CREATE POLICY contenido_inicio_update_superadmin ON storage.objects
  FOR UPDATE TO authenticated USING (bucket_id = 'contenido-inicio' AND v2_private.is_superadmin())
  WITH CHECK (bucket_id = 'contenido-inicio' AND v2_private.is_superadmin());
DROP POLICY IF EXISTS contenido_inicio_delete_superadmin ON storage.objects;
CREATE POLICY contenido_inicio_delete_superadmin ON storage.objects
  FOR DELETE TO authenticated USING (bucket_id = 'contenido-inicio' AND v2_private.is_superadmin());

INSERT INTO v2.schema_migrations(version, descripcion)
VALUES ('2.1.12x', '12x_home_content.sql - Contenido del Inicio editable por SUPERADMIN con imágenes en Storage.')
ON CONFLICT (version) DO NOTHING;
COMMIT;

SELECT id, updated_at, updated_by FROM v2.configuracion_inicio;
SELECT id, name, public, file_size_limit FROM storage.buckets WHERE id = 'contenido-inicio';
