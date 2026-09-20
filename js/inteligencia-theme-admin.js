import { supabase, dbV2 } from "./supabase-client.js";
import { loadAuthContext } from "./auth.js";
import { isSuperAdmin } from "./permissions.js";
import {
  INTELLIGENCE_THEME_BUCKET,
  INTELLIGENCE_THEME_DEFAULTS,
  INTELLIGENCE_THEME_PALETTES,
  intelligenceThemeImageUrl,
} from "./inteligencia-theme.js";

const $ = (id) => document.getElementById(id);
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const ACCEPTED_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
let themes = [];
let currentContent = { ...INTELLIGENCE_THEME_DEFAULTS };

function dateValue(value) { return value ? String(value).slice(0, 10) : ""; }
function contentFromForm() {
  return {
    kicker: $("themeKicker").value.trim(),
    title: $("themeTitle").value.trim(),
    description: $("themeDescription").value.trim(),
    palette: $("themePalette").value,
    imagePath: currentContent.imagePath || "",
    imageAlt: $("themeImageAlt").value.trim(),
    imageCredit: $("themeImageCredit").value.trim(),
  };
}

function setPreview(content) {
  const image = $("themeImagePreview");
  const source = intelligenceThemeImageUrl(content.imagePath);
  image.src = source || "assets/identidad-institucional/logos/Logo.png";
  renderLivePreview(source);
}

function renderLivePreview(imageSource = null) {
  const palette = INTELLIGENCE_THEME_PALETTES[$("themePalette").value] ?? INTELLIGENCE_THEME_PALETTES.INSTITUCIONAL;
  const preview = $("themeLivePreview");
  preview.style.setProperty("--preview-primary", palette.primary);
  preview.style.setProperty("--preview-secondary", palette.secondary);
  preview.style.setProperty("--preview-accent", palette.accent);
  $("themeLiveKicker").textContent = $("themeKicker").value.trim() || INTELLIGENCE_THEME_DEFAULTS.kicker;
  $("themeLiveTitle").textContent = $("themeTitle").value.trim() || INTELLIGENCE_THEME_DEFAULTS.title;
  $("themeLiveDescription").textContent = $("themeDescription").value.trim() || INTELLIGENCE_THEME_DEFAULTS.description;
  const liveImage = $("themeLiveImage");
  const source = imageSource ?? intelligenceThemeImageUrl(currentContent.imagePath);
  liveImage.hidden = !source;
  if (source) liveImage.src = source;
}

function setForm(theme = null) {
  currentContent = { ...INTELLIGENCE_THEME_DEFAULTS, ...(theme?.contenido ?? {}) };
  $("themeId").value = theme?.id ?? "";
  $("themeName").value = theme?.nombre ?? "";
  $("themeActive").checked = theme?.activo ?? true;
  $("themeStart").value = dateValue(theme?.fecha_inicio);
  $("themeEnd").value = dateValue(theme?.fecha_fin);
  $("themePriority").value = theme?.prioridad ?? 0;
  $("themeKicker").value = currentContent.kicker;
  $("themeTitle").value = currentContent.title;
  $("themeDescription").value = currentContent.description;
  $("themePalette").value = currentContent.palette;
  $("themeImageAlt").value = currentContent.imageAlt;
  $("themeImageCredit").value = currentContent.imageCredit;
  $("themeImageFile").value = "";
  $("themeFormTitle").textContent = theme ? "Editar tema programado" : "Crear tema cultural";
  $("saveTheme").textContent = theme ? "Guardar cambios" : "Programar tema";
  setPreview(currentContent);
}

function dateLabel(theme) {
  if (!theme.fecha_inicio && !theme.fecha_fin) return "Siempre disponible";
  return `${theme.fecha_inicio ? new Date(`${theme.fecha_inicio}T00:00:00`).toLocaleDateString("es-MX", { day:"2-digit", month:"short", year:"numeric" }) : "Sin inicio"} — ${theme.fecha_fin ? new Date(`${theme.fecha_fin}T00:00:00`).toLocaleDateString("es-MX", { day:"2-digit", month:"short", year:"numeric" }) : "Sin fin"}`;
}

