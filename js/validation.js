/**
 * VINCULACIÓN CULTURAL 2.0
 * validation.js
 *
 * Fase 5 — Bandeja institucional de validación.
 */

import { dbV2 } from "./supabase-client.js";

import {
  loadOperationalUnits,
  loadMunicipalities,
} from "./catalogs.js";

import {
  createEvidenceSignedUrl,
} from "./evidence.js";

const PAGE_SIZE = 20;

let context = null;
let initialized = false;

let state = {
  page: 0,
  total: 0,
  rows: [],
  detail: null,
};

const ui = {};
const $ = (id) => document.getElementById(id);


function formatDate(value) {
  if (!value) return "—";

  const date = new Date(
    `${value}T12:00:00`
  );

  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return new Intl.DateTimeFormat(
    "es-MX",
    {
      year: "numeric",
      month: "short",
      day: "2-digit",
    }
  ).format(date);
}


function formatDateTime(value) {
  if (!value) return "—";

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return new Intl.DateTimeFormat(
    "es-MX",
    {
      dateStyle: "medium",
      timeStyle: "short",
    }
  ).format(date);
}


function numberText(value) {
  if (
    value === null ||
    value === undefined
  ) {
    return "—";
  }

  return Number(value)
    .toLocaleString("es-MX");
}


function fillSelect(
  element,
  rows,
  {
    placeholder,
    valueKey = "id",
    labelKey = "nombre",
  }
) {
  element.replaceChildren();

  const empty =
    document.createElement("option");

  empty.value = "";
  empty.textContent = placeholder;

  element.appendChild(empty);

  for (const row of rows) {
    const option =
      document.createElement("option");

    option.value =
      row[valueKey];

    option.textContent =
      row[labelKey];

    element.appendChild(option);
  }
}


function setLoading(loading) {
  ui.refresh.disabled = loading;
  ui.refresh.textContent =
    loading
      ? "Cargando..."
      : "Actualizar";
}


function renderEmpty(message) {
  ui.body.replaceChildren();

  const tr =
    document.createElement("tr");

  const td =
    document.createElement("td");

  td.colSpan = 8;
  td.className =
    "validation-empty";

  td.textContent = message;

  tr.appendChild(td);
  ui.body.appendChild(tr);
}


function queueBadge(days) {
  const badge =
    document.createElement("span");

  badge.className =
    days >= 3
      ? "validation-age validation-age-old"
      : "validation-age";

  badge.textContent =
    days === 0
      ? "Hoy"
      : `${days} día(s)`;

  return badge;
}


function renderRows(rows) {
  ui.body.replaceChildren();

  if (!rows.length) {
    renderEmpty(
      "No hay registros EN REVISIÓN con estos filtros."
    );
    return;
  }

  for (const row of rows) {
    const tr =
      document.createElement("tr");

    const folioTd =
      document.createElement("td");

    const folio =
      document.createElement("strong");

    folio.className =
      "validation-folio";

    folio.textContent =
      row.folio ?? "—";

    const type =
      document.createElement("small");

    type.textContent =
      row.tipo_registro_nombre ??
      row.tipo_pendiente ??
      "Registro";

    folioTd.append(
      folio,
      type
    );

    const dateTd =
      document.createElement("td");

    dateTd.textContent =
      formatDate(
        row.fecha_inicio
      );

    const territoryTd =
      document.createElement("td");

    const municipality =
      document.createElement("strong");

    municipality.textContent =
      row.municipio_nombre ??
      "Sin municipio";

    const region =
      document.createElement("small");

    region.textContent =
      row.region_nombre ??
      "—";

    territoryTd.append(
      municipality,
      region
    );

    const activityTd =
      document.createElement("td");

    const activity =
      document.createElement("strong");

    activity.textContent =
      row.nombre ??
      "Sin nombre";

    const action =
      document.createElement("small");

    action.textContent =
      `${row.accion_clave ?? "—"} · ${row.accion_nombre ?? "—"}`;

    activityTd.append(
      activity,
      action
    );

    const programTd =
      document.createElement("td");

    const unit =
      document.createElement("strong");

    unit.textContent =
      row.unidad_nombre ??
      row.unidad_clave ??
      "—";

    const program =
      document.createElement("small");

    program.textContent =
      row.programa_nombre ??
      "Sin programa";

    programTd.append(
      unit,
      program
    );

    const beneficiariesTd =
      document.createElement("td");

    beneficiariesTd.className =
      "validation-number";

    beneficiariesTd.textContent =
      numberText(
        row.total_beneficiarios
      );

    const ageTd =
      document.createElement("td");

    ageTd.appendChild(
      queueBadge(
        Number(
          row.dias_sin_movimiento ??
          0
        )
      )
    );

    const actionTd =
      document.createElement("td");

    const reviewButton =
      document.createElement("button");

    reviewButton.type = "button";

    reviewButton.className =
      "validation-review-button";

    reviewButton.textContent =
      "Revisar";

    reviewButton.addEventListener(
      "click",
      () =>
        openValidation(
          row.id
        )
    );

    actionTd.appendChild(
      reviewButton
    );

    tr.append(
      folioTd,
      dateTd,
      territoryTd,
      activityTd,
      programTd,
      beneficiariesTd,
      ageTd,
      actionTd
    );

    ui.body.appendChild(tr);
  }
}


