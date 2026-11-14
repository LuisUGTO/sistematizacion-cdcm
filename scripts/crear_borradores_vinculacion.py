from docx import Document
from docx.shared import Pt, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
from pathlib import Path

OUT=Path('Documentos SC/Expediente Vinculacion')
def doc(title,subtitle):
    d=Document(); s=d.sections[0]; s.top_margin=Inches(.7); s.bottom_margin=Inches(.7); s.left_margin=Inches(.8); s.right_margin=Inches(.8)
    d.styles['Normal'].font.name='Aptos'; d.styles['Normal'].font.size=Pt(10.5)
    p=d.add_paragraph(style='Title'); p.alignment=WD_ALIGN_PARAGRAPH.CENTER; p.add_run(title)
    p=d.add_paragraph(); p.alignment=WD_ALIGN_PARAGRAPH.CENTER; r=p.add_run(subtitle); r.italic=True
    return d
def bullets(d,items,style='List Bullet'):
    for x in items:d.add_paragraph(x,style=style)
def table(d,rows):
    t=d.add_table(rows=0,cols=2); t.style='Table Grid'
    for a,b in rows:
        c=t.add_row().cells; c[0].text=a; c[1].text=b

d=doc('Cotización de servicios de Vinculación Cultural','Borrador para revisión de datos administrativos')
d.add_paragraph('Prestador: Luis Ángel Durán Álvarez | RFC: DUAL921018QI3 | Registro de proveedor/acreedor: 504898')
d.add_paragraph('Dirigida a: [CONFIRMAR destinatario y área]')
d.add_heading('Concepto del servicio',1)
d.add_paragraph('Servicio profesional para apoyar la sistematización, organización, captura, homologación y seguimiento de la información de actividades de Vinculación Cultural, incluyendo talleres, eventos, procesos de formación, reuniones de colaboración, promoción de talento local y demás actividades reportadas por las unidades operativas.')
d.add_heading('Importes',1)
table(d,[('Concepto','Importe'),('Servicio profesional de sistematización y seguimiento de información de Vinculación Cultural','[CONFIRMAR]'),('Subtotal','[CONFIRMAR]'),('IVA','[CONFIRMAR si aplica]'),('Total','[CONFIRMAR]')])
d.add_heading('Condiciones',1)
d.add_paragraph('Vigencia: [CONFIRMAR]. Periodo de prestación: [CONFIRMAR]. Forma y plazo de pago: [CONFIRMAR].')
d.add_paragraph('Borrador pendiente de confirmar destinatario, importe, tratamiento fiscal, vigencia, calendario y condiciones de pago.')
d.add_paragraph('Guanajuato, [fecha]\n\nAtentamente,\n\nLuis Ángel Durán Álvarez\nPULSO Consultoría en Calidad y Transformación Digital')
d.save(OUT/'07 Cotizacion del proyecto/07_Cotizacion_Vinculacion_BORRADOR.docx')

d=doc('Proyecto de Vinculación Cultural','Sistematización y seguimiento de actividades culturales')
d.add_paragraph('Prestador: Luis Ángel Durán Álvarez | RFC: DUAL921018QI3 | Registro de proveedor/acreedor: 504898')
d.add_heading('1. Nombre del proyecto',1); d.add_paragraph('Sistematización y seguimiento de la información de actividades de Vinculación Cultural.')
d.add_heading('2. Antecedentes y necesidad',1); d.add_paragraph('Las unidades de Vinculación Cultural generan información de talleres, sedes, eventos, procesos de formación, reuniones de colaboración, promoción de talento local y otras acciones. El proyecto propone ordenar y homologar esa información para facilitar su captura, consulta, seguimiento y elaboración de reportes institucionales.')
d.add_heading('3. Objetivo general',1); d.add_paragraph('Diseñar y apoyar la organización de una estructura funcional para registrar, sistematizar y dar seguimiento a las actividades de Vinculación Cultural, con criterios homogéneos y trazabilidad de la información.')
d.add_heading('4. Alcance',1); bullets(d,['Revisión de formatos, archivos y fuentes de información existentes.','Homologación de campos, catálogos y criterios de captura.','Estructuración de información de talleres, eventos, sedes, municipios, comunidades y públicos atendidos.','Organización de apartados para procesos de formación, reuniones de colaboración e intercambios.','Definición de reportes y consultas por periodo, sede, municipio, disciplina y población.','Documentación de reglas básicas de captura, validación y actualización.'])
d.add_heading('5. Entregables propuestos',1); bullets(d,['Matriz de fuentes, campos y responsables.','Catálogos y criterios homologados para la captura.','Estructura organizada de registros de actividades.','Descripción funcional de módulos y flujos de seguimiento.','Reportes o vistas de consulta para el periodo acordado.','Documento de recomendaciones para operación y actualización.'],'List Number')
d.add_heading('6. Datos por confirmar',1); table(d,[('Área solicitante y destinatario','[CONFIRMAR]'),('Periodo de ejecución','[CONFIRMAR]'),('Municipios, sedes o unidades incluidas','[CONFIRMAR alcance]'),('Calendario de actividades y entregas','[CONFIRMAR]'),('Criterios de aceptación','[CONFIRMAR con Vinculación]')])
d.add_paragraph('Base de proyecto para Vinculación; no sustituye el formato institucional ni el contrato que, en su caso, formalicen las partes.')
d.add_paragraph('Guanajuato, [fecha]\n\nLuis Ángel Durán Álvarez')
d.save(OUT/'08 Proyecto/08_Proyecto_Vinculacion_BORRADOR.docx')
