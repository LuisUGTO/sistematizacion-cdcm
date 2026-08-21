-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 09c_source_alignment_2026.sql
-- Diagnóstico de alineación del modelo V2 contra la base oficial 2026
-- Secretaría de Cultura de Guanajuato
--
-- ESTE ARCHIVO ES READ-ONLY.
-- NO INSERTA, NO ACTUALIZA, NO BORRA Y NO REGISTRA MIGRACIÓN.
--
-- OBJETIVO:
--   Detectar si el modelo actual puede representar sin pérdida:
--     1) Participación vs Acceso
--     2) Grupo etario 2026
--     3) Género 2026
--     4) Grupos prioritarios 2026
--
-- FUENTE 2026 REVISADA:
--   "base para indicadores oficial"
--
-- DEFINICIONES OBSERVADAS:
--
-- Grupo etario:
--   - Primera infancia (0–5 años)
--   - Niñas y niños (6–12 años)
--   - Adolescencia (13–17 años)
--   - Jóvenes (18–29 años)
--   - Adultos (30–59 años)
--   - Personas adultas mayores (60+)
--   - Intergeneracional
--   - No especificado
--
-- Género:
--   - Mujer
--   - Hombre
--   - No binario
--   - Persona trans
--   - Prefiere no especificar
--   - Público mixto
--
-- Grupos prioritarios:
--   - Personas con discapacidad
--   - Pueblos y comunidades indígenas
--   - Personas afromexicanas
--   - Mujeres en situación de vulnerabilidad
--   - Juventudes en riesgo
--   - Niñas, niños y adolescentes
--   - Personas adultas mayores
--   - Personas migrantes
--   - Personas privadas de la libertad
--
-- Además la fuente distingue:
--   - Número de personas que PARTICIPAN en procesos culturales
--   - Número de personas que ACCEDEN en procesos culturales
--
-- RESULTADO:
--   Un único registro diagnóstico.
-- ============================================================================


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.cat_dimensiones_poblacion') IS NULL
     OR to_regclass('v2.cat_opciones_poblacion') IS NULL
     OR to_regclass('v2.registros') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos V2 requeridos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.09b'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 09b_operational_seed.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. DIAGNÓSTICO
-- ============================================================================

WITH

-- --------------------------------------------------------------------------
-- A. Catálogo oficial 2026: GRUPO ETARIO
-- current_key indica la opción V2 que puede mapearse SIN pérdida semántica.
-- NULL = la opción no existe aún en V2.
-- --------------------------------------------------------------------------
src_etario(
  source_key,
  source_label,
  current_key
) AS (
  VALUES
    (
      'PRIMERA_INFANCIA',
      'Primera infancia (0–5 años)',
      NULL::TEXT
    ),
    (
      'NINAS_NINOS',
      'Niñas y niños (6–12 años)',
      NULL::TEXT
    ),
    (
      'ADOLESCENCIA',
      'Adolescencia (13–17 años)',
      'ADOLESCENCIA'
    ),
    (
      'JOVENES',
      'Jóvenes (18–29 años)',
      'JUVENTUDES'
    ),
    (
      'ADULTOS',
      'Adultos (30–59 años)',
      NULL::TEXT
    ),
    (
      'ADULTOS_MAYORES',
      'Personas adultas mayores (60+)',
      'ADULTOS_MAYORES'
    ),
    (
      'INTERGENERACIONAL',
      'Intergeneracional',
      NULL::TEXT
    ),
    (
      'NO_ESPECIFICADO',
      'No especificado',
      NULL::TEXT
    )
),

-- --------------------------------------------------------------------------
-- B. Catálogo oficial 2026: GÉNERO
-- --------------------------------------------------------------------------
src_genero(
  source_key,
  source_label,
  current_key
) AS (
  VALUES
    ('MUJER', 'Mujer', 'MUJERES'),
    ('HOMBRE', 'Hombre', 'HOMBRES'),
    ('NO_BINARIO', 'No binario', NULL::TEXT),
    ('PERSONA_TRANS', 'Persona trans', NULL::TEXT),
    (
      'PREFIERE_NO_ESPECIFICAR',
      'Prefiere no especificar',
      NULL::TEXT
    ),
    ('PUBLICO_MIXTO', 'Público mixto', NULL::TEXT)
),