function renderPagination() {
  const start =
    state.total === 0
      ? 0
      : state.page *
          PAGE_SIZE +
        1;

  const end =
    Math.min(
      state.total,
      (state.page + 1) *
        PAGE_SIZE
    );

  ui.range.textContent =
    `${start}-${end} de ${state.total}`;

  ui.prev.disabled =
    state.page <= 0;

  ui.next.disabled =
    (state.page + 1) *
      PAGE_SIZE >=
    state.total;
}


function getFilters() {
  return {
    search:
      ui.search.value.trim(),

    unitId:
      ui.unit.value,

    municipalityId:
      ui.municipality.value,

    year:
      ui.year.value,
  };
}


async function fetchQueue() {
  const filters =
    getFilters();

  let query = dbV2()
    .from(
      "vw_pendientes_validacion"
    )
    .select(
      [
        "id",
        "folio",
        "unidad_operativa_id",
        "unidad_clave",
        "unidad_nombre",
        "programa_id",
        "programa_nombre",
        "accion_id",
        "accion_clave",
        "accion_nombre",
        "tipo_registro_nombre",
        "municipio_id",
        "municipio_nombre",
        "region_nombre",
        "nombre",
        "fecha_inicio",
        "periodo_anio",
        "total_beneficiarios",
        "estatus",
        "row_version",
        "updated_at",
        "dias_sin_movimiento",
        "tipo_pendiente",
      ].join(","),
      {
        count: "exact",
      }
    )
    .eq(
      "estatus",
      "EN_REVISION"
    );

  if (filters.search) {
    const safe =
      filters.search
        .replaceAll(",", " ")
        .replaceAll("(", " ")
        .replaceAll(")", " ")
        .trim();

    if (safe) {
      query = query.or(
        [
          `folio.ilike.%${safe}%`,
          `nombre.ilike.%${safe}%`,
          `accion_nombre.ilike.%${safe}%`,
          `municipio_nombre.ilike.%${safe}%`,
        ].join(",")
      );
    }
  }

  if (filters.unitId) {
    query = query.eq(
      "unidad_operativa_id",
      filters.unitId
    );
  }

  if (filters.municipalityId) {
    query = query.eq(
      "municipio_id",
      filters.municipalityId
    );
  }

  if (filters.year) {
    query = query.eq(
      "periodo_anio",
      Number(
        filters.year
      )
    );
  }

  const from =
    state.page * PAGE_SIZE;

  const to =
    from + PAGE_SIZE - 1;

  const {
    data,
    error,
    count,
  } = await query
    .order(
      "updated_at",
      {
        ascending: true,
      }
    )
    .range(
      from,
      to
    );

  if (error) {
    throw error;
  }

  state.rows =
    data ?? [];

  state.total =
    count ?? 0;

  renderRows(
    state.rows
  );

  renderPagination();

  ui.kpiPending.textContent =
    state.total
      .toLocaleString("es-MX");

  ui.kpiOld.textContent =
    state.rows
      .filter(
        (row) =>
          Number(
            row.dias_sin_movimiento ??
            0
          ) >= 3
      )
      .length
      .toLocaleString("es-MX");

  ui.kpiMunicipalities.textContent =
    new Set(
      state.rows
        .map(
          (row) =>
            row.municipio_id
        )
        .filter(Boolean)
    )
      .size
      .toLocaleString(
        "es-MX"
      );
}


