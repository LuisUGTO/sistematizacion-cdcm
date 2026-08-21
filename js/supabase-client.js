/**
 * VINCULACIÓN CULTURAL 2.0
 * supabase-client.js
 *
 * Cliente único de Supabase para todo el frontend V2.
 *
 * IMPORTANTE:
 * - No agregar headers HTTP personalizados globales aquí.
 * - La seguridad real depende de Auth + RLS.
 */

import { APP_CONFIG, assertAppConfig } from "./config.js";

assertAppConfig();

if (!window.supabase?.createClient) {
  throw new Error(
    "SUPABASE_JS_NOT_LOADED: cargue @supabase/supabase-js@2 antes de los módulos V2."
  );
}

const {
  url,
  publishableKey,
  schema,
  evidenceBucket,
} = APP_CONFIG.supabase;


/**
 * Cliente principal Supabase.
 *
 * Las consultas de base de datos trabajan por defecto
 * contra el schema v2.
 */
export const supabase = window.supabase.createClient(
  url,
  publishableKey,
  {
    db: {
      schema,
    },

    auth: {
      persistSession: APP_CONFIG.auth.persistSession,
      autoRefreshToken: APP_CONFIG.auth.autoRefreshToken,
      detectSessionInUrl: APP_CONFIG.auth.detectSessionInUrl,
      storageKey: "vinculacion-cultural-v2-auth",
    },
  }
);


/**
 * Acceso explícito al schema V2.
 */
export function dbV2() {
  return supabase.schema(schema);
}


/**
 * Bucket privado de evidencias V2.
 */
export function evidenceStorage() {
  return supabase.storage.from(evidenceBucket);
}


/**
 * Health check mínimo del Data API.
 */
export async function checkDataApi() {
  const startedAt = performance.now();

  const { data, error } = await dbV2()
    .from("cat_unidades_operativas")
    .select("id,clave,nombre")
    .eq("activo", true)
    .limit(1);

  return {
    ok: !error,
    elapsedMs: Math.round(
      performance.now() - startedAt
    ),
    data: data ?? [],
    error: error ?? null,
  };
}