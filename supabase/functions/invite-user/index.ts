import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, "Content-Type": "application/json" },
});

async function within<T>(step: string, action: Promise<T>, milliseconds = 20000): Promise<T> {
  let timeoutId: number | undefined;
  try {
    return await Promise.race([
      action,
      new Promise<T>((_, reject) => {
        timeoutId = setTimeout(() => reject(new Error(`TIMEOUT_${step}: la operación tardó demasiado.`)), milliseconds);
      }),
    ]);
  } finally {
    if (timeoutId !== undefined) clearTimeout(timeoutId);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "Método no permitido." }, 405);
  try {
    console.log("invite-user: inicio");
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const appUrl = Deno.env.get("APP_URL");
    if (!appUrl) return json({ ok: false, error: "Falta configurar APP_URL en la función." }, 500);

    const authorization = req.headers.get("Authorization") ?? "";
    const callerClient = createClient(url, anon, { global: { headers: { Authorization: authorization } } });
    const { data: userData, error: userError } = await within("SESSION", callerClient.auth.getUser());
    if (userError || !userData.user) return json({ ok: false, error: "Sesión no válida." }, 401);

    const admin = createClient(url, service, { auth: { autoRefreshToken: false, persistSession: false } });
    console.log("invite-user: verificando SUPERADMIN");
    const { data: caller, error: callerError } = await within("PROFILE", admin.schema("v2").from("profiles")
      .select("rol,activo").eq("user_id", userData.user.id).single());
    if (callerError) throw callerError;
    if (!caller?.activo || caller.rol !== "SUPERADMIN") {
      return json({ ok: false, error: "Sólo SUPERADMIN puede enviar invitaciones." }, 403);
    }

    const body = await req.json();
    const email = String(body.email ?? "").trim().toLowerCase();
    const name = String(body.name ?? "").trim() || null;
    const role = String(body.role ?? "CAPTURISTA").trim().toUpperCase();
    const unitIds = Array.isArray(body.unitIds) ? [...new Set(body.unitIds)] : [];
    const municipalityIds = Array.isArray(body.municipalityIds) ? [...new Set(body.municipalityIds)] : [];
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ ok: false, error: "Correo no válido." }, 400);
    if (!["ADMIN", "SUPERVISOR", "DIRECTIVO", "CAPTURISTA"].includes(role)) return json({ ok: false, error: "Rol no permitido." }, 400);
    if (role === "CAPTURISTA" && (!unitIds.length || !municipalityIds.length)) {
      return json({ ok: false, error: "El capturista necesita unidad y municipio." }, 400);
    }

    console.log("invite-user: enviando correo", { email, role });
    const { data: invited, error: inviteError } = await within("EMAIL", admin.auth.admin.inviteUserByEmail(email, {
      redirectTo: `${appUrl.replace(/\/$/, "")}/establecer-acceso.html`, data: { full_name: name },
    }), 25000);
    if (inviteError || !invited.user) throw inviteError ?? new Error("No se creó la invitación.");

    const uid = invited.user.id;
    console.log("invite-user: configurando perfil");
    const { error: profileError } = await within("PROFILE_SAVE", admin.schema("v2").from("profiles").upsert({
      user_id: uid, email, nombre: name, rol: role, activo: true, updated_at: new Date().toISOString(),
    }, { onConflict: "user_id" }));
    if (profileError) throw profileError;

    if (unitIds.length) {
      const { error } = await within("UNITS", admin.schema("v2").from("profile_unidades").upsert(
        unitIds.map((id: string, i: number) => ({ user_id: uid, unidad_operativa_id: id, es_principal: i === 0, activo: true, created_by: userData.user.id })),
        { onConflict: "user_id,unidad_operativa_id" }));
      if (error) throw error;
    }
    if (municipalityIds.length) {
      const { error } = await within("MUNICIPALITIES", admin.schema("v2").from("profile_municipios").upsert(
        municipalityIds.map((id: string, i: number) => ({ user_id: uid, municipio_id: id, es_principal: i === 0, activo: true, created_by: userData.user.id })),
        { onConflict: "user_id,municipio_id" }));
      if (error) throw error;
    }
    await within("AUDIT", admin.schema("v2").from("invitaciones_usuarios").insert({
      email, rol: role, invitado_por: userData.user.id, auth_user_id: uid,
      metadata: { unidades: unitIds.length, municipios: municipalityIds.length },
    }));
    console.log("invite-user: terminado");
    return json({ ok: true });
  } catch (error) {
    console.error("invite-user: error", error);
    return json({ ok: false, error: error instanceof Error ? error.message : "No se pudo enviar la invitación." }, 400);
  }
});
