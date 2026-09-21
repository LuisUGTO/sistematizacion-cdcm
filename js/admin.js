/**
 * VINCULACIÓN CULTURAL 2.0
 * admin.js — Etapa 6.5
 * Administración V2 de usuarios, roles, alcances y catálogos.
 */

import { supabase, dbV2 } from "./supabase-client.js";
import { loadAuthContext } from "./auth.js";
import { isAdmin, isSuperAdmin } from "./permissions.js";

const publicDb = supabase.schema("public");
const ADMIN_SAVE_TIMEOUT_MS = 20000;

const state = {
  context: null,
  users: [],
  units: [],
  municipalities: [],
  selectedUser: null,
};

const $ = (id) => document.getElementById(id);

const ui = {
  loading: $("loadingOverlay"),
  adminIdentity: $("adminIdentity"),
  userList: $("userList"),
  search: $("userSearch"),
  filter: $("userFilter"),
  statTotal: $("statTotal"),
  statReady: $("statReady"),
  statIncomplete: $("statIncomplete"),
  statInactive: $("statInactive"),
  dialog: $("accessDialog"),
  accessForm: $("accessForm"),
  dialogEmail: $("dialogEmail"),
  dialogNameField: $("dialogNameField"),
  dialogName: $("dialogName"),
  saveUserName: $("saveUserName"),
  dialogRole: $("dialogRole"),
  dialogActive: $("dialogActive"),
  unitChecks: $("unitChecks"),
  municipalityChecks: $("municipalityChecks"),
  municipalitySearch: $("municipalitySearch"),
  guidance: $("dialogGuidance"),
  saveAccess: $("saveAccess"),
  inviteDialog: $("inviteDialog"),
  inviteForm: $("inviteForm"),
  inviteUnitChecks: $("inviteUnitChecks"),
  inviteMunicipalityChecks: $("inviteMunicipalityChecks"),
  sendInvite: $("sendInvite"),
};

function normalize(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .trim();
}

function scopeIds(user, kind) {
  return new Set(
    kind === "units"
      ? user?.unidad_ids ?? []
      : user?.municipio_ids ?? []
  );
}

function accessStatus(user) {
  if (!user.activo) return "INACTIVE";
  if (["ADMIN", "SUPERADMIN"].includes(user.rol)) return "READY";

  const hasUnit = (user.unidad_ids?.length ?? 0) > 0;
  const hasMunicipality =
    (user.municipio_ids?.length ?? 0) > 0;

  if (user.rol === "CAPTURISTA") {
    return hasUnit && hasMunicipality
      ? "READY"
      : "INCOMPLETE";
  }

  return hasUnit ? "READY" : "INCOMPLETE";
}

function accessLabel(user) {
  const status = accessStatus(user);
  if (status === "READY") return "Listo para trabajar";
  if (status === "INACTIVE") return "Usuario inactivo";
  if (!(user.unidad_ids?.length ?? 0)) return "Falta unidad";
  return "Falta municipio";
}

function showError(title, error) {
  console.error(title, error);
  const raw = String(error?.message ?? error ?? "Error no identificado");
  const friendly = raw
    .replace("ADMIN_REQUIRED:", "")
    .replace("AUTH_REQUIRED:", "")
    .replace("CAPTURE_UNIT_REQUIRED:", "")
    .replace("CAPTURE_MUNICIPALITY_REQUIRED:", "")
    .replace("SELF_ADMIN_PROTECTED:", "")
    .replace("USER_NOT_FOUND:", "")
    .trim();

  return Swal.fire({ icon: "error", title, text: friendly });
}

function makeBadge(text, className) {
  const badge = document.createElement("span");
  badge.className = `badge ${className}`;
  badge.textContent = text;
  return badge;
}

function renderStats() {
  const statuses = state.users.map(accessStatus);
  ui.statTotal.textContent = state.users.length;
  ui.statReady.textContent = statuses.filter((s) => s === "READY").length;
  ui.statIncomplete.textContent = statuses.filter((s) => s === "INCOMPLETE").length;
  ui.statInactive.textContent = statuses.filter((s) => s === "INACTIVE").length;
}

function filteredUsers() {
  const query = normalize(ui.search.value);
  const filter = ui.filter.value;

  return state.users.filter((user) => {
    const matchesText =
      !query ||
      normalize(user.email).includes(query) ||
      normalize(user.nombre).includes(query);

    const matchesFilter =
      filter === "ALL" || accessStatus(user) === filter;

    return matchesText && matchesFilter;
  });
}