-- --------------------------------------------------------------------------
-- C. Catálogo oficial 2026: GRUPOS PRIORITARIOS
-- --------------------------------------------------------------------------
src_prioritario(
  source_key,
  source_label,
  current_key
) AS (
  VALUES
    (
      'DISCAPACIDAD',
      'Personas con discapacidad',
      'DISCAPACIDAD'
    ),
    (
      'PUEBLOS_COMUNIDADES_INDIGENAS',
      'Pueblos y comunidades indígenas',
      'INDIGENAS'
    ),
    (
      'AFROMEXICANAS',
      'Personas afromexicanas',
      'AFROMEXICANAS'
    ),
    (
      'MUJERES_VULNERABILIDAD',
      'Mujeres en situación de vulnerabilidad',
      NULL::TEXT
    ),
    (
      'JUVENTUDES_RIESGO',
      'Juventudes en riesgo',
      NULL::TEXT
    ),
    (
      'NNA',
      'Niñas, niños y adolescentes',
      NULL::TEXT
    ),
    (
      'ADULTOS_MAYORES',
      'Personas adultas mayores',
      NULL::TEXT
    ),
    (
      'MIGRANTES',
      'Personas migrantes',
      NULL::TEXT
    ),
    (
      'PRIVADAS_LIBERTAD',
      'Personas privadas de la libertad',
      NULL::TEXT
    )
),

-- --------------------------------------------------------------------------
-- D. Opciones V2 existentes por dimensión
-- --------------------------------------------------------------------------
v2_options AS (
  SELECT
    upper(btrim(d.clave)) AS dimension_key,
    upper(btrim(o.clave)) AS option_key,
    o.nombre,
    o.activo
  FROM v2.cat_dimensiones_poblacion d
  JOIN v2.cat_opciones_poblacion o
    ON o.dimension_id = d.id
),

-- --------------------------------------------------------------------------
-- E. Estadísticas de compatibilidad etaria
-- --------------------------------------------------------------------------
etario_stats AS (
  SELECT
    count(*)::INTEGER AS source_count,

    count(*) FILTER (
      WHERE s.current_key IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM v2_options v
          WHERE v.dimension_key = 'GRUPO_ETARIO'
            AND v.option_key = upper(s.current_key)
            AND v.activo = true
        )
    )::INTEGER AS mapped_count,

    count(*) FILTER (
      WHERE s.current_key IS NULL
         OR NOT EXISTS (
           SELECT 1
           FROM v2_options v
           WHERE v.dimension_key = 'GRUPO_ETARIO'
             AND v.option_key = upper(s.current_key)
             AND v.activo = true
         )
    )::INTEGER AS missing_count,

    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'clave', s.source_key,
          'nombre', s.source_label
        )
        ORDER BY s.source_key
      ) FILTER (
        WHERE s.current_key IS NULL
           OR NOT EXISTS (
             SELECT 1
             FROM v2_options v
             WHERE v.dimension_key = 'GRUPO_ETARIO'
               AND v.option_key = upper(s.current_key)
               AND v.activo = true
           )
      ),
      '[]'::jsonb
    ) AS missing_options

  FROM src_etario s
),

-- --------------------------------------------------------------------------
-- F. Estadísticas de compatibilidad género
-- --------------------------------------------------------------------------
genero_stats AS (
  SELECT
    count(*)::INTEGER AS source_count,

    count(*) FILTER (
      WHERE s.current_key IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM v2_options v
          WHERE v.dimension_key = 'GENERO'
            AND v.option_key = upper(s.current_key)
            AND v.activo = true
        )
    )::INTEGER AS mapped_count,

    count(*) FILTER (
      WHERE s.current_key IS NULL
         OR NOT EXISTS (
           SELECT 1
           FROM v2_options v
           WHERE v.dimension_key = 'GENERO'
             AND v.option_key = upper(s.current_key)
             AND v.activo = true
         )
    )::INTEGER AS missing_count,

    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'clave', s.source_key,
          'nombre', s.source_label
        )
        ORDER BY s.source_key
      ) FILTER (
        WHERE s.current_key IS NULL
           OR NOT EXISTS (
             SELECT 1
             FROM v2_options v
             WHERE v.dimension_key = 'GENERO'
               AND v.option_key = upper(s.current_key)
               AND v.activo = true
           )
      ),
      '[]'::jsonb
    ) AS missing_options

  FROM src_genero s
),

-- --------------------------------------------------------------------------
-- G. Estadísticas de compatibilidad grupos prioritarios
-- --------------------------------------------------------------------------
prioritario_stats AS (
  SELECT
    count(*)::INTEGER AS source_count,

    count(*) FILTER (
      WHERE s.current_key IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM v2_options v
          WHERE v.dimension_key = 'GRUPO_PRIORITARIO'
            AND v.option_key = upper(s.current_key)
            AND v.activo = true
        )
    )::INTEGER AS mapped_count,

    count(*) FILTER (
      WHERE s.current_key IS NULL
         OR NOT EXISTS (
           SELECT 1
           FROM v2_options v
           WHERE v.dimension_key = 'GRUPO_PRIORITARIO'
             AND v.option_key = upper(s.current_key)
             AND v.activo = true
         )
    )::INTEGER AS missing_count,

    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'clave', s.source_key,
          'nombre', s.source_label
        )
        ORDER BY s.source_key
      ) FILTER (
        WHERE s.current_key IS NULL
           OR NOT EXISTS (
             SELECT 1
             FROM v2_options v
             WHERE v.dimension_key = 'GRUPO_PRIORITARIO'
               AND v.option_key = upper(s.current_key)
               AND v.activo = true
           )
      ),
      '[]'::jsonb
    ) AS missing_options

  FROM src_prioritario s
),

