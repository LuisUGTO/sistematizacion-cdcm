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
  ACTIVIDAD_PROYECTO_CIRCUITO: ["ACTIVIDAD_PROYECTO_CIRCUITO", "PB3563_2602"],
  ACTIVIDAD_PROYECTO_REGIONAL: ["ACTIVIDAD_PROYECTO_REGIONAL", "PB3563_2602"],
  INTERCAMBIO_CULTURAL: ["INTERCAMBIO_CULTURAL", "PB3563_2602"],
  ARTICULACION_INTER_INTRA: ["ARTICULACION_INTER_INTRA", "PB3563_2602"],
  PROYECTO_SOCIOCULTURAL: ["PROYECTO_SOCIOCULTURAL", "PB3564_2601", "PB3564_2602", "PB3563_2602"],
  EXPOSICION_MUESTRA: ["EXPOSICION_MUESTRA", "EVENTO_MUNICIPAL", "PB3563_2602"],
  ACTIVIDAD_VIRTUAL: ["EVENTO_MUNICIPAL", "PB3563_2602"],
  EVENTO_MUNICIPAL: ["EVENTO_MUNICIPAL", "PB3563_2602"],
};

export const SMART_CATEGORY_LABELS = {
  TALLER_CASA_CULTURA: "Talleres en Casa de Cultura",
  TALLER_SALON_CULTURA: "Salones culturales",
  CAPACITACION_PROMOTORES: "Capacitaciones",
  REUNION_COLABORACION: "Reuniones de colaboración",
  ACTIVIDAD_PROYECTO_CIRCUITO: "Actividades de proyecto de circuito",
  ACTIVIDAD_PROYECTO_REGIONAL: "Actividades de proyecto regional",
  INTERCAMBIO_CULTURAL: "Intercambios culturales",
  ARTICULACION_INTER_INTRA: "Articulación inter e intrainstitucional",
  PROYECTO_SOCIOCULTURAL: "Proyectos socioculturales",
  EXPOSICION_MUESTRA: "Exposiciones municipales",
  ACTIVIDAD_VIRTUAL: "Actividades virtuales",
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

function fixedDemographics(row, startIndex = 6) {
  const values = {
    mujeres: 0,
    hombres: 0,
    ninez: 0,
    juventudes: 0,
    adultos: 0,
    adultos_mayores: 0,
  };
  const keys = ["ninez", "juventudes", "adultos", "adultos_mayores"];
  keys.forEach((key, offset) => {
    const women = numberValue(row[startIndex + (offset * 2)]);
    const men = numberValue(row[startIndex + (offset * 2) + 1]);
    values[key] = women + men;
    values.mujeres += women;
    values.hombres += men;
  });
  return values;
}

function meaningfulName(value) {
  const text = asText(value);
  const normalized = normalizeImportText(text);
  if (!text || /^\d+(?:\.0)?$/.test(text)) return "";
  if (["elegir uno", "actividad", "tipo", "programa", "total"].includes(normalized)) return "";
  return text;
}

function doloresSection(row) {
  const text = rowText(row);
  if (text.includes("actividades de promocion cultural")) {
    return { reset: true };
  }
  if (text.includes("procesos de formacion capacitaciones")) {
    return { category: "CAPACITACION_PROMOTORES", nameIndexes: [1], venueIndexes: [3], dateIndex: 4 };
  }
  if (text.includes("reuniones circuito") || text.includes("reuniones circuito y o regionales")) {
    return { category: "REUNION_COLABORACION", nameIndexes: [1], venueIndexes: [3, 4] };
  }
  if (text.includes("proyecto de circuito cultural")) {
    return { category: "ACTIVIDAD_PROYECTO_CIRCUITO", nameIndexes: [1], venueIndexes: [4, 3] };
  }
  if (text.includes("proyecto regional")) {
    return { category: "ACTIVIDAD_PROYECTO_REGIONAL", nameIndexes: [1], venueIndexes: [4, 3] };
  }
  if (text.includes("intercambios culturales")) {
    return { category: "INTERCAMBIO_CULTURAL", nameIndexes: [1], venueIndexes: [4] };
  }
  if (text.includes("articulacion inter e intra")) {
    return { category: "ARTICULACION_INTER_INTRA", nameIndexes: [2, 1], venueIndexes: [4, 3] };
  }
  if (text.includes("actividades de proyectos socioculturales")) {
    return { category: "PROYECTO_SOCIOCULTURAL", nameIndexes: [1], venueIndexes: [4] };
  }
  if (text.includes("actividades virtuales")) {
    return { category: "ACTIVIDAD_VIRTUAL", nameIndexes: [1], venueIndexes: [4] };
  }
  if (text.includes("exposiciones municipales")) {
    return { category: "EXPOSICION_MUESTRA", nameIndexes: [1], venueIndexes: [4] };
  }
  if (text.includes("eventos municipales")) {
    return { category: "EVENTO_MUNICIPAL", nameIndexes: [1], venueIndexes: [4] };
  }
  return null;
}

function parseDoloresMonthlySheet({ sheetName, matrix, month, year, XLSX }) {
  const rows = [];
  let active = null;
  const fallbackDate = `${year}-${String(month).padStart(2, "0")}-01`;

  for (let index = 0; index < matrix.length; index += 1) {
    const row = matrix[index] ?? [];
    const detected = doloresSection(row);
    if (detected) {
      active = detected.reset ? null : detected;
      continue;
    }
    if (!active) continue;

    const currentText = rowText(row);
    if (currentText.startsWith("total") || currentText === "totales") {
      active = null;
      continue;
    }

    const name = active.nameIndexes
      .map((column) => meaningfulName(row[column]))
      .find(Boolean) ?? "";
    const total = numberValue(row[5]);
    if (!name || total <= 0) continue;

    const demographicValues = fixedDemographics(row);
    const demographicTotal = demographicValues.mujeres + demographicValues.hombres;
    const venue = active.venueIndexes
      .map((column) => asText(row[column]))
      .find(Boolean) ?? "";
    const date = excelDateToISO(row[active.dateIndex], XLSX, fallbackDate);

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
      responsible: "",
      days: "",
      schedule: "",
      fee: "",
      type: "",
      event: "",
      description: `${SMART_CATEGORY_LABELS[active.category]} · Reporte mensual ${sheetName} ${year}`,
      ...demographicValues,
      total_beneficiarios: total || demographicTotal,
      raw: row,
    });
  }
  return rows;
}