function renderUsers() {
  ui.userList.replaceChildren();

  const users = filteredUsers();
  if (!users.length) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "No hay usuarios que coincidan con el filtro.";
    ui.userList.appendChild(empty);
    return;
  }

  users.forEach((user) => {
    const row = document.createElement("article");
    row.className = "user-row";

    const identity = document.createElement("div");
    const email = document.createElement("div");
    email.className = "user-email";
    email.textContent = user.email;
    const name = document.createElement("div");
    name.className = "user-name";
    name.textContent = user.nombre || "Sin nombre asignado";
    identity.append(email, name);

    const badges = document.createElement("div");
    badges.className = "badges";
    badges.append(
      makeBadge(
        user.rol,
        user.rol === "ADMIN" ? "badge-admin" : "badge-role"
      ),
      makeBadge(
        user.activo ? "Activo" : "Inactivo",
        user.activo ? "badge-active" : "badge-inactive"
      ),
      makeBadge(
        accessLabel(user),
        accessStatus(user) === "READY"
          ? "badge-ready"
          : accessStatus(user) === "INACTIVE"
            ? "badge-inactive"
            : "badge-incomplete"
      )
    );

    const scopes = document.createElement("div");
    scopes.className = "scope-summary";
    const units = document.createElement("span");
    units.textContent = `${user.unidad_ids?.length ?? 0} unidad(es)`;
    const municipalities = document.createElement("span");
    municipalities.textContent = `${user.municipio_ids?.length ?? 0} municipio(s)`;
    scopes.append(units, municipalities);

    const configure = document.createElement("button");
    configure.className = "button button-primary";
    configure.type = "button";
    configure.textContent = "Configurar";
    configure.addEventListener("click", () => openAccessDialog(user));
    if (["ADMIN", "SUPERADMIN"].includes(user.rol) && !isSuperAdmin(state.context)) {
      configure.disabled = true;
      configure.textContent = "Protegido";
    }

    row.append(identity, badges, scopes, configure);
    ui.userList.appendChild(row);
  });
}

function renderCheckList(container, items, selectedIds, prefix) {
  container.replaceChildren();

  items.forEach((item) => {
    const wrapper = document.createElement("div");
    wrapper.className = "check-item";
    if (prefix.includes("municipality")) {
      wrapper.dataset.search = normalize(item.nombre_oficial);
    }

    const input = document.createElement("input");
    input.type = "checkbox";
    input.id = `${prefix}-${item.id}`;
    input.value = item.id;
    input.checked = selectedIds.has(item.id);

    const label = document.createElement("label");
    label.htmlFor = input.id;
    label.textContent =
      prefix.includes("unit") ? item.nombre : item.nombre_oficial;

    wrapper.append(input, label);
    container.appendChild(wrapper);
  });
}

function updateGuidance() {
  const role = ui.dialogRole.value;
  if (role === "ADMIN") {
    ui.guidance.textContent =
      "El administrador tiene acceso global y puede gestionar usuarios. Reserva este rol para responsables del sistema; no es necesario para la captura cotidiana.";
  } else if (role === "CAPTURISTA") {
    ui.guidance.textContent =
      "Un capturista activo necesita al menos una unidad y un municipio. La primera selección se guarda como principal.";
  } else {
    ui.guidance.textContent =
      "Selecciona al menos una unidad. Sin municipios, el alcance del supervisor o directivo puede abarcar toda la unidad asignada.";
  }
}

function openAccessDialog(user) {
  if (user.rol === "SUPERADMIN") {
    Swal.fire("Cuenta protegida", "El SUPERADMIN principal no puede modificarse desde este panel.", "info");
    return;
  }
  state.selectedUser = user;
  ui.dialogEmail.textContent = user.email;
  ui.dialogNameField.hidden = !isSuperAdmin(state.context);
  ui.dialogName.value = user.nombre ?? "";
  ui.dialogRole.value = user.rol;
  ui.dialogActive.checked = user.activo;
  ui.municipalitySearch.value = "";

  renderCheckList(
    ui.unitChecks,
    state.units,
    scopeIds(user, "units"),
    "unit"
  );
  renderCheckList(
    ui.municipalityChecks,
    state.municipalities,
    scopeIds(user, "municipalities"),
    "municipality"
  );
  updateGuidance();
  ui.dialog.showModal();
}

