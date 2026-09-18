-- ETAPA 7.4 - SUPERADMIN E INVITACIONES SEGURAS
BEGIN;

DO $$ DECLARE c RECORD; BEGIN
  FOR c IN SELECT conname FROM pg_constraint
    WHERE conrelid='v2.profiles'::regclass AND contype='c'
      AND pg_get_constraintdef(oid) ILIKE '%rol%'
  LOOP EXECUTE format('ALTER TABLE v2.profiles DROP CONSTRAINT %I',c.conname); END LOOP;
END $$;

ALTER TABLE v2.profiles ADD CONSTRAINT ck_v2_profiles_rol
CHECK (rol IN ('SUPERADMIN','ADMIN','SUPERVISOR','DIRECTIVO','CAPTURISTA'));

CREATE OR REPLACE FUNCTION v2_private.is_superadmin() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $$ SELECT COALESCE(v2_private.current_role()='SUPERADMIN',false) $$;

CREATE OR REPLACE FUNCTION v2_private.is_admin() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $$ SELECT COALESCE(v2_private.current_role() IN ('SUPERADMIN','ADMIN'),false) $$;

UPDATE v2.profiles SET rol='SUPERADMIN',activo=true,updated_at=now()
WHERE lower(email)='la.duranalvarez@ugto.mx';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM v2.profiles WHERE lower(email)='la.duranalvarez@ugto.mx' AND rol='SUPERADMIN') THEN
    RAISE EXCEPTION 'SUPERADMIN_NOT_FOUND: la cuenta la.duranalvarez@ugto.mx debe existir primero en Auth/V2.';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS v2.invitaciones_usuarios (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(), email TEXT NOT NULL,
  rol TEXT NOT NULL, invitado_por UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  estado TEXT NOT NULL DEFAULT 'ENVIADA', metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE v2.invitaciones_usuarios ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE v2.invitaciones_usuarios FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION v2_private.protect_superadmin() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE caller TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  caller:=v2_private.current_role();
  IF OLD.rol='SUPERADMIN' AND (NEW.rol IS DISTINCT FROM OLD.rol OR NEW.activo IS DISTINCT FROM OLD.activo) THEN
    RAISE EXCEPTION 'SUPERADMIN_PROTECTED: la cuenta principal no puede modificarse desde el panel.';
  END IF;
  IF caller<>'SUPERADMIN' AND (OLD.rol='ADMIN' OR NEW.rol IN ('ADMIN','SUPERADMIN')) THEN
    RAISE EXCEPTION 'SUPERADMIN_REQUIRED: solo SUPERADMIN puede gestionar administradores.';
  END IF;
  IF OLD.rol<>'SUPERADMIN' AND NEW.rol='SUPERADMIN' THEN
    RAISE EXCEPTION 'SUPERADMIN_UNIQUE: no se puede asignar este rol desde el panel.';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_v2_profiles_protect_superadmin ON v2.profiles;
CREATE TRIGGER trg_v2_profiles_protect_superadmin BEFORE UPDATE ON v2.profiles
FOR EACH ROW EXECUTE FUNCTION v2_private.protect_superadmin();

REVOKE ALL ON FUNCTION v2_private.is_superadmin() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION v2_private.is_superadmin() TO authenticated;

INSERT INTO v2.schema_migrations(version,descripcion) VALUES
('2.1.12w','12w_superadmin_invitations.sql - SUPERADMIN principal e invitaciones seguras mediante Edge Function.')
ON CONFLICT(version) DO NOTHING;
COMMIT;

-- Esperado: SUPERADMIN | true | 1
SELECT rol,
  to_regprocedure('v2_private.is_superadmin()') IS NOT NULL AS helper,
  (SELECT count(*) FROM v2.schema_migrations WHERE version='2.1.12w') AS migracion
FROM v2.profiles WHERE lower(email)='la.duranalvarez@ugto.mx';
