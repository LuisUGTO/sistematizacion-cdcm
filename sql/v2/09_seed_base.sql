-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 09_seed_base.sql
-- Catálogos base oficiales y valores iniciales
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   02_catalogs.sql
--   03_operation_modules.sql
--   04_indicators.sql
--   05_functions_triggers.sql
--   06_rls.sql
--   07_storage.sql
--   08_views_rpc.sql
--
-- CARGA:
--   ✓ unidades operativas iniciales
--   ✓ 46 municipios oficiales de Guanajuato
--   ✓ aliases históricos V1 comprobados
--   ✓ tipos de registro
--   ✓ tipos de espacio
--   ✓ funciones de personas
--   ✓ tipos de asentamiento base
--   ✓ unidades de medida base
--   ✓ dimensiones y opciones poblacionales heredables
--
-- DECISIÓN:
--   cat_regiones NO se llena en este archivo.
--   La regionalización institucional se cargará cuando se confirme contra
--   los archivos oficiales de Vinculación/Indicadores.
--
-- FUENTE TERRITORIAL:
--   INEGI - clave geoestadística municipal completa:
--   11 (Guanajuato) + 3 dígitos de municipio = 5 caracteres.
--
-- SEGURIDAD:
--   Script idempotente.
--   Puede reejecutarse sin crear duplicados lógicos.
--
-- NO HACE:
--   ✗ no crea programas institucionales aún
--   ✗ no crea acciones institucionales aún
--   ✗ no crea indicadores 2025/2026 aún
--   ✗ no migra registros V1
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '180s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.cat_municipios') IS NULL
     OR to_regclass('v2.cat_unidades_operativas') IS NULL
     OR to_regclass('v2.cat_tipos_registro') IS NULL
     OR to_regclass('v2.cat_dimensiones_poblacion') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan catálogos V2. Ejecute 01-08 primero.';
  END IF;
END
$$;


-- ============================================================================
-- 01. UNIDADES OPERATIVAS INICIALES
-- ============================================================================

INSERT INTO v2.cat_unidades_operativas (
  clave,
  nombre,
  descripcion,
  orden,
  activo
)
VALUES
  (
    'CDCM',
    'Centros de Desarrollo Cultural Municipal',
    'Unidad operativa inicial para la captura y seguimiento CDCM.',
    10,
    true
  ),
  (
    'BIBLIOTECAS',
    'Bibliotecas',
    'Unidad operativa inicial para la Red de Bibliotecas y sus estadísticas.',
    20,
    true
  )
ON CONFLICT DO NOTHING;


-- Normalización idempotente de nombres/estado.
UPDATE v2.cat_unidades_operativas u
SET
  nombre = s.nombre,
  descripcion = s.descripcion,
  orden = s.orden,
  activo = true
FROM (
  VALUES
    (
      'CDCM',
      'Centros de Desarrollo Cultural Municipal',
      'Unidad operativa inicial para la captura y seguimiento CDCM.',
      10
    ),
    (
      'BIBLIOTECAS',
      'Bibliotecas',
      'Unidad operativa inicial para la Red de Bibliotecas y sus estadísticas.',
      20
    )
) AS s(clave, nombre, descripcion, orden)
WHERE lower(btrim(u.clave)) = lower(s.clave);


-- ============================================================================
-- 02. MUNICIPIOS OFICIALES DE GUANAJUATO
--
-- clave_inegi guarda CVEGEO de 5 caracteres.
-- Ejemplo:
--   Abasolo = 11001
-- ============================================================================