async function saveUserName() {
  if (!state.selectedUser || !isSuperAdmin(state.context)) return;
  const name = ui.dialogName.value.trim();
  if (name.length < 2) {
    return Swal.fire("Nombre incompleto", "Indica al menos dos caracteres para el nombre visible.", "warning");
  }
  ui.saveUserName.disabled = true;
  ui.saveUserName.textContent = "Guardando…";
  try {
    const { data, error } = await dbV2().rpc("rpc_superadmin_actualizar_nombre_usuario", {
      p_user_id: state.selectedUser.user_id,
      p_nombre: name,
    });
    if (error) throw error;
    const saved = Array.isArray(data) ? data[0] : data;
    state.selectedUser.nombre = saved?.nombre ?? name;
    const local = state.users.find((user) => user.user_id === state.selectedUser.user_id);
    if (local) local.nombre = state.selectedUser.nombre;
    renderUsers();
    await Swal.fire({ icon: "success", title: "Nombre actualizado", text: "El nombre visible quedó guardado y el cambio fue auditado.", timer: 1500, showConfirmButton: false });
  } catch (error) {
    await showError("No se pudo actualizar el nombre", error);
  } finally {
    ui.saveUserName.disabled = false;
    ui.saveUserName.textContent = "Guardar nombre";
  }
}

function openInviteDialog() {
  ui.inviteForm.reset();
  renderCheckList(ui.inviteUnitChecks, state.units, new Set(), "invite-unit");
  renderCheckList(ui.inviteMunicipalityChecks, state.municipalities, new Set(), "invite-municipality");
  ui.inviteDialog.showModal();
}

async function sendInvitation(event) {
  event.preventDefault();
  const unitIds = checkedValues(ui.inviteUnitChecks);
  const municipalityIds = checkedValues(ui.inviteMunicipalityChecks);
  const role = $("inviteRole").value;
  if (role === "CAPTURISTA" && (!unitIds.length || !municipalityIds.length)) {
    return Swal.fire("Falta alcance", "Un capturista necesita al menos una unidad y un municipio.", "warning");
  }
  ui.sendInvite.disabled = true;
  ui.sendInvite.textContent = "Enviando…";
  try {
    const controller = new AbortController();
    const timeoutId = window.setTimeout(() => controller.abort(), 35000);
    let result;
    try {
      result = await supabase.functions.invoke("invite-user", { body: {
      email: $("inviteEmail").value.trim(),
      name: $("inviteName").value.trim(), role, unitIds, municipalityIds,
      }, signal: controller.signal });
    } finally { window.clearTimeout(timeoutId); }
    const { data, error } = result;
    if (error) {
      let message = null;
      const response = error?.context;
      if (response?.clone && typeof response.clone().json === "function") {
        try {
          const payload = await response.clone().json();
          message = payload?.error || null;
        } catch (_) {
          // La respuesta puede no contener JSON; se usa el mensaje de respaldo.
        }
      }
      throw new Error(message || error?.message || "No se pudo enviar la invitación.");
    }
    if (!data?.ok) throw new Error(data?.error || "No se confirmó la invitación.");
    ui.inviteDialog.close();
    await loadUsers();
    await Swal.fire("Invitación enviada", "La persona recibirá un correo para activar su acceso.", "success");
  } catch (error) {
    const message = error?.name === "AbortError"
      ? "La solicitud tardó demasiado. Revisa los Logs de la función invite-user; no reintentes hasta identificar el paso detenido."
      : error;
    // Un <dialog> nativo se muestra en la capa superior del navegador. Si
    // permanece abierto, SweetAlert queda detrás y el usuario sólo ve
    // "Enviando…". Cerramos el diálogo antes de presentar el resultado.
    if (ui.inviteDialog.open) ui.inviteDialog.close();
    await showError("No se pudo enviar la invitación", message);
  }
  finally { ui.sendInvite.disabled = false; ui.sendInvite.textContent = "Enviar invitación"; }
}

function checkedValues(container) {
  return [...container.querySelectorAll('input[type="checkbox"]:checked')]
    .map((input) => input.value);
}

function setAllChecks(container, checked) {
  container
    .querySelectorAll('input[type="checkbox"]')
    .forEach((input) => { input.checked = checked; });
}

