import { supabase, dbV2 } from "./supabase-client.js";

export const HOME_CONTENT_BUCKET = "contenido-inicio";

export const HOME_CONTENT_DEFAULTS = Object.freeze({
  heroKicker: "Vinculación Cultural · Guanajuato",
  heroTitle: "La cultura del territorio, en un solo sistema",
  heroDescription: "Registra, valida y consulta la actividad cultural de los municipios con información confiable, ordenada y trazable.",
  primaryActionLabel: "Registrar una actividad",
  secondaryActionLabel: "Consultar bitácora",
  heroImagePath: "assets/identidad-institucional/inicio/portada/inicio-portada-guanajuato.jpg",
  heroImageAlt: "Arquitectura y patrimonio cultural de Guanajuato",
  heroCaption: "Patrimonio cultural de Guanajuato · fotografía institucional",
  galleryTitle: "Cultura que sucede en el territorio",
  galleryDescription: "Espacios, patrimonio y servicios culturales de Guanajuato.",
  galleryOneImagePath: "assets/identidad-institucional/inicio/destacados/inicio-patrimonio-cultural.jpg",
  galleryOneImageAlt: "Patio de un recinto histórico y cultural de Guanajuato",
  galleryOneTitle: "Patrimonio e infraestructura cultural",
  galleryOneDescription: "Espacios que resguardan y acercan la cultura.",
  galleryTwoImagePath: "assets/identidad-institucional/inicio/destacados/inicio-bibliotecas-lectura.jpg",
  galleryTwoImageAlt: "Biblioteca con acervo y mobiliario de consulta",
  galleryTwoTitle: "Bibliotecas y espacios de lectura",
  galleryTwoDescription: "Conocimiento, memoria y encuentro comunitario.",
});

function normalizedContent(value) {
  return { ...HOME_CONTENT_DEFAULTS, ...(value && typeof value === "object" ? value : {}) };
}

export function homeContentImageUrl(path) {
  const value = String(path ?? "").trim();
  if (!value || value.startsWith("assets/") || /^https?:\/\//i.test(value)) return value;
  return supabase.storage.from(HOME_CONTENT_BUCKET).getPublicUrl(value).data.publicUrl;
}

export async function getHomeContent() {
  const { data, error } = await dbV2()
    .from("configuracion_inicio")
    .select("contenido,updated_at")
    .eq("id", true)
    .maybeSingle();

  if (error) throw error;
  return { content: normalizedContent(data?.contenido), updatedAt: data?.updated_at ?? null };
}

export function applyHomeContent(content, root = document) {
  const value = normalizedContent(content);
  root.querySelectorAll("[data-home-content]").forEach((element) => {
    const key = element.dataset.homeContent;
    if (key in value) element.textContent = value[key] ?? "";
  });

  root.querySelectorAll("img[data-home-image]").forEach((image) => {
    const key = image.dataset.homeImage;
    if (key in value) image.src = homeContentImageUrl(value[key]);
    const altKey = image.dataset.homeAlt;
    if (altKey && altKey in value) image.alt = value[altKey] ?? "";
  });

  return value;
}