INSERT INTO v2.cat_municipios (
  clave_inegi,
  nombre_oficial,
  orden,
  activo
)
VALUES
  ('11001', 'Abasolo', 1, true),
  ('11002', 'Acámbaro', 2, true),
  ('11003', 'San Miguel de Allende', 3, true),
  ('11004', 'Apaseo el Alto', 4, true),
  ('11005', 'Apaseo el Grande', 5, true),
  ('11006', 'Atarjea', 6, true),
  ('11007', 'Celaya', 7, true),
  ('11008', 'Manuel Doblado', 8, true),
  ('11009', 'Comonfort', 9, true),
  ('11010', 'Coroneo', 10, true),
  ('11011', 'Cortazar', 11, true),
  ('11012', 'Cuerámaro', 12, true),
  ('11013', 'Doctor Mora', 13, true),
  ('11014', 'Dolores Hidalgo Cuna de la Independencia Nacional', 14, true),
  ('11015', 'Guanajuato', 15, true),
  ('11016', 'Huanímaro', 16, true),
  ('11017', 'Irapuato', 17, true),
  ('11018', 'Jaral del Progreso', 18, true),
  ('11019', 'Jerécuaro', 19, true),
  ('11020', 'León', 20, true),
  ('11021', 'Moroleón', 21, true),
  ('11022', 'Ocampo', 22, true),
  ('11023', 'Pénjamo', 23, true),
  ('11024', 'Pueblo Nuevo', 24, true),
  ('11025', 'Purísima del Rincón', 25, true),
  ('11026', 'Romita', 26, true),
  ('11027', 'Salamanca', 27, true),
  ('11028', 'Salvatierra', 28, true),
  ('11029', 'San Diego de la Unión', 29, true),
  ('11030', 'San Felipe', 30, true),
  ('11031', 'San Francisco del Rincón', 31, true),
  ('11032', 'San José Iturbide', 32, true),
  ('11033', 'San Luis de la Paz', 33, true),
  ('11034', 'Santa Catarina', 34, true),
  ('11035', 'Santa Cruz de Juventino Rosas', 35, true),
  ('11036', 'Santiago Maravatío', 36, true),
  ('11037', 'Silao de la Victoria', 37, true),
  ('11038', 'Tarandacuao', 38, true),
  ('11039', 'Tarimoro', 39, true),
  ('11040', 'Tierra Blanca', 40, true),
  ('11041', 'Uriangato', 41, true),
  ('11042', 'Valle de Santiago', 42, true),
  ('11043', 'Victoria', 43, true),
  ('11044', 'Villagrán', 44, true),
  ('11045', 'Xichú', 45, true),
  ('11046', 'Yuriria', 46, true)
ON CONFLICT DO NOTHING;


-- Reafirma nombre oficial, orden y estado por CVEGEO.
UPDATE v2.cat_municipios m
SET
  nombre_oficial = s.nombre_oficial,
  orden = s.orden,
  activo = true
FROM (
  VALUES
    ('11001', 'Abasolo', 1),
    ('11002', 'Acámbaro', 2),
    ('11003', 'San Miguel de Allende', 3),
    ('11004', 'Apaseo el Alto', 4),
    ('11005', 'Apaseo el Grande', 5),
    ('11006', 'Atarjea', 6),
    ('11007', 'Celaya', 7),
    ('11008', 'Manuel Doblado', 8),
    ('11009', 'Comonfort', 9),
    ('11010', 'Coroneo', 10),
    ('11011', 'Cortazar', 11),
    ('11012', 'Cuerámaro', 12),
    ('11013', 'Doctor Mora', 13),
    ('11014', 'Dolores Hidalgo Cuna de la Independencia Nacional', 14),
    ('11015', 'Guanajuato', 15),
    ('11016', 'Huanímaro', 16),
    ('11017', 'Irapuato', 17),
    ('11018', 'Jaral del Progreso', 18),
    ('11019', 'Jerécuaro', 19),
    ('11020', 'León', 20),
    ('11021', 'Moroleón', 21),
    ('11022', 'Ocampo', 22),
    ('11023', 'Pénjamo', 23),
    ('11024', 'Pueblo Nuevo', 24),
    ('11025', 'Purísima del Rincón', 25),
    ('11026', 'Romita', 26),
    ('11027', 'Salamanca', 27),
    ('11028', 'Salvatierra', 28),
    ('11029', 'San Diego de la Unión', 29),
    ('11030', 'San Felipe', 30),
    ('11031', 'San Francisco del Rincón', 31),
    ('11032', 'San José Iturbide', 32),
    ('11033', 'San Luis de la Paz', 33),
    ('11034', 'Santa Catarina', 34),
    ('11035', 'Santa Cruz de Juventino Rosas', 35),
    ('11036', 'Santiago Maravatío', 36),
    ('11037', 'Silao de la Victoria', 37),
    ('11038', 'Tarandacuao', 38),
    ('11039', 'Tarimoro', 39),
    ('11040', 'Tierra Blanca', 40),
    ('11041', 'Uriangato', 41),
    ('11042', 'Valle de Santiago', 42),
    ('11043', 'Victoria', 43),
    ('11044', 'Villagrán', 44),
    ('11045', 'Xichú', 45),
    ('11046', 'Yuriria', 46)
) AS s(clave_inegi, nombre_oficial, orden)
WHERE m.clave_inegi = s.clave_inegi;