async function loadCatalogs() {
  const [unitsResult, municipalitiesResult] = await Promise.all([
    dbV2()
      .from("cat_unidades_operativas")
      .select("id,clave,nombre,orden")
      .eq("activo", true)
      .order("orden")
      .order("nombre"),
    dbV2()
      .from("cat_municipios")
      .select("id,clave_inegi,nombre_oficial,orden")
      .eq("activo", true)
      .order("orden")
      .order("nombre_oficial"),
  ]);

  if (unitsResult.error) throw unitsResult.error;
  if (municipalitiesResult.error) throw municipalitiesResult.error;

  state.units = unitsResult.data ?? [];
  state.municipalities = municipalitiesResult.data ?? [];
}

async function loadUsers() {
  ui.userList.innerHTML = '<div class="empty">Actualizando usuarios…</div>';
  const { data, error } = await dbV2().rpc("rpc_admin_listar_usuarios");
  if (error) throw error;
  state.users = data ?? [];
  renderStats();
  renderUsers();
}

async function saveAccess(event) {
  event.preventDefault();
  if (!state.selectedUser) return;

  const role = ui.dialogRole.value;
  const active = ui.dialogActive.checked;
  const unitIds = checkedValues(ui.unitChecks);
  const municipalityIds = checkedValues(ui.municipalityChecks);

  if (active && role === "CAPTURISTA" && !unitIds.length) {
    return Swal.fire("Falta una unidad", "Selecciona al menos una unidad operativa.", "warning");
  }
  if (active && role === "CAPTURISTA" && !municipalityIds.length) {
    return Swal.fire("Falta un municipio", "Selecciona al menos un municipio o usa Todo el estado.", "warning");
  }
  if (active && ["SUPERVISOR", "DIRECTIVO"].includes(role) && !unitIds.length) {
    return Swal.fire("Falta una unidad", "Selecciona al menos una unidad para definir su alcance.", "warning");
  }

  ui.saveAccess.disabled = true;
  ui.saveAccess.textContent = "Guardando…";

  try {
    const controller = new AbortController();
    const timeoutId = window.setTimeout(
      () => controller.abort(),
      ADMIN_SAVE_TIMEOUT_MS
    );

    let result;
    try {
      result = await dbV2()
        .rpc("rpc_admin_guardar_acceso", {
          p_user_id: state.selectedUser.user_id,
          p_rol: role,
          p_activo: active,
          p_unidad_ids: unitIds,
          p_municipio_ids: municipalityIds,
        })
        .abortSignal(controller.signal);
    } finally {
      window.clearTimeout(timeoutId);
    }

    const { error } = result;
    if (error) throw error;

    ui.dialog.close();
    await loadUsers();
    await Swal.fire({
      icon: "success",
      title: "Acceso actualizado",
      text: "El rol y los alcances quedaron guardados.",
      timer: 1800,
      showConfirmButton: false,
    });
  } catch (error) {
    // Un <dialog> abierto vive en la capa superior del navegador. Se cierra
    // temporalmente para que SweetAlert sea visible de inmediato y no parezca
    // que el botón quedó atrapado en "Guardando…".
    if (ui.dialog.open) ui.dialog.close();

    if (error?.name === "AbortError") {
      await Swal.fire({
        icon: "warning",
        title: "La operación tardó demasiado",
        text: "No se confirmó el guardado. Revisa tu conexión y pulsa Actualizar antes de intentarlo nuevamente.",
      });
    } else {
      await showError("No se pudo guardar el acceso", error);
    }

    // El formulario conserva las selecciones para que el ADMIN pueda revisar
    // o reintentar sin configurarlo nuevamente.
    if (state.selectedUser) ui.dialog.showModal();
  } finally {
    ui.saveAccess.disabled = false;
    ui.saveAccess.textContent = "Guardar acceso";
  }
}

function installTabs() {
  document.querySelectorAll(".tab").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll(".tab").forEach((item) => {
        item.setAttribute("aria-selected", String(item === button));
      });
      document.querySelectorAll(".panel").forEach((panel) => {
        panel.classList.toggle("active", panel.id === `panel-${button.dataset.tab}`);
      });
    });
  });
}

