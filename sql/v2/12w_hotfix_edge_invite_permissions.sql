-- HOTFIX 7.4 - Permisos mínimos para la Edge Function invite-user
-- Ejecutar una sola vez en Supabase SQL Editor.
BEGIN;

GRANT USAGE ON SCHEMA v2 TO service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE v2.profiles TO service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE v2.profile_unidades TO service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE v2.profile_municipios TO service_role;
GRANT INSERT ON TABLE v2.invitaciones_usuarios TO service_role;

INSERT INTO v2.schema_migrations(version, descripcion)
VALUES (
  '2.1.12w1',
  '12w_hotfix_edge_invite_permissions.sql - Permisos mínimos service_role para Edge Function de invitaciones.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- Resultado esperado: true | true | true | 1
SELECT
  has_schema_privilege('service_role', 'v2', 'USAGE') AS schema_v2,
  has_table_privilege('service_role', 'v2.profiles', 'SELECT,INSERT,UPDATE') AS profiles,
  has_table_privilege('service_role', 'v2.invitaciones_usuarios', 'INSERT') AS invitations,
  (SELECT count(*) FROM v2.schema_migrations WHERE version='2.1.12w1') AS migracion;
