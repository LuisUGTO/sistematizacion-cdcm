-- ============================================================================
-- VINCULACION CULTURAL V2
-- 12o_restore_imported_demography.sql
-- Etapa 6.6.1: restauracion idempotente de demografia importada
--
-- Corrige registros IMPORTACION_EXCEL cuya demografia quedo completamente
-- vacia al guardarlos con una version anterior del editor. La fuente de verdad
-- es el payload normalizado que permanece en import_staging.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.registro_poblacion') IS NULL
     OR to_regclass('v2.import_staging') IS NULL
     OR to_regclass('v2.esquema_opciones_poblacion') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION_FALLIDA: faltan las tablas operativas o de importacion V2.';
  END IF;
END
$$;

WITH source_rows AS (
  SELECT
    r.id AS registro_id,
    r.created_by,
    r.esquema_demografico_id,
    demo.value AS item
  FROM v2.registros r
  JOIN v2.import_staging s
    ON s.import_job_id = r.import_job_id
   AND s.numero_fila = r.fila_origen
  CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(
    CASE
      WHEN pg_catalog.jsonb_typeof(
        s.normalized_data #> '{payload,demografia}'
      ) = 'array'
      THEN s.normalized_data #> '{payload,demografia}'
      ELSE '[]'::JSONB
    END
  ) AS demo(value)
  WHERE r.origen = 'IMPORTACION_EXCEL'
    AND r.deleted_at IS NULL
    AND r.estatus <> 'ANULADO'
    AND r.esquema_demografico_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM v2.registro_poblacion current_demo
      WHERE current_demo.registro_id = r.id
    )
),
validated AS (
  SELECT DISTINCT
    source_rows.registro_id,
    (source_rows.item ->> 'opcion_poblacion_id')::UUID
      AS opcion_poblacion_id,
    pg_catalog.upper(source_rows.item ->> 'universo') AS universo,
    (source_rows.item ->> 'cantidad')::INTEGER AS cantidad,
    source_rows.created_by
  FROM source_rows
  JOIN v2.esquema_opciones_poblacion eo
    ON eo.esquema_id = source_rows.esquema_demografico_id
   AND eo.opcion_poblacion_id =
       (source_rows.item ->> 'opcion_poblacion_id')::UUID
   AND eo.activo = true
  WHERE COALESCE(source_rows.item ->> 'opcion_poblacion_id', '') <> ''
    AND COALESCE(source_rows.item ->> 'cantidad', '') ~ '^[0-9]+$'
    AND (source_rows.item ->> 'cantidad')::INTEGER > 0
    AND pg_catalog.upper(source_rows.item ->> 'universo') IN (
      'BENEFICIARIOS', 'PARTICIPANTES', 'ACCESOS'
    )
)
INSERT INTO v2.registro_poblacion (
  registro_id,
  opcion_poblacion_id,
  universo,
  cantidad,
  observaciones,
  created_by
)
SELECT
  validated.registro_id,
  validated.opcion_poblacion_id,
  validated.universo,
  validated.cantidad,
  'Restaurado desde la fuente normalizada de importacion Excel; Etapa 6.6.1.',
  validated.created_by
FROM validated
ON CONFLICT (registro_id, opcion_poblacion_id, universo)
DO NOTHING;

INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12o',
  '12o_restore_imported_demography.sql - Restaura demografia importada vaciada por el editor anterior.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  NOT EXISTS (
    SELECT 1
    FROM v2.registros r
    JOIN v2.import_staging s
      ON s.import_job_id = r.import_job_id
     AND s.numero_fila = r.fila_origen
    WHERE r.origen = 'IMPORTACION_EXCEL'
      AND r.deleted_at IS NULL
      AND r.estatus <> 'ANULADO'
      AND pg_catalog.jsonb_typeof(
        s.normalized_data #> '{payload,demografia}'
      ) = 'array'
      AND pg_catalog.jsonb_array_length(
        s.normalized_data #> '{payload,demografia}'
      ) > 0
      AND NOT EXISTS (
        SELECT 1
        FROM v2.registro_poblacion rp
        WHERE rp.registro_id = r.id
      )
  ) AS demografia_importada_restaurada,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12o')
    AS migracion_registrada;

-- Resultado esperado:
-- true | 1
