-- ============================================================================
-- ETAPA 7.7.4 - TEMAS CULTURALES PROGRAMABLES
-- Identidad estacional para Inteligencia Cultural. Sin afectar datos ni KPIs.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS v2.temas_inteligencia (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre TEXT NOT NULL CHECK (char_length(btrim(nombre)) BETWEEN 3 AND 120),
  activo BOOLEAN NOT NULL DEFAULT true,
  fecha_inicio DATE NULL,
  fecha_fin DATE NULL,
  prioridad INTEGER NOT NULL DEFAULT 0 CHECK (prioridad BETWEEN 0 AND 100),
  contenido JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT temas_inteligencia_fechas_validas CHECK (
    fecha_inicio IS NULL OR fecha_fin IS NULL OR fecha_inicio <= fecha_fin
  )
);

CREATE TABLE IF NOT EXISTS v2.auditoria_temas_inteligencia (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tema_id UUID NULL,
  operacion TEXT NOT NULL CHECK (operacion IN ('INSERT', 'UPDATE')),
  nombre TEXT NOT NULL,
  activo BOOLEAN NOT NULL,
  fecha_inicio DATE NULL,
  fecha_fin DATE NULL,
  prioridad INTEGER NOT NULL,
  contenido JSONB NOT NULL,
  actualizado_por UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE v2.temas_inteligencia ENABLE ROW LEVEL SECURITY;
ALTER TABLE v2.auditoria_temas_inteligencia ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON v2.temas_inteligencia TO authenticated;
GRANT SELECT ON v2.auditoria_temas_inteligencia TO authenticated;

DROP POLICY IF EXISTS temas_inteligencia_read_authenticated ON v2.temas_inteligencia;
CREATE POLICY temas_inteligencia_read_authenticated ON v2.temas_inteligencia
  FOR SELECT TO authenticated USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS temas_inteligencia_insert_superadmin ON v2.temas_inteligencia;
CREATE POLICY temas_inteligencia_insert_superadmin ON v2.temas_inteligencia
  FOR INSERT TO authenticated WITH CHECK (v2_private.is_superadmin());

DROP POLICY IF EXISTS temas_inteligencia_update_superadmin ON v2.temas_inteligencia;
CREATE POLICY temas_inteligencia_update_superadmin ON v2.temas_inteligencia
  FOR UPDATE TO authenticated
  USING (v2_private.is_superadmin())
  WITH CHECK (v2_private.is_superadmin());

DROP POLICY IF EXISTS auditoria_temas_inteligencia_read_superadmin ON v2.auditoria_temas_inteligencia;
CREATE POLICY auditoria_temas_inteligencia_read_superadmin ON v2.auditoria_temas_inteligencia
  FOR SELECT TO authenticated USING (v2_private.is_superadmin());

CREATE OR REPLACE FUNCTION v2_private.touch_temas_inteligencia()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
BEGIN
  NEW.updated_at := now();
  NEW.updated_by := auth.uid();
  IF TG_OP = 'INSERT' AND NEW.created_by IS NULL THEN NEW.created_by := auth.uid(); END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION v2_private.audit_temas_inteligencia()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
BEGIN
  INSERT INTO v2.auditoria_temas_inteligencia(
    tema_id, operacion, nombre, activo, fecha_inicio, fecha_fin, prioridad, contenido, actualizado_por
  ) VALUES (
    NEW.id, TG_OP, NEW.nombre, NEW.activo, NEW.fecha_inicio, NEW.fecha_fin, NEW.prioridad, NEW.contenido, auth.uid()
  );
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_temas_inteligencia_touch ON v2.temas_inteligencia;
CREATE TRIGGER trg_temas_inteligencia_touch
  BEFORE INSERT OR UPDATE ON v2.temas_inteligencia
  FOR EACH ROW EXECUTE FUNCTION v2_private.touch_temas_inteligencia();

DROP TRIGGER IF EXISTS trg_temas_inteligencia_audit ON v2.temas_inteligencia;
CREATE TRIGGER trg_temas_inteligencia_audit
  AFTER INSERT OR UPDATE ON v2.temas_inteligencia
  FOR EACH ROW EXECUTE FUNCTION v2_private.audit_temas_inteligencia();

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('temas-inteligencia', 'temas-inteligencia', true, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = true, file_size_limit = 5242880,
  allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp'];

DROP POLICY IF EXISTS temas_inteligencia_public_read ON storage.objects;
CREATE POLICY temas_inteligencia_public_read ON storage.objects
  FOR SELECT USING (bucket_id = 'temas-inteligencia');

DROP POLICY IF EXISTS temas_inteligencia_write_superadmin ON storage.objects;
CREATE POLICY temas_inteligencia_write_superadmin ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (bucket_id = 'temas-inteligencia' AND v2_private.is_superadmin());

DROP POLICY IF EXISTS temas_inteligencia_update_superadmin ON storage.objects;
CREATE POLICY temas_inteligencia_update_superadmin ON storage.objects
  FOR UPDATE TO authenticated USING (bucket_id = 'temas-inteligencia' AND v2_private.is_superadmin())
  WITH CHECK (bucket_id = 'temas-inteligencia' AND v2_private.is_superadmin());

DROP POLICY IF EXISTS temas_inteligencia_delete_superadmin ON storage.objects;
CREATE POLICY temas_inteligencia_delete_superadmin ON storage.objects
  FOR DELETE TO authenticated USING (bucket_id = 'temas-inteligencia' AND v2_private.is_superadmin());

INSERT INTO v2.schema_migrations(version, descripcion)
VALUES ('2.1.12ae', '12ae_temas_inteligencia.sql - Temas culturales programables para Inteligencia Cultural.')
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  to_regclass('v2.temas_inteligencia') IS NOT NULL AS tabla_temas_existe,
  to_regclass('v2.auditoria_temas_inteligencia') IS NOT NULL AS auditoria_existe,
  (SELECT public FROM storage.buckets WHERE id = 'temas-inteligencia') AS bucket_publico,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12ae') AS migracion;
-- Esperado: true | true | true | 1