-- ============================================================================
-- 03. ALIASES HISTÓRICOS V1 COMPROBADOS
--
-- NO se usan para captura manual.
-- Solo normalización de importaciones/migraciones.
-- ============================================================================

INSERT INTO v2.cat_municipio_alias (
  municipio_id,
  alias,
  origen,
  activo
)
SELECT
  m.id,
  x.alias,
  'V1_REGISTROS_CULTURALES',
  true
FROM (
  VALUES
    ('11012', 'Cueramaro'),
    ('11036', 'Stgo Mtío'),
    ('11014', 'Dolores Hidalgo'),
    ('11014', 'Dolores Hidalgo C.I.N.')
) AS x(clave_inegi, alias)
JOIN v2.cat_municipios m
  ON m.clave_inegi = x.clave_inegi
WHERE NOT EXISTS (
  SELECT 1
  FROM v2.cat_municipio_alias a
  WHERE lower(btrim(a.alias)) = lower(btrim(x.alias))
);


-- ============================================================================
-- 04. TIPOS DE REGISTRO
-- ============================================================================

INSERT INTO v2.cat_tipos_registro (
  clave,
  nombre,
  descripcion,
  orden,
  activo
)
VALUES
  ('TALLER', 'Taller cultural',
   'Taller o proceso formativo cultural.', 10, true),

  ('CURSO_VERANO', 'Curso de verano',
   'Curso o actividad de temporada vacacional.', 20, true),

  ('CAPACITACION', 'Capacitación',
   'Proceso de capacitación o formación especializada.', 30, true),

  ('REUNION', 'Reunión',
   'Reunión de trabajo, coordinación o seguimiento.', 40, true),

  ('INTERCAMBIO', 'Intercambio',
   'Intercambio cultural o colaboración entre territorios.', 50, true),

  ('PROYECTO_SOCIOCULTURAL', 'Proyecto sociocultural',
   'Proyecto con intervención sociocultural documentada.', 60, true),

  ('PROYECTO_CIRCUITO', 'Proyecto de circuito',
   'Proyecto articulado en circuito cultural.', 70, true),

  ('PROYECTO_REGIONAL', 'Proyecto regional',
   'Proyecto con alcance regional o multiterritorial.', 80, true),

  ('EVENTO', 'Evento',
   'Evento cultural o actividad pública.', 90, true),

  ('EXPOSICION', 'Exposición',
   'Exposición cultural, artística o patrimonial.', 100, true),

  ('ESTADISTICA_BIBLIOTECA', 'Estadística de biblioteca',
   'Reporte estadístico periódico de una biblioteca.', 110, true),

  ('OTRO', 'Otro',
   'Tipo excepcional no clasificado en los anteriores.', 999, true)

ON CONFLICT DO NOTHING;


-- ============================================================================
-- 05. TIPOS DE ESPACIO
-- ============================================================================

INSERT INTO v2.cat_tipos_espacio (
  clave,
  nombre,
  orden,
  activo
)
VALUES
  ('BIBLIOTECA', 'Biblioteca', 10, true),
  ('CASA_CULTURA', 'Casa de Cultura', 20, true),
  ('TEATRO', 'Teatro', 30, true),
  ('MUSEO', 'Museo', 40, true),
  ('CENTRO_CULTURAL', 'Centro Cultural', 50, true),
  ('SALA', 'Sala', 60, true),
  ('ESPACIO_COMUNITARIO', 'Espacio comunitario', 70, true),
  ('OTRO', 'Otro', 999, true)
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 06. FUNCIONES DE PERSONAS
-- ============================================================================

INSERT INTO v2.cat_funciones (
  clave,
  nombre,
  orden,
  activo
)
VALUES
  ('DOCENTE', 'Docente', 10, true),
  ('TALLERISTA', 'Tallerista', 20, true),
  ('BIBLIOTECARIO', 'Bibliotecario/a', 30, true),
  ('ENLACE_MUNICIPAL', 'Enlace municipal', 40, true),
  ('RESPONSABLE', 'Responsable', 50, true),
  ('OTRO', 'Otro', 999, true)
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 07. TIPOS DE ASENTAMIENTO BASE
-- ============================================================================

