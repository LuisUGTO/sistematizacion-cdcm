/**
 * VINCULACIÓN CULTURAL 2.0
 * supabase-client.js
 *
 * Cliente único de Supabase para todo el frontend V2.
 *
 * Requiere que index.html/admin.html carguen antes:
 *   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
 */

import { APP_CONFIG, assertAppConfig } from "./config.js";

assertAppConfig();

if (!window.supabase?.createClient) {
  throw new Error(
    "SUPABASE_JS_NOT_LOADED: cargue @supabase/supabase-js@2 antes de los módulos V2."
  );
}

const { url, publishableKey, schema, evidenceBucket } = APP_CONFIG.supabase;

export const supabase = window.supabase.createClient(
  url,
  publishableKey,
  {
    db: {
      // Previene que el frontend V2 opere accidentalmente contra public/V1.
      schema,
    },
    auth: {
      persistSession: APP_CONFIG.auth.persistSession,
      autoRefreshToken: APP_CONFIG.auth.autoRefreshToken,
      detectSessionInUrl: APP_CONFIG.auth.detectSessionInUrl,
      storageKey: "vinculacion-cultural-v2-auth",
    },
    global: {
      headers: {
        "x-application-name": `${APP_CONFIG.app.shortName}/${APP_CONFIG.app.version}`,
      },
    },
  }
);

/**
 * Devuelve el mismo cliente con el schema v2 explicitado.
 * Es útil para hacer evidente la intención en módulos sensibles.
 */
export function dbV2() {
  return supabase.schema(schema);
}

/**
 * Referencia al bucket privado de evidencias.
 * No genera Signed URLs por sí misma.
 */
export function evidenceStorage() {
  return supabase.storage.from(evidenceBucket);
}

/**
 * Health check mínimo del Data API.
 * La consulta sigue protegida por RLS; una sesión sin acceso puede obtener error.
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
    elapsedMs: Math.round(performance.now() - startedAt),
    data: data ?? [],
    error: error ?? null,
  };
}
