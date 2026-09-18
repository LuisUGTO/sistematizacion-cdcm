import { supabase, dbV2 } from "./supabase-client.js";
import { loadAuthContext } from "./auth.js";
import { isSuperAdmin } from "./permissions.js";
import {
  HOME_CONTENT_BUCKET,
  HOME_CONTENT_DEFAULTS,
  getHomeContent,
  homeContentImageUrl,
} from "./home-content.js";

const $ = (id) => document.getElementById(id);
const IMAGE_SLOTS = ["hero", "galleryOne", "galleryTwo"];
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const ACCEPTED_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

const fieldNames = Object.keys(HOME_CONTENT_DEFAULTS).filter((key) => !key.endsWith("ImagePath"));

function setForm(content) {
  Object.entries(HOME_CONTENT_DEFAULTS).forEach(([key, fallback]) => {
    const input = $(`content-${key}`);
    if (input) input.value = content[key] ?? fallback;
  });
  updatePreviews(content);
}

function formContent() {
  return Object.fromEntries(Object.entries(HOME_CONTENT_DEFAULTS).map(([key, fallback]) => {
    const input = $(`content-${key}`);
    return [key, String(input?.value ?? fallback).trim()];
  }));
}

function updatePreviews(content) {
  IMAGE_SLOTS.forEach((slot) => {
    const image = $(`content-${slot}-preview`);
    const path = content[`${slot}ImagePath`];
    if (image) image.src = homeContentImageUrl(path);
  });
}

function filePath(slot, file) {
  const extension = file.name.split(".").pop()?.toLowerCase() || "jpg";
  return `inicio/${slot}/${Date.now()}-${crypto.randomUUID()}.${extension}`;
}

async function uploadSelectedImages(content) {
  for (const slot of IMAGE_SLOTS) {
    const file = $(`content-${slot}-file`)?.files?.[0];
    if (!file) continue;
    if (!ACCEPTED_TYPES.has(file.type)) throw new Error("Usa imágenes JPG, PNG o WEBP.");
    if (file.size > MAX_IMAGE_BYTES) throw new Error("Cada imagen debe pesar como máximo 5 MB.");

    const path = filePath(slot, file);
    const { error } = await supabase.storage.from(HOME_CONTENT_BUCKET).upload(path, file, {
      cacheControl: "3600",
      contentType: file.type,
      upsert: false,
    });
    if (error) throw error;
    content[`${slot}ImagePath`] = path;
  }
}

async function saveContent(event, context) {
  event.preventDefault();
  const button = $("saveHomeContent");
  button.disabled = true;
  button.textContent = "Publicando…";
  try {
    const content = formContent();
    await uploadSelectedImages(content);
    const { error } = await dbV2().from("configuracion_inicio").upsert({
      id: true,
      contenido: content,
      updated_by: context.user.id,
    }, { onConflict: "id" });
    if (error) throw error;

    await Swal.fire("Inicio actualizado", "Los cambios ya están publicados para las cuentas que ingresen al sistema.", "success");
    $("content-hero-file").value = "";
    $("content-galleryOne-file").value = "";
    $("content-galleryTwo-file").value = "";
  } catch (error) {
    await Swal.fire("No se pudo publicar", error?.message ?? "Revisa los datos e intenta nuevamente.", "error");
  } finally {
    button.disabled = false;
    button.textContent = "Publicar cambios";
  }
}

async function initialize() {
  const tab = $("contentTab");
  const panel = $("panel-content");
  if (!tab || !panel) return;

  try {
    const context = await loadAuthContext({ force: true });
    if (!context || !isSuperAdmin(context)) {
      tab.hidden = true;
      panel.hidden = true;
      return;
    }

    panel.hidden = false;

    const { content } = await getHomeContent();
    setForm(content);
    $("homeContentForm").addEventListener("submit", (event) => saveContent(event, context));
    $("resetHomeContent").addEventListener("click", () => {
      setForm(HOME_CONTENT_DEFAULTS);
      IMAGE_SLOTS.forEach((slot) => { $(`content-${slot}-file`).value = ""; });
    });
    IMAGE_SLOTS.forEach((slot) => {
      $(`content-${slot}-file`).addEventListener("change", (event) => {
        const file = event.target.files?.[0];
        if (file) $(`content-${slot}-preview`).src = URL.createObjectURL(file);
      });
    });
  } catch (error) {
    console.error("Contenido institucional:", error);
    tab.hidden = true;
    panel.hidden = true;
  }
}

initialize();
