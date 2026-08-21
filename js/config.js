/**
 * VINCULACIÓN CULTURAL 2.0
 * config.js
 *
 * Configuración pública del frontend.
 *
 * IMPORTANTE:
 * - La publishable key de Supabase está diseñada para existir en el cliente.
 * - NUNCA colocar aquí service_role, secretos privados ni contraseñas.
 * - El acceso real lo gobiernan RLS + Auth + profiles del schema v2.
 */

export const APP_CONFIG = Object.freeze({
  app: Object.freeze({
    name: "Sistematización de Vinculación Cultural",
    shortName: "Vinculación Cultural",
    version: "2.1.0",
    environment: "production",
  }),

  supabase: Object.freeze({
    url: "https://azhlshuiazhgjpjckkce.supabase.co",
    publishableKey: "sb_publishable_wSABUjH15RrjBQ577R2bSA_jX6I4mAM",

    // Toda operación de datos del nuevo frontend parte de v2.
    schema: "v2",

    // Bucket privado creado en 07_storage.sql.
    evidenceBucket: "evidencias-v2",
  }),

  auth: Object.freeze({
    // Supabase Auth funciona fuera del schema PostgREST.
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,

    // Los usuarios nuevos se sincronizan a v2.profiles como CAPTURISTA.
    // Sin alcance asignado, RLS mantiene deny-by-default.
    shouldCreateUserFromMagicLink: true,
  }),

  pagination: Object.freeze({
    defaultPageSize: 25,
    maxPageSize: 100,
  }),

  featureFlags: Object.freeze({
    offline: false,
    imports: false,
    adminV2: false,
  }),

  debug: false,
});

export function assertAppConfig() {
  const { url, publishableKey, schema } = APP_CONFIG.supabase;

  if (!url || !/^https:\/\/.+\.supabase\.co$/i.test(url)) {
    throw new Error("CONFIG_SUPABASE_URL_INVALID");
  }

  if (!publishableKey || !publishableKey.startsWith("sb_publishable_")) {
    throw new Error("CONFIG_SUPABASE_PUBLISHABLE_KEY_INVALID");
  }

  if (schema !== "v2") {
    throw new Error("CONFIG_SCHEMA_MUST_BE_V2");
  }

  return true;
}