async function refreshQueue() {
  setLoading(true);

  try {
    await fetchQueue();
  } catch (error) {
    console.error(
      "Bandeja de Validación:",
      error
    );

    renderEmpty(
      `No se pudo cargar la bandeja: ${
        error?.message ??
        "error desconocido"
      }`
    );
  } finally {
    setLoading(false);
    renderPagination();
  }
}


function addDetailItem(
  container,
  label,
  value
) {
  const item =
    document.createElement("div");

  item.className =
    "validation-detail-item";

  const key =
    document.createElement("strong");

  key.textContent = label;

  const content =
    document.createElement("span");

  content.textContent =
    String(
      value ?? "—"
    ).trim() || "—";

  item.append(
    key,
    content
  );

  container.appendChild(item);
}


function renderDemography(rows) {
  ui.detailDemography
    .replaceChildren();

  if (!rows?.length) {
    ui.detailDemography.textContent =
      "Sin desagregación registrada.";
    return;
  }

  const grouped = new Map();

  for (const row of rows) {
    const universe =
      row.universo ?? "OTRO";

    const dimension =
      row.dimension_nombre ??
      "Otra dimensión";

    const key =
      `${universe}|${dimension}`;

    if (!grouped.has(key)) {
      grouped.set(
        key,
        {
          universe,
          dimension,
          rows: [],
        }
      );
    }

    grouped
      .get(key)
      .rows.push(row);
  }

  for (const group of grouped.values()) {
    const block =
      document.createElement("div");

    block.className =
      "validation-demo-block";

    const title =
      document.createElement("strong");

    title.textContent =
      `${group.universe} · ${group.dimension}`;

    const chips =
      document.createElement("div");

    chips.className =
      "validation-demo-chips";

    for (const row of group.rows) {
      const chip =
        document.createElement("span");

      chip.textContent =
        `${row.opcion_nombre}: ${numberText(row.cantidad)}`;

      chips.appendChild(chip);
    }

    block.append(
      title,
      chips
    );

    ui.detailDemography
      .appendChild(block);
  }
}


function renderHistory(rows) {
  ui.detailHistory
    .replaceChildren();

  if (!rows?.length) {
    ui.detailHistory.textContent =
      "Sin historial.";
    return;
  }

  for (const row of rows) {
    const item =
      document.createElement("div");

    item.className =
      "validation-history-item";

    const head =
      document.createElement("div");

    const transition =
      document.createElement("strong");

    transition.textContent =
      `${row.estatus_anterior ?? "INICIO"} → ${row.estatus_nuevo}`;

    const date =
      document.createElement("span");

    date.textContent =
      formatDateTime(
        row.created_at
      );

    head.append(
      transition,
      date
    );

    const user =
      document.createElement("small");

    user.textContent =
      row.usuario_nombre ||
      row.usuario_email ||
      "Sistema / usuario";

    item.append(
      head,
      user
    );

    if (row.observacion) {
      const observation =
        document.createElement("p");

      observation.textContent =
        row.observacion;

      item.appendChild(
        observation
      );
    }

    ui.detailHistory
      .appendChild(item);
  }
}


function renderIndicators(rows) {
  ui.detailIndicators
    .replaceChildren();

  if (!rows?.length) {
    ui.detailIndicators.textContent =
      "La acción no tiene una regla automática de indicador configurada para este ejercicio.";
    return;
  }

  for (const row of rows) {
    const item =
      document.createElement("div");

    item.className =
      "validation-indicator";

    const title =
      document.createElement("strong");

    title.textContent =
      `${row.clave} · ${row.nombre}`;

    const meta =
      document.createElement("small");

    meta.textContent =
      [
        row.regla_aporte,
        row.requiere_validado
          ? "requiere VALIDADO"
          : "no requiere VALIDADO",
        row.valor_estimado !== null &&
        row.valor_estimado !== undefined
          ? `aporte estimado: ${row.valor_estimado}`
          : null,
      ]
        .filter(Boolean)
        .join(" · ");

    item.append(
      title,
      meta
    );

    ui.detailIndicators
      .appendChild(item);
  }
}