function renderThemes() {
  const body = $("themeTable");
  body.replaceChildren();
  if (!themes.length) {
    const row = document.createElement("tr");
    row.innerHTML = '<td colspan="5">Aún no hay temas programados. Se mantiene la identidad institucional predeterminada.</td>';
    body.appendChild(row);
    return;
  }
  themes.forEach((theme) => {
    const row = document.createElement("tr");
    const palette = INTELLIGENCE_THEME_PALETTES[theme.contenido?.palette]?.label || "Institucional";
    row.innerHTML = `<td><strong></strong><small></small></td><td></td><td></td><td></td><td></td>`;
    row.children[0].querySelector("strong").textContent = theme.nombre;
    row.children[0].querySelector("small").textContent = `Prioridad ${theme.prioridad}`;
    row.children[1].textContent = dateLabel(theme);
    row.children[2].textContent = palette;
    const status = document.createElement("span"); status.className = `catalog-status ${theme.activo ? "active" : "inactive"}`; status.textContent = theme.activo ? "Activo" : "Inactivo"; row.children[3].appendChild(status);
    const actions = document.createElement("div"); actions.className = "catalog-table-actions";
    const edit = document.createElement("button"); edit.type = "button"; edit.className = "button button-secondary"; edit.textContent = "Editar"; edit.addEventListener("click", () => { setForm(theme); $("themeForm").scrollIntoView({ behavior:"smooth", block:"start" }); });
    const toggle = document.createElement("button"); toggle.type = "button"; toggle.className = "button button-quiet"; toggle.textContent = theme.activo ? "Desactivar" : "Activar"; toggle.addEventListener("click", () => toggleTheme(theme));
    actions.append(edit, toggle); row.children[4].appendChild(actions); body.appendChild(row);
  });
}

async function loadThemes() {
  const { data, error } = await dbV2().from("temas_inteligencia").select("*").order("activo", { ascending:false }).order("prioridad", { ascending:false }).order("fecha_inicio", { ascending:false, nullsFirst:false });
  if (error) throw error;
  themes = data ?? [];
  renderThemes();
}

async function uploadImage(content, themeId) {
  const file = $("themeImageFile").files?.[0];
  if (!file) return;
  if (!ACCEPTED_TYPES.has(file.type)) throw new Error("Usa imágenes JPG, PNG o WEBP.");
  if (file.size > MAX_IMAGE_BYTES) throw new Error("La imagen debe pesar como máximo 5 MB.");
  const extension = file.name.split(".").pop()?.toLowerCase() || "jpg";
  const path = `temas/${themeId || crypto.randomUUID()}/${Date.now()}-${crypto.randomUUID()}.${extension}`;
  const { error } = await supabase.storage.from(INTELLIGENCE_THEME_BUCKET).upload(path, file, { cacheControl:"3600", contentType:file.type, upsert:false });
  if (error) throw error;
  content.imagePath = path;
}

async function saveTheme(event) {
  event.preventDefault();
  const start = $("themeStart").value || null;
  const end = $("themeEnd").value || null;
  if (start && end && start > end) { await Swal.fire("Revisa las fechas", "La fecha de inicio no puede ser posterior a la fecha de fin.", "warning"); return; }
  const button = $("saveTheme"); button.disabled = true;
  try {
    const id = $("themeId").value || null;
    const content = contentFromForm();
    await uploadImage(content, id);
    const payload = { nombre: $("themeName").value.trim(), activo: $("themeActive").checked, fecha_inicio:start, fecha_fin:end, prioridad:Number($("themePriority").value || 0), contenido:content };
    if (!payload.nombre || !content.title) throw new Error("Indica al menos el nombre del tema y su título principal.");
    const request = id ? dbV2().from("temas_inteligencia").update(payload).eq("id", id) : dbV2().from("temas_inteligencia").insert(payload);
    const { error } = await request;
    if (error) throw error;
    await loadThemes(); setForm();
    await Swal.fire("Tema guardado", "La programación quedó publicada. Se aplicará automáticamente cuando corresponda a sus fechas.", "success");
  } catch (error) {
    await Swal.fire("No se pudo guardar", error?.message ?? "Revisa los campos e inténtalo de nuevo.", "error");
  } finally { button.disabled = false; }
}

async function toggleTheme(theme) {
  const { error } = await dbV2().from("temas_inteligencia").update({ activo: !theme.activo }).eq("id", theme.id);
  if (error) { await Swal.fire("No se pudo actualizar", error.message, "error"); return; }
  await loadThemes();
}

async function init() {
  const tab = $("themeTab"); const panel = $("panel-themes");
  if (!tab || !panel) return;
  const context = await loadAuthContext({ force:true });
  if (!context || !isSuperAdmin(context)) { tab.hidden = true; panel.hidden = true; return; }
  tab.hidden = false; panel.hidden = false;
  Object.entries(INTELLIGENCE_THEME_PALETTES).forEach(([value, palette]) => {
    const option = document.createElement("option"); option.value = value; option.textContent = palette.label; $("themePalette").appendChild(option);
  });
  setForm(); await loadThemes();
  $("themeForm").addEventListener("submit", saveTheme);
  $("resetTheme").addEventListener("click", () => setForm());
  ["themeKicker", "themeTitle", "themeDescription", "themePalette"].forEach((id) => $(id).addEventListener("input", () => renderLivePreview()));
  $("themeImageFile").addEventListener("change", (event) => {
    const file = event.target.files?.[0];
    if (!file) { setPreview(currentContent); return; }
    const source = URL.createObjectURL(file);
    $("themeImagePreview").src = source;
    renderLivePreview(source);
  });
}

init().catch((error) => { console.error("Temas culturales:", error); });