INSERT INTO v2.cat_tipos_asentamiento (
  clave,
  nombre,
  orden,
  activo
)
VALUES
  ('COMUNIDAD', 'Comunidad', 10, true),
  ('COLONIA', 'Colonia', 20, true),
  ('LOCALIDAD', 'Localidad', 30, true),
  ('BARRIO', 'Barrio', 40, true),
  ('EJIDO', 'Ejido', 50, true),
  ('RANCHERIA', 'Ranchería', 60, true),
  ('OTRO', 'Otro', 999, true)
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 08. UNIDADES DE MEDIDA BASE
-- ============================================================================

INSERT INTO v2.cat_unidades_medida (
  clave,
  nombre,
  simbolo,
  tipo_dato,
  activo
)
VALUES
  ('ACCION', 'Acción', NULL, 'ENTERO', true),
  ('PERSONA', 'Persona', NULL, 'ENTERO', true),
  ('EVENTO', 'Evento', NULL, 'ENTERO', true),
  ('PROYECTO', 'Proyecto', NULL, 'ENTERO', true),
  ('PORCENTAJE', 'Porcentaje', '%', 'PORCENTAJE', true),
  ('MONTO_MXN', 'Monto en pesos mexicanos', 'MXN', 'MONEDA', true)
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 09. DIMENSIONES DE POBLACIÓN
--
-- Estas dimensiones preservan el modelo CDCM histórico.
-- Bibliotecas podrá ampliar opciones/métricas posteriormente sin alterar
-- el núcleo.
-- ============================================================================

INSERT INTO v2.cat_dimensiones_poblacion (
  clave,
  nombre,
  descripcion,
  es_exclusiva,
  orden,
  activo
)
VALUES
  (
    'GENERO',
    'Género',
    'Desagregación de personas por género registrada en el modelo histórico.',
    true,
    10,
    true
  ),
  (
    'GRUPO_ETARIO',
    'Grupo etario',
    'Desagregación por grupo de edad registrada en el modelo histórico.',
    true,
    20,
    true
  ),
  (
    'GRUPO_PRIORITARIO',
    'Grupo prioritario',
    'Características poblacionales que pueden traslaparse entre sí.',
    false,
    30,
    true
  )
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 10. OPCIONES DE POBLACIÓN
-- ============================================================================

-- Género
INSERT INTO v2.cat_opciones_poblacion (
  dimension_id,
  clave,
  nombre,
  orden,
  activo
)
SELECT
  d.id,
  x.clave,
  x.nombre,
  x.orden,
  true
FROM v2.cat_dimensiones_poblacion d
CROSS JOIN (
  VALUES
    ('HOMBRES', 'Hombres', 10),
    ('MUJERES', 'Mujeres', 20)
) AS x(clave, nombre, orden)
WHERE lower(btrim(d.clave)) = 'genero'
  AND NOT EXISTS (
    SELECT 1
    FROM v2.cat_opciones_poblacion o
    WHERE o.dimension_id = d.id
      AND lower(btrim(o.clave)) = lower(x.clave)
  );


-- Grupo etario
INSERT INTO v2.cat_opciones_poblacion (
  dimension_id,
  clave,
  nombre,
  orden,
  activo
)
SELECT
  d.id,
  x.clave,
  x.nombre,
  x.orden,
  true
FROM v2.cat_dimensiones_poblacion d
CROSS JOIN (
  VALUES
    ('NINEZ', 'Niñez', 10),
    ('ADOLESCENCIA', 'Adolescencia', 20),
    ('JUVENTUDES', 'Juventudes', 30),
    ('ADULTOS_MAYORES', 'Personas adultas mayores', 40)
) AS x(clave, nombre, orden)
WHERE lower(btrim(d.clave)) = 'grupo_etario'
  AND NOT EXISTS (
    SELECT 1
    FROM v2.cat_opciones_poblacion o
    WHERE o.dimension_id = d.id
      AND lower(btrim(o.clave)) = lower(x.clave)
  );


-- Grupos prioritarios
INSERT INTO v2.cat_opciones_poblacion (
  dimension_id,
  clave,
  nombre,
  orden,
  activo
)
SELECT
  d.id,
  x.clave,
  x.nombre,
  x.orden,
  true
