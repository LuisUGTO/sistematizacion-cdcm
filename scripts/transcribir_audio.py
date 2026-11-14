from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools' / 'faster_whisper'))
from faster_whisper import WhisperModel

if len(sys.argv) != 2:
    raise SystemExit('Uso: python scripts/transcribir_audio.py ruta\u0020al\u0020audio.ogg')

audio = Path(sys.argv[1])
if not audio.exists():
    raise SystemExit(f'No existe el archivo: {audio}')

model = WhisperModel('small', device='cpu', compute_type='int8')
segments, info = model.transcribe(str(audio), language='es', vad_filter=True)
for segment in segments:
    print(segment.text.strip())
