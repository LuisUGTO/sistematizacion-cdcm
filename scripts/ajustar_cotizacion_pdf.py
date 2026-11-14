from docx import Document
from pathlib import Path

src = Path('Documentos SC/Expediente Vinculacion/07 Cotización de servicios profesionales - BORRADOR.docx')
dst = Path('Documentos SC/Expediente Vinculacion/07 Cotización de servicios profesionales - EDITABLE.docx')
d = Document(src)
p = d.paragraphs
p[0].text = 'Silao de la Victoria, Guanajuato, noviembre de 2026'
p[1].text = 'COTIZACIÓN DE SERVICIOS PROFESIONALES'
p[2].text = 'Sistematización de actividades de Vinculación Cultural'
p[3].text = 'Secretaría de Cultura del Estado de Guanajuato.'
p[4].text = 'Atención: Dirección General de Vinculación y Desarrollo Cultural - Coordinación de Desarrollo Cultural Municipal.'
p[5].text = '1. Concepto del servicio'
p[6].text = 'Elaboración de diagnósticos y estadísticas que se efectúan con base en reportes que generan las áreas de la DGVDC en relación a usuarios, talleres y beneficiarios de las actividades realizadas.'
p[7].text = '2. Propuesta económica'
p[8].text = 'Honorarios y moneda: $34,800.00 (Treinta y cuatro mil ochocientos pesos 00/100 MXN), IVA incluido.'
for idx in (9, 10):
    el = p[idx]._element
    el.getparent().remove(el)
d.save(dst)