FROM v2.cat_dimensiones_poblacion d
CROSS JOIN (
  VALUES
    ('AFROMEXICANAS', 'Personas afromexicanas', 10),
    ('DISCAPACIDAD', 'Personas con discapacidad', 20),
    ('INDIGENAS', 'Personas indígenas', 30),
    ('LGBTQ', 'Personas LGBTQ+', 40)
) AS x(clave, nombre, orden)
WHERE lower(btrim(d.clave)) = 'grupo_prioritario'
  AND NOT EXISTS (
    SELECT 1
    FROM v2.cat_opciones_poblacion o
    WHERE o.dimension_id = d.id
      AND lower(btrim(o.clave)) = lower(x.clave)
  );


-- ============================================================================
-- 11. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.09',
  '09_seed_base.sql - Catálogos base, 46 municipios INEGI y aliases históricos confirmados.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 12. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

SELECT
  'V2.1 - 09_seed_base' AS instalacion,

  (
    SELECT count(*)
    FROM v2.cat_unidades_operativas
    WHERE upper(btrim(clave)) IN ('CDCM', 'BIBLIOTECAS')
  ) AS unidades_base,

  (
    SELECT count(*)
    FROM v2.cat_municipios
    WHERE clave_inegi BETWEEN '11001' AND '11046'
  ) AS municipios_guanajuato,

  (
    SELECT count(*)
    FROM v2.cat_municipio_alias
    WHERE lower(btrim(alias)) IN (
      lower('Cueramaro'),
      lower('Stgo Mtío'),
      lower('Dolores Hidalgo'),
      lower('Dolores Hidalgo C.I.N.')
    )
  ) AS aliases_v1_base,

  (
    SELECT count(*)
    FROM v2.cat_tipos_registro
    WHERE upper(btrim(clave)) IN (
      'TALLER',
      'CURSO_VERANO',
      'CAPACITACION',
      'REUNION',
      'INTERCAMBIO',
      'PROYECTO_SOCIOCULTURAL',
      'PROYECTO_CIRCUITO',
      'PROYECTO_REGIONAL',
      'EVENTO',
      'EXPOSICION',
      'ESTADISTICA_BIBLIOTECA',
      'OTRO'
    )
  ) AS tipos_registro_base,

  (
    SELECT count(*)
    FROM v2.cat_tipos_espacio
    WHERE upper(btrim(clave)) IN (
      'BIBLIOTECA',
      'CASA_CULTURA',
      'TEATRO',
      'MUSEO',
      'CENTRO_CULTURAL',
      'SALA',
      'ESPACIO_COMUNITARIO',
      'OTRO'
    )
  ) AS tipos_espacio_base,

  (
    SELECT count(*)
    FROM v2.cat_funciones
    WHERE upper(btrim(clave)) IN (
      'DOCENTE',
      'TALLERISTA',
      'BIBLIOTECARIO',
      'ENLACE_MUNICIPAL',
      'RESPONSABLE',
      'OTRO'
    )
  ) AS funciones_base,

  (
    SELECT count(*)
    FROM v2.cat_dimensiones_poblacion
    WHERE upper(btrim(clave)) IN (
      'GENERO',
      'GRUPO_ETARIO',
      'GRUPO_PRIORITARIO'
    )
  ) AS dimensiones_poblacion,

  (
    SELECT count(*)
    FROM v2.cat_opciones_poblacion
  ) AS opciones_poblacion,

  (
    SELECT count(*)
    FROM v2.cat_regiones
  ) AS regiones_cargadas,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.09'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO:
--
-- unidades_base               = 2
-- municipios_guanajuato       = 46
-- aliases_v1_base             = 4
-- tipos_registro_base         = 12
-- tipos_espacio_base          = 8
-- funciones_base              = 6
-- dimensiones_poblacion       = 3
-- opciones_poblacion          = 10
-- regiones_cargadas           = 0   <-- INTENCIONAL
-- migracion_registrada        = 1
--
-- IMPORTANTE:
-- regiones_cargadas = 0 NO es un error.
-- No se inventó una regionalización institucional.
--
-- SIGUIENTE PASO RECOMENDADO:
--
-- Antes de 10_legacy_migration.sql:
--
--   09b_operational_seed.sql
--
-- Debe construirse a partir de:
--   - Indicadores 2025
--   - Indicadores 2026
--   - reportes CDCM
--   - concentrados
--   - archivos de Bibliotecas
--
-- Ahí definiremos con precisión:
--   programas
--   acciones
--   configuracion_acciones
--   indicadores/versiones/metas
--   regionalización institucional
--
-- Solo después se migra V1.
-- ============================================================================