-- --------------------------------------------------------------------------
-- H. Columnas estructurales para Participación / Acceso
-- --------------------------------------------------------------------------
structure_stats AS (
  SELECT
    EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'v2'
        AND table_name = 'registros'
        AND column_name = 'total_participantes'
    ) AS total_participantes_existe,

    EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'v2'
        AND table_name = 'registros'
        AND column_name = 'total_accesos'
    ) AS total_accesos_existe
),

-- --------------------------------------------------------------------------
-- I. Opción histórica amplia "Niñez"
-- Esta opción NO debe borrarse porque ya representa el modelo histórico,
-- pero no es equivalente al modelo 2026 que separa 0–5 y 6–12.
-- --------------------------------------------------------------------------
historical_stats AS (
  SELECT
    EXISTS (
      SELECT 1
      FROM v2_options
      WHERE dimension_key = 'GRUPO_ETARIO'
        AND option_key = 'NINEZ'
        AND activo = true
    ) AS ninez_historica_activa,

    EXISTS (
      SELECT 1
      FROM v2_options
      WHERE dimension_key = 'GRUPO_PRIORITARIO'
        AND option_key = 'LGBTQ'
        AND activo = true
    ) AS lgbtq_historico_activo
)

SELECT
  'V2.1 - 09c_source_alignment_2026' AS diagnostico,

  -- Grupo etario
  e.source_count AS etarios_fuente_2026,
  e.mapped_count AS etarios_compatibles_actuales,
  e.missing_count AS etarios_faltantes,
  e.missing_options AS detalle_etarios_faltantes,

  -- Género
  g.source_count AS generos_fuente_2026,
  g.mapped_count AS generos_compatibles_actuales,
  g.missing_count AS generos_faltantes,
  g.missing_options AS detalle_generos_faltantes,

  -- Prioritarios
  p.source_count AS prioritarios_fuente_2026,
  p.mapped_count AS prioritarios_compatibles_actuales,
  p.missing_count AS prioritarios_faltantes,
  p.missing_options AS detalle_prioritarios_faltantes,

  -- Estructura
  s.total_participantes_existe,
  s.total_accesos_existe,

  -- Históricos que deben conservarse
  h.ninez_historica_activa,
  h.lgbtq_historico_activo,

  -- Decisiones
  (
    NOT s.total_participantes_existe
    OR NOT s.total_accesos_existe
  ) AS requiere_ampliar_registros,

  (
    e.missing_count > 0
    OR g.missing_count > 0
    OR p.missing_count > 0
  ) AS requiere_versionar_demografia,

  (
    s.total_participantes_existe
    AND s.total_accesos_existe
    AND e.missing_count = 0
    AND g.missing_count = 0
    AND p.missing_count = 0
  ) AS listo_para_seed_2026,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.09b'
  ) AS seed_09b_confirmado

FROM etario_stats e
CROSS JOIN genero_stats g
CROSS JOIN prioritario_stats p
CROSS JOIN structure_stats s
CROSS JOIN historical_stats h;


-- ============================================================================
-- RESULTADO ESPERADO EN EL MODELO ACTUAL:
--
-- etarios_fuente_2026              = 8
-- etarios_compatibles_actuales     = 3
-- etarios_faltantes                = 5
--
-- generos_fuente_2026              = 6
-- generos_compatibles_actuales     = 2
-- generos_faltantes                = 4
--
-- prioritarios_fuente_2026         = 9
-- prioritarios_compatibles_actuales= 3
-- prioritarios_faltantes           = 6
--
-- total_participantes_existe       = false
-- total_accesos_existe             = false
--
-- ninez_historica_activa           = true
-- lgbtq_historico_activo           = true
--
-- requiere_ampliar_registros       = true
-- requiere_versionar_demografia    = true
-- listo_para_seed_2026             = false
-- seed_09b_confirmado              = 1
--
-- IMPORTANTE:
-- "false" en listo_para_seed_2026 ES EL RESULTADO CORRECTO.
--
-- El siguiente archivo, si el diagnóstico coincide, será:
--
--   09d_demographic_model_2026.sql
--
-- Ese archivo:
--   - conservará catálogos históricos 2025/V1
--   - agregará esquemas demográficos versionados
--   - agregará Participación y Acceso sin eliminar total_beneficiarios
--   - permitirá que cada acción/ejercicio seleccione el esquema aplicable
-- ============================================================================
