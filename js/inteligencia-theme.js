import { supabase, dbV2 } from "./supabase-client.js";

export const INTELLIGENCE_THEME_BUCKET = "temas-inteligencia";
export const INTELLIGENCE_THEME_PALETTES = Object.freeze({
  INSTITUCIONAL: { label: "Institucional", primary: "#043b68", secondary: "#0870b7", accent: "#55d5d4" },
  PATRIO: { label: "Mes patrio", primary: "#006341", secondary: "#c61f2d", accent: "#f4c542" },
  CERVANTINO: { label: "Festival Cervantino", primary: "#4a165f", secondary: "#cb4b8b", accent: "#f3bd3e" },
  MEMORIA: { label: "Día de Muertos", primary: "#3f185b", secondary: "#df6b25", accent: "#f1b638" },
  PATRIMONIO: { label: "Patrimonio", primary: "#5a3a14", secondary: "#93702d", accent: "#63b6a8" },
});

export const INTELLIGENCE_THEME_DEFAULTS = Object.freeze({
  kicker: "DECISIONES BASADAS EN EVIDENCIA",
  title: "Panorama estratégico de Vinculación Cultural",
  description: "Lectura ejecutiva de la operación, territorio, población y resultados institucionales. Cada cifra respeta el alcance y los filtros de la cuenta autenticada.",
  palette: "INSTITUCIONAL",
  imagePath: "",
  imageAlt: "",
  imageCredit: "",
});

function normalized(value) {
  const content = value && typeof value === "object" ? value : {};
  const palette = INTELLIGENCE_THEME_PALETTES[content.palette] ? content.palette : "INSTITUCIONAL";
  return { ...INTELLIGENCE_THEME_DEFAULTS, ...content, palette };
}

export function intelligenceThemeImageUrl(path) {
  const value = String(path ?? "").trim();
  if (!value || value.startsWith("assets/") || /^https?:\/\//i.test(value)) return value;
  return supabase.storage.from(INTELLIGENCE_THEME_BUCKET).getPublicUrl(value).data.publicUrl;
}

export async function getActiveIntelligenceTheme() {
  const today = new Date().toISOString().slice(0, 10);
  const { data, error } = await dbV2()
    .from("temas_inteligencia")
    .select("id,nombre,fecha_inicio,fecha_fin,prioridad,contenido,updated_at")
    .eq("activo", true)
    .or(`fecha_inicio.is.null,fecha_inicio.lte.${today}`)
    .or(`fecha_fin.is.null,fecha_fin.gte.${today}`)
    .order("prioridad", { ascending: false })
    .order("fecha_inicio", { ascending: false, nullsFirst: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data ? { ...data, contenido: normalized(data.contenido) } : null;
}

export function applyIntelligenceTheme(theme, root = document) {
  const content = normalized(theme?.contenido);
  const palette = INTELLIGENCE_THEME_PALETTES[content.palette];
  const hero = root.querySelector(".hero");
  if (hero) {
    hero.style.setProperty("--theme-primary", palette.primary);
    hero.style.setProperty("--theme-secondary", palette.secondary);
    hero.style.setProperty("--theme-accent", palette.accent);
    hero.dataset.theme = content.palette;
  }
  const text = {
    themeKicker: content.kicker,
    themeTitle: content.title,
    themeDescription: content.description,
    themeName: theme?.nombre || "Identidad institucional",
    themeCredit: content.imageCredit,
  };
  Object.entries(text).forEach(([id, value]) => {
    const element = root.getElementById?.(id) ?? root.querySelector?.(`#${id}`);
    if (element) element.textContent = value || "";
  });
  const image = root.getElementById?.("themeImage") ?? root.querySelector?.("#themeImage");
  if (image) {
    const source = intelligenceThemeImageUrl(content.imagePath);
    image.hidden = !source;
    if (source) { image.src = source; image.alt = content.imageAlt || "Imagen representativa del tema cultural"; }
  }
  const credit = root.getElementById?.("themeCredit") ?? root.querySelector?.("#themeCredit");
  if (credit) credit.hidden = !content.imageCredit;
  return content;
}