function renderEvidences(rows) {
  ui.detailEvidence
    .replaceChildren();

  if (!rows?.length) {
    ui.detailEvidence.textContent =
      "Sin evidencia activa.";
    return;
  }

  for (const row of rows) {
    const item =
      document.createElement("div");

    item.className =
      "validation-evidence-item";

    const copy =
      document.createElement("div");

    const name =
      document.createElement("strong");

    name.textContent =
      row.nombre_original ??
      row.tipo_evidencia ??
      "Evidencia";

    const meta =
      document.createElement("small");

    meta.textContent =
      [
        row.mime_type,
        row.size_bytes
          ? `${Math.ceil(Number(row.size_bytes) / 1024)} KB`
          : null,
      ]
        .filter(Boolean)
        .join(" · ");

    copy.append(
      name,
      meta
    );

    const open =
      document.createElement("button");

    open.type =
      "button";

    open.className =
      "btn-secondary";

    open.textContent =
      "Abrir";

    open.addEventListener(
      "click",
      async () => {
        try {
          const url =
            await createEvidenceSignedUrl(
              row.storage_path,
              120
            );

          if (!url) {
            throw new Error(
              "No se obtuvo URL temporal."
            );
          }

          window.open(
            url,
            "_blank",
            "noopener,noreferrer"
          );

        } catch (error) {
          await Swal.fire({
            icon: "error",
            title:
              "No se pudo abrir la evidencia",
            text:
              error?.message ??
              "Error de Storage.",
          });
        }
      }
    );

    item.append(
      copy,
      open
    );

    ui.detailEvidence
      .appendChild(item);
  }
}


function renderQuality(data) {
  const issues =
    data.calidad
      ?.incidencias ?? [];

  ui.qualityBox
    .replaceChildren();

  if (!issues.length) {
    ui.qualityBox.className =
      "validation-quality validation-quality-ok";

    ui.qualityBox.textContent =
      "✓ Sin incidencias estructurales pendientes.";
    return;
  }

  ui.qualityBox.className =
    "validation-quality validation-quality-warn";

  ui.qualityBox.textContent =
    `Incidencias: ${issues.join(", ")}`;
}


function renderDetail(data) {
  state.detail = data;

  ui.detailTitle.textContent =
    data.record.folio ??
    "Revisión V2";

  ui.detailSubtitle.textContent =
    [
      data.record.accion_clave,
      data.record.accion_nombre,
    ]
      .filter(Boolean)
      .join(" · ");

  ui.detailCore
    .replaceChildren();

  addDetailItem(
    ui.detailCore,
    "Actividad",
    data.record.nombre
  );

  addDetailItem(
    ui.detailCore,
    "Fecha",
    `${formatDate(data.record.fecha_inicio)} – ${formatDate(data.record.fecha_fin)}`
  );

  addDetailItem(
    ui.detailCore,
    "Unidad",
    data.record.unidad_nombre
  );

  addDetailItem(
    ui.detailCore,
    "Programa",
    data.record.programa_nombre
  );

  addDetailItem(
    ui.detailCore,
    "Municipio",
    data.record.municipio_nombre
  );

  addDetailItem(
    ui.detailCore,
    "Región",
    data.record.region_nombre
  );

  addDetailItem(
    ui.detailCore,
    "Espacio",
    data.record.espacio_nombre
  );

  addDetailItem(
    ui.detailCore,
    "Tipo",
    data.record.tipo_registro
  );

  addDetailItem(
    ui.detailCore,
    "Beneficiarios",
    numberText(
      data.record.total_beneficiarios
    )
  );

  addDetailItem(
    ui.detailCore,
    "Participantes",
    numberText(
      data.record.total_participantes
    )
  );

  addDetailItem(
    ui.detailCore,
    "Accesos",
    numberText(
      data.record.total_accesos
    )
  );

  addDetailItem(
    ui.detailCore,
    "Responsable",
    data.responsable
      ? [
          data.responsable.nombre,
          data.responsable.correo,
        ]
          .filter(Boolean)
          .join(" · ")
      : "Sin responsable"
  );

  ui.detailDescription.textContent =
    data.record.descripcion ||
    "Sin descripción adicional.";

  ui.detailWorkshop.hidden =
    !data.taller;

  if (data.taller) {
    ui.detailWorkshop.textContent =
      [
        data.taller.disciplina,
        data.taller.programacion,
        data.taller.modalidad_cuota,
        data.taller.costo !== null &&
        data.taller.costo !== undefined
          ? `$${data.taller.costo} MXN`
          : null,
        data.taller.observaciones,
      ]
        .filter(Boolean)
        .join(" · ");
  }

  renderDemography(
    data.demografia
  );

  renderEvidences(
    data.evidencias
  );

  renderHistory(
    data.historial
  );

  renderIndicators(
    data.indicadores
  );

  renderQuality(data);

  ui.observation.value = "";

  const canDecide =
    data.permissions
      ?.can_decide === true;

  ui.observe.disabled =
    !canDecide;

  ui.validate.disabled =
    !canDecide;
}