function installUserEvents() {
  ui.search.addEventListener("input", renderUsers);
  ui.filter.addEventListener("change", renderUsers);
  $("showIncomplete").addEventListener("click", () => {
    ui.filter.value = "INCOMPLETE";
    renderUsers();
  });
  $("refreshUsers").addEventListener("click", async () => {
    try { await loadUsers(); } catch (error) { await showError("No se pudieron actualizar los usuarios", error); }
  });
  ui.dialogRole.addEventListener("change", updateGuidance);
  ui.saveUserName.addEventListener("click", saveUserName);
  ui.accessForm.addEventListener("submit", saveAccess);
  $("cancelAccess").addEventListener("click", () => ui.dialog.close());
  $("closeDialogX").addEventListener("click", () => ui.dialog.close());
  $("inviteUserButton").addEventListener("click", openInviteDialog);
  ui.inviteForm.addEventListener("submit", sendInvitation);
  $("cancelInvite").addEventListener("click", () => ui.inviteDialog.close());
  $("closeInviteX").addEventListener("click", () => ui.inviteDialog.close());

  document.querySelectorAll("[data-select]").forEach((button) => {
    button.addEventListener("click", () => {
      setAllChecks(
        button.dataset.select === "units" ? ui.unitChecks : ui.municipalityChecks,
        true
      );
    });
  });
  document.querySelectorAll("[data-clear]").forEach((button) => {
    button.addEventListener("click", () => {
      setAllChecks(
        button.dataset.clear === "units" ? ui.unitChecks : ui.municipalityChecks,
        false
      );
    });
  });
  ui.municipalitySearch.addEventListener("input", () => {
    const query = normalize(ui.municipalitySearch.value);
    ui.municipalityChecks.querySelectorAll(".check-item").forEach((item) => {
      item.hidden = Boolean(query) && !item.dataset.search.includes(query);
    });
  });
}

// Catálogos legados: se conservan aislados en public durante la transición V2.
async function loadTeachers() {
  const tbody = $("teacherTable");
  const { data, error } = await publicDb.from("cat_docentes").select("*").order("nombre_docente");
  tbody.replaceChildren();
  if (error) {
    const row = tbody.insertRow();
    row.insertCell().colSpan = 4;
    row.cells[0].textContent = `Catálogo no disponible: ${error.message}`;
    return;
  }
  (data ?? []).forEach((teacher, index) => {
    const row = tbody.insertRow();
    row.insertCell().textContent = index + 1;
    row.insertCell().textContent = teacher.nombre_docente;
    row.insertCell().textContent = "Activo";
    const cell = row.insertCell();
    const button = document.createElement("button");
    button.type = "button";
    button.className = "button button-danger";
    button.textContent = "Eliminar";
    button.addEventListener("click", () => deleteTeacher(teacher.id));
    cell.appendChild(button);
  });
}

async function deleteTeacher(id) {
  const decision = await Swal.fire({ title: "¿Eliminar docente?", text: "Se quitará del catálogo de captura anterior.", icon: "warning", showCancelButton: true, confirmButtonText: "Eliminar", confirmButtonColor: "#c2413b" });
  if (!decision.isConfirmed) return;
  const { error } = await publicDb.from("cat_docentes").delete().eq("id", id);
  if (error) return showError("No se pudo eliminar", error);
  await loadTeachers();
}

function installLegacyEvents() {
  $("teacherForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const name = $("teacherName").value.trim();
    if (!name) return;
    const { error } = await publicDb.from("cat_docentes").insert({ nombre_docente: name });
    if (error) return showError("No se pudo registrar", error);
    event.target.reset();
    await loadTeachers();
  });

}

async function initialize() {
  installTabs();
  installUserEvents();

  try {
    state.context = await loadAuthContext({ force: true });
    if (!state.context || !isAdmin(state.context)) {
      throw new Error("Esta pantalla requiere un perfil de administrador activo.");
    }

    ui.adminIdentity.textContent = `${state.context.user.email} · ADMIN`;
    ui.adminIdentity.textContent = `${state.context.user.email} · ${state.context.profile.rol}`;
    $("inviteUserButton").hidden = !isSuperAdmin(state.context);
    await loadCatalogs();
    installLegacyEvents();
    await Promise.all([loadUsers(), loadTeachers()]);
    ui.loading.hidden = true;
  } catch (error) {
    ui.loading.hidden = true;
    await showError("Acceso administrativo no disponible", error);
    window.location.href = "index.html";
  }
}

initialize();
