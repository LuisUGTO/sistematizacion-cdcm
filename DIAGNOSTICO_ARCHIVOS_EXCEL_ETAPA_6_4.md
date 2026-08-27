# Diagnóstico de los 10 archivos Excel recibidos

## Resultado ejecutivo

Los archivos sí sirven y permitieron confirmar que Vinculación Cultural no utiliza un único formato. Se identificaron cinco familias de información. La importación debe reconocer la granularidad antes de guardar para no sumar dos veces una actividad y su concentrado.

## Familias detectadas

### 1. Actividades operativas detalladas

Archivos principales:

- `Cuerámaro - Reporte de actividades 2026.xlsx`
- `(Dolores Hidalgo) Reporte de Actividades 2025.xlsx`
- Hojas detalladas de `Concentrado Numeralia Informe de Gobierno.xlsx`

Uso en V2: importación a borradores operativos, una actividad por fila.

### 2. Concentrados mensuales CDCM

Archivo principal:

- `CONCENTRADOS 2025.xlsx`

Uso futuro: capa agregada mensual. No debe mezclarse con el detalle operativo.

### 3. Indicadores y resúmenes por proyecto

Archivos principales:

- `Indicadores 2026.xlsx`
- `Indicadores 2025 (1) (1).xlsx`
- `Indicadores 2025 (1).xlsx`
- `CDCM. RESUMEN POR PROYECTO.xlsx`

Uso futuro: indicadores versionados y metas. Las dos versiones 2025 no son archivos idénticos, por lo que deben tratarse como versiones y no descartarse automáticamente.

### 4. Estadística mensual de bibliotecas

Archivo principal:

- `Concentrado Estadísticas 2025.xlsx`

Uso futuro: módulo estadístico de bibliotecas, separado de la actividad cultural individual.

### 5. Catálogo y diagnóstico de bibliotecas

Archivo principal:

- `DIAGNOSTICO, DIRECTORIO, BIBLIOTECAS 2022.xlsx`

Uso futuro: catálogo/directorio e infraestructura. No alimenta el contador de actividades.

## Regla de seguridad adoptada

La Etapa 6.4 permite importar actividades detalladas y advierte cuando una hoja parece un indicador, catálogo o concentrado. Las otras familias se conservarán para módulos especializados; no se forzarán dentro de `v2.registros`.
