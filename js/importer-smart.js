/**
 * Reconocimiento de formatos institucionales complejos.
 * No depende del DOM ni de Supabase para poder probarse de forma aislada.
 */

const MONTHS = new Map([
  ["ENE", 1], ["ENERO", 1],
  ["FEB", 2], ["FEBRERO", 2],
  ["MAR", 3], ["MARZO", 3],
  ["ABR", 4], ["ABRIL", 4],
  ["MAY", 5], ["MAYO", 5],
  ["JUN", 6], ["JUNIO", 6],
  ["JUL", 7], ["JULIO", 7],
  ["AGO", 8], ["AGOSTO", 8],
  ["SEP", 9], ["SEPT", 9], ["SEPTIEMBRE", 9],
  ["OCT", 10], ["OCTUBRE", 10],
  ["NOV", 11], ["NOVIEMBRE", 11],
  ["DIC", 12], ["DICIEMBRE", 12],
]);

export const SMART_ACTION_CANDIDATES = {
  TALLER_CASA_CULTURA: ["TALLER_CASA_CULTURA", "PB3562_2602"],
  TALLER_SALON_CULTURA: ["TALLER_SALON_CULTURA", "PB3562_2602"],
  CAPACITACION_PROMOTORES: ["CAPACITACION_PROMOTORES", "PB3562_2601", "PB3562_2605"],
  REUNION_COLABORACION: ["REUNION_COLABORACION", "ARTICULACION_INTER_INTRA", "PB3563_2602"],
  INTERCAMBIO_CULTURAL: ["INTERCAMBIO_CULTURAL", "PB3563_2602"],
  EVENTO_MUNICIPAL: ["EVENTO_MUNICIPAL", "PB3563_2602"],
};

export const SMART_CATEGORY_LABELS = {
  TALLER_CASA_CULTURA: "Talleres en Casa de Cultura",
  TALLER_SALON_CULTURA: "Salones culturales",
  CAPACITACION_PROMOTORES: "Capacitaciones",
  REUNION_COLABORACION: "Reuniones de colaboración",
  INTERCAMBIO_CULTURAL: "Intercambios culturales",
  EVENTO_MUNICIPAL: "Eventos y actividades municipales",
};

export function normalizeImportText(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-zA-Z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function asText(value) {
  return String(value ?? "").trim();
}

function rowText(row) {
  return normalizeImportText((row ?? []).filter((cell) => cell !== null).join(" | "));
}

function numberValue(value) {
  if (value === null || value === undefined || value === "") return 0;
  if (typeof value === "number" && Number.isFinite(value)) return Math.max(0, Math.round(value));
  const cleaned = String(value).replace(/[^0-9.,-]/g, "").replace(/,/g, "");
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? Math.max(0, Math.round(parsed)) : 0;
}

function excelDateToISO(value, XLSX, fallback) {
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    return value.toISOString().slice(0, 10);
  }
  if (typeof value === "number" && XLSX?.SSF) {
    const parsed = XLSX.SSF.parse_date_code(value);
    if (parsed) {
      return `${parsed.y}-${String(parsed.m).padStart(2, "0")}-${String(parsed.d).padStart(2, "0")}`;
    }
  }
  const raw = asText(value);
  if (!raw) return fallback;
  const match = raw.match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{2,4})$/);
  if (match) {
    const year = match[3].length === 2 ? `20${match[3]}` : match[3];
    return `${year}-${match[2].padStart(2, "0")}-${match[1].padStart(2, "0")}`;
  }
  return fallback;
}

function findColumn(row, aliases) {
  const targets = aliases.map(normalizeImportText);
  return (row ?? []).findIndex((cell) => {
    const current = normalizeImportText(cell);
    return current && targets.some((target) => current === target || current.includes(target));
  });
}

function findBlock(row, precedingText) {
  const current = rowText(row);
  if (current.includes("disciplina saber impartido")) {
    return precedingText.includes("salones culturales")
      ? { category: "TALLER_SALON_CULTURA", nameAliases: ["disciplina saber impartido"], nameOffset: 1 }
      : { category: "TALLER_CASA_CULTURA", nameAliases: ["disciplina saber impartido"], nameOffset: 1 };
  }
  if (current.includes("tema") && current.includes("ponente")) {
    return { category: "CAPACITACION_PROMOTORES", nameAliases: ["tema"], nameOffset: 1 };
  }
  if (current.includes("tematica") && current.includes("sede")) {
    return { category: "REUNION_COLABORACION", nameAliases: ["tematica"], nameOffset: 1 };
  }
  if (current.includes("agrupacion") && current.includes("artista") && current.includes("actividad")) {
    return { category: "INTERCAMBIO_CULTURAL", nameAliases: ["agrupacion artista actividad"], nameOffset: 1 };
  }
  if (current.includes("evento actividad") && current.includes("sede")) {
    return { category: "EVENTO_MUNICIPAL", nameAliases: ["evento actividad"], nameOffset: 0 };
  }
  return null;
}

function inferMunicipality(matrix) {
  for (const row of matrix) {
    const marker = (row ?? []).findIndex((cell) => normalizeImportText(cell) === "municipio");
    if (marker < 0) continue;
    for (let index = marker + 1; index < Math.min(row.length, marker + 7); index += 1) {
      const candidate = asText(row[index]);
      if (candidate && normalizeImportText(candidate) !== "elabora") return candidate;
    }
  }
  return null;
}

function inferYear(fileName, matrices) {
  const fromName = String(fileName ?? "").match(/\b(20\d{2})\b/);
  if (fromName) return Number(fromName[1]);
  for (const matrix of matrices) {
    for (const row of matrix.slice(0, 14)) {
      for (const value of row ?? []) {
        if (value instanceof Date && !Number.isNaN(value.getTime())) return value.getFullYear();
      }
    }
  }
  return new Date().getFullYear();
}

