/**
 * VINCULACIÓN CULTURAL 2.0
 * permissions.js
 *
 * Autorización de interfaz alineada con 06_rls.sql.
 *
 * La UI NO sustituye RLS.
 */

export const ROLES = Object.freeze({
  ADMIN: "ADMIN",
  SUPERVISOR: "SUPERVISOR",
  DIRECTIVO: "DIRECTIVO",
  CAPTURISTA: "CAPTURISTA",
});

export const PERMISSIONS = Object.freeze({
  ACCESS_APP: "ACCESS_APP",

  CAPTURE_CREATE: "CAPTURE_CREATE",
  CAPTURE_EDIT_OWN: "CAPTURE_EDIT_OWN",

  BITACORA_VIEW_OWN: "BITACORA_VIEW_OWN",
  BITACORA_VIEW_SCOPE: "BITACORA_VIEW_SCOPE",

  DASHBOARD_VIEW_SCOPE: "DASHBOARD_VIEW_SCOPE",

  VALIDATION_REVIEW: "VALIDATION_REVIEW",
  VALIDATION_APPROVE: "VALIDATION_APPROVE",

  CATALOG_READ: "CATALOG_READ",
  CATALOG_MANAGE: "CATALOG_MANAGE",

  USER_MANAGE: "USER_MANAGE",
  IMPORT_MANAGE: "IMPORT_MANAGE",
  AUDIT_VIEW: "AUDIT_VIEW",
});

const ALL = Object.freeze(Object.values(PERMISSIONS));

const ROLE_PERMISSIONS = Object.freeze({
  [ROLES.ADMIN]: ALL,

  // 06_rls.sql permite al SUPERVISOR revisar/actualizar dentro de alcance,
  // pero NO crear registros nuevos.
  [ROLES.SUPERVISOR]: Object.freeze([
    PERMISSIONS.ACCESS_APP,
    PERMISSIONS.BITACORA_VIEW_SCOPE,
    PERMISSIONS.DASHBOARD_VIEW_SCOPE,
    PERMISSIONS.VALIDATION_REVIEW,
    PERMISSIONS.VALIDATION_APPROVE,
    PERMISSIONS.CATALOG_READ,
    PERMISSIONS.IMPORT_MANAGE,
  ]),

  [ROLES.DIRECTIVO]: Object.freeze([
    PERMISSIONS.ACCESS_APP,
    PERMISSIONS.BITACORA_VIEW_SCOPE,
    PERMISSIONS.DASHBOARD_VIEW_SCOPE,
    PERMISSIONS.CATALOG_READ,
  ]),

  [ROLES.CAPTURISTA]: Object.freeze([
    PERMISSIONS.ACCESS_APP,
    PERMISSIONS.CAPTURE_CREATE,
    PERMISSIONS.CAPTURE_EDIT_OWN,
    PERMISSIONS.BITACORA_VIEW_OWN,
    PERMISSIONS.CATALOG_READ,
  ]),
});

export function normalizeRole(role) {
  return String(role ?? "").trim().toUpperCase();
}

export function getRolePermissions(role) {
  return ROLE_PERMISSIONS[normalizeRole(role)] ?? [];
}

export function can(profileOrContext, permission) {
  const profile = profileOrContext?.profile ?? profileOrContext;

  if (!profile || profile.activo !== true) {
    return false;
  }

  return getRolePermissions(profile.rol).includes(permission);
}

export function canAny(profileOrContext, permissions = []) {
  return permissions.some((permission) =>
    can(profileOrContext, permission)
  );
}

export function canAll(profileOrContext, permissions = []) {
  return permissions.every((permission) =>
    can(profileOrContext, permission)
  );
}

export function isAdmin(profileOrContext) {
  const profile = profileOrContext?.profile ?? profileOrContext;
  return normalizeRole(profile?.rol) === ROLES.ADMIN;
}

export function isSupervisor(profileOrContext) {
  const profile = profileOrContext?.profile ?? profileOrContext;
  return normalizeRole(profile?.rol) === ROLES.SUPERVISOR;
}

export function isDirectivo(profileOrContext) {
  const profile = profileOrContext?.profile ?? profileOrContext;
  return normalizeRole(profile?.rol) === ROLES.DIRECTIVO;
}

export function isCapturista(profileOrContext) {
  const profile = profileOrContext?.profile ?? profileOrContext;
  return normalizeRole(profile?.rol) === ROLES.CAPTURISTA;
}

export function isWithinUnitScope(context, unitId) {
  if (!context?.profile || !unitId) return false;
  if (isAdmin(context)) return true;

  return Boolean(
    context.scopes?.unitIds?.includes(unitId)
  );
}

export function isWithinMunicipalityScope(context, municipalityId) {
  if (!context?.profile || !municipalityId) return false;
  if (isAdmin(context)) return true;

  return Boolean(
    context.scopes?.municipalityIds?.includes(municipalityId)
  );
}

export function applyPermissionVisibility(root, context) {
  const scope = root ?? document;

  scope
    .querySelectorAll("[data-permission]")
    .forEach((element) => {
      const required = element.dataset.permission;
      const visible = can(context, required);

      element.hidden = !visible;
      element.setAttribute(
        "aria-hidden",
        visible ? "false" : "true"
      );
    });
}