async function openValidation(
  recordId
) {
  ui.detailOverlay.hidden =
    false;

  document.body.style.overflow =
    "hidden";

  ui.detailTitle.textContent =
    "Cargando expediente...";

  try {
    const {
      data,
      error,
    } = await dbV2()
      .rpc(
        "rpc_get_registro_validacion",
        {
          p_registro_id:
            recordId,
        }
      )
      .single();

    if (error) {
      throw error;
    }

    const payload =
      data?.payload;

    if (!payload) {
      throw new Error(
        "El servidor no devolvió el expediente."
      );
    }

    renderDetail(
      payload
    );

  } catch (error) {
    console.error(
      "Detalle de validación:",
      error
    );

    await Swal.fire({
      icon: "error",
      title:
        "No se pudo abrir el expediente",
      text:
        error?.message ??
        "Error de Data API.",
    });

    closeDetail();
  }
}


function closeDetail() {
  ui.detailOverlay.hidden =
    true;

  document.body.style.overflow =
    "";

  state.detail = null;
}


async function decide(
  decision
) {
  const data =
    state.detail;

  if (!data?.record?.id) {
    return;
  }

  const observation =
    ui.observation
      .value.trim();

  if (
    decision === "OBSERVAR" &&
    observation.length < 10
  ) {
    await Swal.fire({
      icon: "warning",
      title:
        "Describe la observación",
      text:
        "Indica claramente qué debe corregirse (mínimo 10 caracteres).",
    });

    ui.observation.focus();
    return;
  }

  const confirmation =
    await Swal.fire({
      icon:
        decision === "VALIDAR"
          ? "question"
          : "warning",

      title:
        decision === "VALIDAR"
          ? "¿Validar este registro?"
          : "¿Enviar observación?",

      text:
        decision === "VALIDAR"
          ? "Al quedar VALIDADO podrá aportar a los indicadores que requieren validación."
          : "El capturista verá esta observación y deberá corregir el expediente.",

      showCancelButton: true,

      confirmButtonText:
        decision === "VALIDAR"
          ? "Sí, validar"
          : "Sí, observar",

      cancelButtonText:
        "Cancelar",
    });

  if (!confirmation.isConfirmed) {
    return;
  }

  ui.observe.disabled = true;
  ui.validate.disabled = true;

  try {
    const {
      data: result,
      error,
    } = await dbV2()
      .rpc(
        "rpc_decide_validacion",
        {
          p_registro_id:
            data.record.id,

          p_expected_row_version:
            data.record.row_version,

          p_decision:
            decision,

          p_observacion:
            observation || null,
        }
      )
      .single();

    if (error) {
      throw error;
    }

    await Swal.fire({
      icon: "success",
      title:
        result.estatus === "VALIDADO"
          ? "Registro validado"
          : "Registro observado",

      text:
        result.estatus === "VALIDADO"
          ? `${result.folio} quedó VALIDADO.`
          : `${result.folio} quedó OBSERVADO y regresará al flujo de corrección.`,
    });

    closeDetail();

    await refreshQueue();

    window.dispatchEvent(
      new CustomEvent(
        "v2:record-updated",
        {
          detail: {
            id:
              data.record.id,
          },
        }
      )
    );

  } catch (error) {
    console.error(
      "Decisión de validación:",
      error
    );

    await Swal.fire({
      icon: "error",
      title:
        "No se pudo registrar la decisión",
      text:
        error?.message ??
        "Error del servidor.",
    });

    ui.observe.disabled = false;
    ui.validate.disabled = false;
  }
}