function parseDoloresWorkshopBreakdown(workbook, year, XLSX) {
  const sheetName = (workbook?.SheetNames ?? []).find((name) =>
    normalizeImportText(name).includes("desglose") && normalizeImportText(name).includes("tall")
  );
  if (!sheetName) return [];

  const matrix = XLSX.utils.sheet_to_json(workbook.Sheets[sheetName], {
    header: 1,
    defval: null,
    raw: true,
    blankrows: true,
  });
  const rows = [];
  let context = "";

  for (let index = 0; index < matrix.length; index += 1) {
    const row = matrix[index] ?? [];
    const text = rowText(row);
    if (text.includes("talleres en casa de cultura")) context = "TALLER_CASA_CULTURA";
    if (text.includes("salones de cultura descentralizados")) context = "TALLER_SALON_CULTURA";
    if (text.includes("talleres de verano")) context = "TALLER_CASA_CULTURA";
    if (!text.includes("disciplina saber impartido") || !context) continue;

    const monthRowIndex = [index + 1, index + 2, index + 3]
      .find((candidate) => (matrix[candidate] ?? []).some((value) => MONTHS.has(asText(value).toUpperCase())));
    if (monthRowIndex === undefined) continue;
    const monthRow = matrix[monthRowIndex] ?? [];
    const monthColumns = monthRow
      .map((value, column) => ({ column, month: MONTHS.get(asText(value).toUpperCase()) }))
      .filter((item) => item.month && item.column >= 12)
      .slice(0, 12);

    for (let dataIndex = monthRowIndex + 1; dataIndex < matrix.length; dataIndex += 1) {
      const dataRow = matrix[dataIndex] ?? [];
      const dataText = rowText(dataRow);
      if (dataText.startsWith("total de talleres")) {
        index = dataIndex;
        break;
      }
      const name = meaningfulName(dataRow[0]);
      if (!name) continue;

      for (const item of monthColumns) {
        const total = numberValue(dataRow[item.column]);
        if (total <= 0) continue;
        const monthLabel = [...MONTHS.entries()].find(([, value]) => value === item.month)?.[0] ?? String(item.month);
        const venueOrFee = asText(dataRow[10]);
        rows.push({
          category: context,
          categoryLabel: SMART_CATEGORY_LABELS[context],
          sheet: monthLabel,
          excelRow: dataIndex + 1,
          month: item.month,
          year,
          name,
          date: `${year}-${String(item.month).padStart(2, "0")}-01`,
          venue: context === "TALLER_SALON_CULTURA" ? venueOrFee : "",
          responsible: asText(dataRow[11]),
          days: dataRow.slice(2, 9).map(asText).filter(Boolean).join(", "),
          schedule: asText(dataRow[9]),
          fee: context === "TALLER_SALON_CULTURA" ? "" : venueOrFee,
          type: asText(dataRow[1]),
          event: "",
          description: `${SMART_CATEGORY_LABELS[context]} · Desglose ${monthLabel} ${year}`,
          mujeres: 0,
          hombres: 0,
          ninez: 0,
          juventudes: 0,
          adultos: 0,
          adultos_mayores: 0,
          total_beneficiarios: total,
          raw: dataRow,
        });
      }
    }
  }
  return rows;
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
  const hasWorkshopBreakdown = (workbook?.SheetNames ?? []).some((name) =>
    normalizeImportText(name).includes("desglose") && normalizeImportText(name).includes("tall")
  );
  const rows = hasWorkshopBreakdown
    ? [
      ...parseDoloresWorkshopBreakdown(workbook, year, XLSX),
      ...monthlySheets.flatMap((item) => parseDoloresMonthlySheet({
        sheetName: item.name,
        matrix: item.matrix,
        month: item.month,
        year,
        XLSX,
      })),
    ]
    : monthlySheets.flatMap((item) => parseMonthlySheet({
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
    profile: hasWorkshopBreakdown ? "REPORTE_CDCM_DESGLOSE_MENSUAL" : "REPORTE_CDCM_MENSUAL",
    label: hasWorkshopBreakdown
      ? "Reporte institucional CDCM con desglose mensual"
      : "Reporte mensual institucional CDCM",
    municipalityName,
    year,
    sheets: monthlySheets.map((item) => item.name),
    rows,
    categories,
  };
}
