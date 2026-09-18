import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, "Content-Type": "application/json" },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "Método no permitido." }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const appUrl = Deno.env.get("APP_URL");
    if (!appUrl) return json({ ok: false, error: "Falta configurar APP_URL en la función." }, 500);

    const authorization = req.headers.get("Authorization") ?? "";
    const callerClient = createClient(url, anon, { global: { headers: { Authorization: authorization } } });
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData.user) return json({ ok: false, error: "Sesión no válida." }, 401);

    const admin = createClient(url, service, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data: caller } = await admin.schema("v2").from("profiles")
      .select("rol,activo").eq("user_id", userData.user.id).single();
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

    const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
      redirectTo: `${appUrl.replace(/\/$/, "")}/establecer-acceso.html`, data: { full_name: name },
    });
    if (inviteError || !invited.user) throw inviteError ?? new Error("No se creó la invitación.");

    const uid = invited.user.id;
    const { error: profileError } = await admin.schema("v2").from("profiles").upsert({
      user_id: uid, email, nombre: name, rol: role, activo: true, updated_at: new Date().toISOString(),
    }, { onConflict: "user_id" });
    if (profileError) throw profileError;

    if (unitIds.length) {
      const { error } = await admin.schema("v2").from("profile_unidades").upsert(
        unitIds.map((id: string, i: number) => ({ user_id: uid, unidad_operativa_id: id, es_principal: i === 0, activo: true, created_by: userData.user.id })),
        { onConflict: "user_id,unidad_operativa_id" });
      if (error) throw error;
    }
    if (municipalityIds.length) {
      const { error } = await admin.schema("v2").from("profile_municipios").upsert(
        municipalityIds.map((id: string, i: number) => ({ user_id: uid, municipio_id: id, es_principal: i === 0, activo: true, created_by: userData.user.id })),
        { onConflict: "user_id,municipio_id" });
      if (error) throw error;
    }
    await admin.schema("v2").from("invitaciones_usuarios").insert({
      email, rol: role, invitado_por: userData.user.id, auth_user_id: uid,
      metadata: { unidades: unitIds.length, municipios: municipalityIds.length },
    });
    return json({ ok: true });
  } catch (error) {
    console.error(error);
    return json({ ok: false, error: error instanceof Error ? error.message : "No se pudo enviar la invitación." }, 400);
  }
});