function debounce(
  fn,
  wait = 350
) {
  let timer = null;

  return (...args) => {
    clearTimeout(timer);

    timer =
      setTimeout(
        () => fn(...args),
        wait
      );
  };
}


function filtersChanged() {
  state.page = 0;
  refreshQueue();
}


async function populateFilters() {
  const [
    units,
    municipalities,
  ] = await Promise.all([
    loadOperationalUnits(
      context
    ),

    loadMunicipalities(
      context
    ),
  ]);

  fillSelect(
    ui.unit,
    units,
    {
      placeholder:
        "Todas las unidades",
      labelKey:
        "nombre",
    }
  );

  fillSelect(
    ui.municipality,
    municipalities,
    {
      placeholder:
        "Todos los municipios",
      labelKey:
        "nombre_oficial",
    }
  );

  const currentYear =
    new Date().getFullYear();

  const years = [];

  for (
    let year = currentYear;
    year >= 2025;
    year -= 1
  ) {
    years.push({
      id:
        String(year),
      nombre:
        String(year),
    });
  }

  fillSelect(
    ui.year,
    years,
    {
      placeholder:
        "Todos los años",
    }
  );

  ui.year.value =
    String(
      currentYear
    );
}


export async function initValidationV2(
  authContext
) {
  context =
    authContext;

  Object.assign(
    ui,
    {
      search:
        $("validationSearch"),

      unit:
        $("validationUnit"),

      municipality:
        $("validationMunicipality"),

      year:
        $("validationYear"),

      refresh:
        $("validationRefresh"),

      body:
        $("validationBody"),

      prev:
        $("validationPrev"),

      next:
        $("validationNext"),

      range:
        $("validationRange"),

      kpiPending:
        $("validationKpiPending"),

      kpiOld:
        $("validationKpiOld"),

      kpiMunicipalities:
        $("validationKpiMunicipalities"),

      detailOverlay:
        $("validationDetailOverlay"),

      detailClose:
        $("validationDetailClose"),

      detailTitle:
        $("validationDetailTitle"),

      detailSubtitle:
        $("validationDetailSubtitle"),

      detailCore:
        $("validationDetailCore"),

      detailDescription:
        $("validationDetailDescription"),

      detailWorkshop:
        $("validationDetailWorkshop"),

      detailDemography:
        $("validationDetailDemography"),

      detailEvidence:
        $("validationDetailEvidence"),

      detailHistory:
        $("validationDetailHistory"),

      detailIndicators:
        $("validationDetailIndicators"),

      qualityBox:
        $("validationQualityBox"),

      observation:
        $("validationObservation"),

      observe:
        $("validationObserve"),

      validate:
        $("validationValidate"),
    }
  );

  if (!ui.body) {
    throw new Error(
      "VALIDATION_V2_UI_NOT_FOUND"
    );
  }

  if (!initialized) {
    const searchChanged =
      debounce(
        filtersChanged
      );

    ui.search.addEventListener(
      "input",
      searchChanged
    );

    [
      ui.unit,
      ui.municipality,
      ui.year,
    ].forEach(
      (element) => {
        element.addEventListener(
          "change",
          filtersChanged
        );
      }
    );

    ui.refresh.addEventListener(
      "click",
      refreshQueue
    );

    ui.prev.addEventListener(
      "click",
      () => {
        if (state.page <= 0) {
          return;
        }

        state.page -= 1;
        refreshQueue();
      }
    );

    ui.next.addEventListener(
      "click",
      () => {
        if (
          (state.page + 1) *
            PAGE_SIZE >=
          state.total
        ) {
          return;
        }

        state.page += 1;
        refreshQueue();
      }
    );

    ui.detailClose.addEventListener(
      "click",
      closeDetail
    );

    ui.detailOverlay
      .addEventListener(
        "click",
        (event) => {
          if (
            event.target ===
            ui.detailOverlay
          ) {
            closeDetail();
          }
        }
      );

    ui.observe.addEventListener(
      "click",
      () =>
        decide(
          "OBSERVAR"
        )
    );

    ui.validate.addEventListener(
      "click",
      () =>
        decide(
          "VALIDAR"
        )
    );

    window.addEventListener(
      "v2:record-updated",
      () => {
        refreshQueue();
      }
    );

    initialized = true;
  }

  await populateFilters();

  state.page = 0;

  await refreshQueue();
}
