# Validación local del paquete 1

## Alcance de la actualización del 31 de octubre de 2026

Los resultados de 14 pruebas que siguen son evidencia previa conservada, no una ejecución de esta auditoría. No se volvió a ejecutar `pnpm test`: aplica el paquete SQL en PGlite y la solicitud actual prohíbe ejecutar migraciones SQL. Se realiza sólo inventario estático (sintaxis JS/CJS, scripts HTML, JSON y referencias locales) y `git diff --check`; estos controles no validan SQL, TypeScript/Deno, servicios ni recorridos de usuario. Consultar el inventario actualizado y `../../../CONTEXTO_PROYECTO.md` para límites y estado al corte.

## Resultado previo

Resultado estático del 31 de octubre: 130 archivos inventariados (119 de texto, 11 binarios; 61 SQL inventariados sin ejecución), 28 JavaScript/CJS sin errores de sintaxis; sin errores JSON, scripts HTML ni referencias locales estáticas ausentes. `git diff --check` terminó sin errores de espacios; Git avisó de normalización LF/CRLF. Los dos Markdown nuevos también se revisaron antes de la entrega. No se alteró la configuración de finales de línea.

Resultado: **14 pruebas aprobadas, 0 fallos** al ejecutar `node --test tests/seguridad-paquete-1.test.cjs`.

Cobertura:

- Instalación completa y repetición de la migración.
- Detención cuando una definición difiere del diagnóstico.
- Cambio de nombre permitido sólo a SUPERADMIN activo; rechazo de otros roles, cuenta inactiva, perfil ausente y sesión ausente.
- Permisos de ejecución de RPC y triggers.
- Observación por SUPERADMIN y ADMIN con control de versión.
- Bloqueo de aprobación por calidad incompleta.
- Supervisor permitido dentro de alcance y rechazado fuera de municipio.
- Rechazo de revisión y decisión para perfiles no autorizados.
- Preparación, carga y confirmación de lotes administrativos con control de propietario.
- Historial e importaciones inaccesibles para roles no autorizados.
- Límite de evidencias, tipos y carácter privado; conservación del otro bucket de prueba.
- Continuidad de carga después de duplicados, sin volver a importarlos.
- Todos los controles del verificador SQL entregable.
- Alineación del permiso de importación en la interfaz.

Además, el inventario actual confirmó sintaxis válida de 28 archivos JavaScript/CJS, scripts incrustados en HTML y archivos JSON, y no detectó referencias locales estáticas ausentes en la aplicación. La revisión de diferencias no encontró errores de espacios. Las advertencias de normalización de finales de línea de Git no alteran las huellas: el paquete normaliza retornos de carro antes de compararlas.

Entorno: PGlite 0.5.10 local en memoria, tablas mínimas y cuentas ficticias. Las nueve funciones proceden del diagnóstico de la base instalada; el núcleo de captura llamado por la confirmación de lotes es un sustituto de pruebas. No se conectó a Supabase. No se probaron subidas HTTP, configuración real de Auth, publicación Jekyll ni recorridos completos de navegador.

Pendientes: ejecutar el paquete en Supabase, traer el resultado de `02_verificar.sql`, realizar los recorridos de integración descritos en LEEME y comprobar las exclusiones de GitHub Pages después de publicar.
