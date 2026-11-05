# Голос пилота: генерация реплик (PVO-1)

Модель: **Qwen3-TTS-12Hz-1.7B-VoiceDesign** (Apache-2.0, голос по текстовому описанию, RU+EN). Выбор и сравнение — `docs/research/pilot-voice-tts.md`.

## Окружение (локально, не в git)
Каталог `~/data/pilot-voice/` (venv ≈ 6 ГБ, веса HF ≈ 4,5 ГБ в `~/data/pilot-voice/hf`). Драйвер NVIDIA 550 (CUDA 12.4) — нужен torch cu124:

```bash
mkdir -p ~/data/pilot-voice && cd ~/data/pilot-voice
python3 -m venv venv
./venv/bin/pip install -U qwen-tts soundfile pyloudnorm scipy
./venv/bin/pip install torch==2.6.0 torchaudio==2.6.0 --extra-index-url https://download.pytorch.org/whl/cu124
./venv/bin/python -c "import torch;print(torch.cuda.is_available())"   # True
```
(без второй команды pip ставит torch 2.15+cu132 — на драйвере 550 CUDA недоступна.) Нужен `ffmpeg` с libvorbis.

## Запуск
```bash
export HF_HOME=~/data/pilot-voice/hf
~/data/pilot-voice/venv/bin/python tools/sounds/voice/gen_voice.py \
  --lines tools/sounds/voice/samples.json --out OUT_DIR --stats tools/sounds/voice/stats.json
```
Результат: `OUT_DIR/<voice>/<lang>/<id>.ogg` (id = `takeoff_1` и т. д., то есть `<ситуация>_<k>` по PV-К3). Образцы PVO-1:
`/home/greg/deltaplan/build/screenshots/pilot-voice/samples/` (24 файла, 2 голоса × 2 языка × 6 реплик). Первый запуск скачивает веса (≈ 6 мин).

`samples.json` — тексты шести реплик и описания голосов (`voices.male`, `voices.female`); тон — английская фраза `tone_en` (для модели), русский `tone` — как в PV-К1. PVO-3 подаёт те же поля из `configs/pilot_voice.json`.

Пост-обработка в `gen_voice.py`: обрезка тишины (≈ 60 мс по краям), ресемпл 44,1 кГц, подгонка под −20 LUFS по замеру ffmpeg готового ogg (до 4 проходов), лимитер, Ogg Vorbis q6 моно. `stats.json` — замеры (LUFS, пик, длительность, время счёта, пик VRAM).

## Лицензии
Код `qwen-tts` и веса — Apache-2.0 (`https://github.com/QwenLM/Qwen3-TTS/blob/main/LICENSE`, карточка `https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`). Голос задан описанием, не клон человека. Запись в `ASSETS.md` / `assets/sounds/LICENSES.md` — за PVO-3.
