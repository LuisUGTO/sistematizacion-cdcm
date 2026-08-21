/**
 * VINCULACIÓN CULTURAL 2.0
 * auth.js
 *
 * Autenticación y contexto de usuario.
 *
 * Regla crítica:
 * EL NAVEGADOR NUNCA CREA NI PROMUEVE UN ADMIN.
 * El rol se lee exclusivamente desde v2.profiles.
 */

import { APP_CONFIG } from "./config.js";
import { supabase, dbV2 } from "./supabase-client.js";

let authContextCache = null;

function normalizeEmail(value) {
  return String(value ?? "").trim().toLowerCase();
}

function buildRedirectUrl(path = "index.html") {
  const base = new URL(window.location.href);
  base.hash = "";
  base.search = "";

  const currentDirectory = base.pathname.endsWith("/")
    ? base.pathname
    : base.pathname.substring(0, base.pathname.lastIndexOf("/") + 1);

  base.pathname = `${currentDirectory}${path}`.replace(/\/{2,}/g, "/");
  return base.toString();
}

export async function sendMagicLink(email, options = {}) {
  const normalizedEmail = normalizeEmail(email);

  if (!normalizedEmail || !normalizedEmail.includes("@")) {
    throw new Error("AUTH_EMAIL_INVALID");
  }

  const emailRedirectTo =
    options.emailRedirectTo ?? buildRedirectUrl("index.html");

  const { data, error } = await supabase.auth.signInWithOtp({
    email: normalizedEmail,
    options: {
      emailRedirectTo,
      shouldCreateUser:
        options.shouldCreateUser ??
        APP_CONFIG.auth.shouldCreateUserFromMagicLink,
    },
  });

  if (error) throw error;

  return data;
}

export async function getSession() {
  const { data, error } = await supabase.auth.getSession();

  if (error) throw error;

  return data?.session ?? null;
}

export async function getAuthenticatedUser() {
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();

  if (error) throw error;

  return user ?? null;
}

export async function getProfile(userId) {
  if (!userId) return null;

  const { data, error } = await dbV2()
    .from("profiles")
    .select("user_id,email,nombre,rol,activo,created_at,updated_at")
    .eq("user_id", userId)
    .maybeSingle();

  // Un perfil inexistente o no visible por RLS se considera sin acceso.
  if (error) {
    if (error.code === "PGRST116") return null;
    throw error;
  }

  return data ?? null;
}

export async function getUserScopes(userId) {
  if (!userId) {
    return {
      units: [],
      municipalities: [],
      unitIds: [],
      municipalityIds: [],
    };
  }

  const [unitsResult, municipalitiesResult] = await Promise.all([
    dbV2()
      .from("profile_unidades")
      .select("unidad_operativa_id,es_principal,activo")
      .eq("user_id", userId)
      .eq("activo", true),

    dbV2()
      .from("profile_municipios")
      .select("municipio_id,es_principal,activo")
      .eq("user_id", userId)
      .eq("activo", true),
  ]);

  if (unitsResult.error) throw unitsResult.error;
  if (municipalitiesResult.error) throw municipalitiesResult.error;

  const units = unitsResult.data ?? [];
  const municipalities = municipalitiesResult.data ?? [];

  return {
    units,
    municipalities,
    unitIds: units.map((row) => row.unidad_operativa_id),
    municipalityIds: municipalities.map((row) => row.municipio_id),
  };
}

export async function loadAuthContext({ force = false } = {}) {
  if (authContextCache && !force) {
    return authContextCache;
  }

  const session = await getSession();

  if (!session?.user) {
    authContextCache = null;
    return null;
  }

  const profile = await getProfile(session.user.id);

  if (!profile) {
    const error = new Error("AUTH_PROFILE_NOT_AVAILABLE");
    error.code = "AUTH_PROFILE_NOT_AVAILABLE";
    throw error;
  }

  if (profile.activo !== true) {
    const error = new Error("AUTH_PROFILE_INACTIVE");
    error.code = "AUTH_PROFILE_INACTIVE";
    throw error;
  }

  const scopes = await getUserScopes(session.user.id);

  authContextCache = Object.freeze({
    session,
    user: session.user,
    profile: Object.freeze(profile),
    scopes: Object.freeze({
      units: Object.freeze(scopes.units),
      municipalities: Object.freeze(scopes.municipalities),
      unitIds: Object.freeze(scopes.unitIds),
      municipalityIds: Object.freeze(scopes.municipalityIds),
    }),
  });

  return authContextCache;
}

export function clearAuthContextCache() {
  authContextCache = null;
}

export async function requireAuth(options = {}) {
  const {
    redirectOnMissingSession = false,
    redirectPath = "index.html",
  } = options;

  const context = await loadAuthContext({ force: true });

  if (!context && redirectOnMissingSession) {
    window.location.assign(buildRedirectUrl(redirectPath));
    return null;
  }

  return context;
}

export async function signOut() {
  clearAuthContextCache();

  const { error } = await supabase.auth.signOut();

  if (error) throw error;
}

export function onAuthStateChange(callback) {
  return supabase.auth.onAuthStateChange((event, session) => {
    clearAuthContextCache();

    if (typeof callback === "function") {
      callback(event, session);
    }
  });
}

/**
 * Nunca usar este método para confiar en la UI.
 * Sirve únicamente para mostrar identidad de sesión.
 */
export function getDisplayIdentity(context) {
  if (!context) {
    return {
      name: "Sin sesión",
      email: "",
      initials: "U",
    };
  }

  const name =
    context.profile?.nombre ||
    context.user?.user_metadata?.full_name ||
    context.user?.user_metadata?.name ||
    context.user?.email ||
    "Usuario";

  const email = normalizeEmail(
    context.profile?.email || context.user?.email
  );

  const initials = String(name)
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part.charAt(0).toUpperCase())
    .join("") || "U";

  return { name, email, initials };
}