function fallbackMunicipalityFromName(fileName) {
  return asText(String(fileName ?? "").split(/\s+-\s+reporte/i)[0]);
}

function demographicsFromRow(header, row) {
  const groups = [
    { aliases: ["infancias"], key: "ninez" },
    { aliases: ["juventudes"], key: "juventudes" },
    { aliases: ["adultos"], key: "adultos" },
    { aliases: ["ads mayores", "adultos mayores"], key: "adultos_mayores" },
  ];
  const values = {
    mujeres: 0,
    hombres: 0,
    ninez: 0,
    juventudes: 0,
    adultos: 0,
    adultos_mayores: 0,
  };
  for (const group of groups) {
    const index = findColumn(header, group.aliases);
    if (index < 0) continue;
    const women = numberValue(row[index]);
    const men = numberValue(row[index + 1]);
    values[group.key] = women + men;
    values.mujeres += women;
    values.hombres += men;
  }
  return { ...values, total_beneficiarios: values.mujeres + values.hombres };
}

function parseMonthlySheet({ sheetName, matrix, month, year, XLSX }) {
  const rows = [];
  let active = null;
  let contextText = "";
  const fallbackDate = `${year}-${String(month).padStart(2, "0")}-01`;

  for (let index = 0; index < matrix.length; index += 1) {
    const row = matrix[index] ?? [];
    const currentText = rowText(row);
    const detected = findBlock(row, contextText);

    if (detected) {
      active = {
        ...detected,
        header: row,
        headerIndex: index,
        nameIndex: findColumn(row, detected.nameAliases) + detected.nameOffset,
        daysIndex: findColumn(row, ["dias de la semana"]),
        scheduleIndex: findColumn(row, ["horario"]),
        feeIndex: findColumn(row, ["costo o libre acceso"]),
        responsibleIndex: findColumn(row, ["nombre del docente", "ponente"]),
        venueIndex: findColumn(row, ["sede lugar donde se llevo a cabo", "sede"]),
        typeIndex: findColumn(row, ["tipo"]),
        dateIndex: findColumn(row, ["fecha"]),
        eventIndex: findColumn(row, ["evento"]),
      };
      contextText = currentText;
      continue;
    }

    if (currentText) contextText = `${contextText} ${currentText}`.slice(-600);
    if (!active || index <= active.headerIndex) continue;

    if (currentText.startsWith("total de") || currentText.includes("total eventos del municipio")) {
      active = null;
      continue;
    }

    const name = asText(row[active.nameIndex]);
    if (!name || /^\d+$/.test(name) || normalizeImportText(name).startsWith("total ")) continue;

    const demographics = demographicsFromRow(active.header, row);
    const date = excelDateToISO(row[active.dateIndex], XLSX, fallbackDate);
    const venue = active.venueIndex >= 0 ? asText(row[active.venueIndex]) : "";
    const responsible = active.responsibleIndex >= 0 ? asText(row[active.responsibleIndex]) : "";
    const event = active.eventIndex >= 0 ? asText(row[active.eventIndex]) : "";
    const type = active.typeIndex >= 0 ? asText(row[active.typeIndex]) : "";

    rows.push({
      category: active.category,
      categoryLabel: SMART_CATEGORY_LABELS[active.category],
      sheet: sheetName,
      excelRow: index + 1,
      month,
      year,
      name,
      date,
      venue,
      responsible,
      days: active.daysIndex >= 0 ? asText(row[active.daysIndex]) : "",
      schedule: active.scheduleIndex >= 0 ? asText(row[active.scheduleIndex]) : "",
      fee: active.feeIndex >= 0 ? asText(row[active.feeIndex]) : "",
      type,
      event,
      description: [SMART_CATEGORY_LABELS[active.category], event, type, `Reporte mensual ${sheetName} ${year}`]
        .filter(Boolean)
        .join(" · "),
      ...demographics,
      raw: row,
    });
  }
  return rows;
}

export function parseInstitutionalCdcmWorkbook(workbook, fileName, XLSX) {
  const monthlySheets = [];
  for (const name of workbook?.SheetNames ?? []) {
    const month = MONTHS.get(String(name).trim().toUpperCase());
    if (!month) continue;
    const matrix = XLSX.utils.sheet_to_json(workbook.Sheets[name], {
      header: 1,
      defval: null,
      raw: true,
      blankrows: true,
    });
    const signature = normalizeImportText(matrix.slice(0, 20).flat().join(" "));
    if (!signature.includes("informe concentrado de actividades") || !signature.includes("cdcm")) continue;
    monthlySheets.push({ name, month, matrix });
  }

  if (!monthlySheets.length) return { recognized: false, rows: [] };

  const year = inferYear(fileName, monthlySheets.map((item) => item.matrix));
  const municipalityName = monthlySheets
    .map((item) => inferMunicipality(item.matrix))
    .find(Boolean) || fallbackMunicipalityFromName(fileName);
  const rows = monthlySheets.flatMap((item) => parseMonthlySheet({
    sheetName: item.name,
    matrix: item.matrix,
    month: item.month,
    year,
    XLSX,
  }));
  const categories = Object.entries(rows.reduce((accumulator, row) => {
    accumulator[row.category] = (accumulator[row.category] ?? 0) + 1;
    return accumulator;
  }, {})).map(([key, count]) => ({ key, label: SMART_CATEGORY_LABELS[key], count }));

  return {
    recognized: true,
    profile: "REPORTE_CDCM_MENSUAL",
    label: "Reporte mensual institucional CDCM",
    municipalityName,
    year,
    sheets: monthlySheets.map((item) => item.name),
    rows,
    categories,
  };
}
