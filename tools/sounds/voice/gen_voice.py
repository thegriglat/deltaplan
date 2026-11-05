#!/usr/bin/env python3
"""Генерация реплик пилота (Qwen3-TTS VoiceDesign) -> <out>/<voice>/<lang>/<id>.ogg (PV-К3).

python gen_voice.py --lines samples.json --out DIR [--voices male,female] [--langs ru,en] [--seed 1234]
Файл --lines: {"lines":[{id,ru,en,tone,tone_en}], "voices":{male:описание, female:описание}}.
Пост-обработка: обрезка тишины (хвост/голова <= 80 мс), -20 LUFS, пик <= -3 dBFS, моно 44,1 кГц, Ogg Vorbis.
Ударения в русском: знак '+' перед ударной гласной не поддерживается моделью напрямую; используйте
Юникод-ударение (U+0301) или переписывание слова в тексте (см. docs/research/pilot-voice-tts.md).
"""
import argparse, json, subprocess, time, os, sys
import numpy as np, soundfile as sf, pyloudnorm as pyln, torch
from scipy.signal import resample_poly

MODEL = os.environ.get("PV_MODEL", "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign")
LANG = {"ru": "Russian", "en": "English"}

def trim(x, sr, thr_db=-45.0, keep=0.06):
    a = np.abs(x); th = 10 ** (thr_db / 20)
    idx = np.where(a > th)[0]
    if len(idx) == 0: return x
    k = int(keep * sr)
    return x[max(idx[0] - k, 0): idx[-1] + k]

def ebur(path):
    """Интегральная громкость и истинный пик по файлу так, как мерит ffmpeg (ebur128)."""
    r = subprocess.run(["ffmpeg", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True).stderr
    tail = r[r.rfind("Summary:"):]
    I = float(tail.split("I:")[1].split("LUFS")[0]); P = float(tail.split("Peak:")[1].split("dBFS")[0])
    return I, P

def encode(x, sr, out_path, gain_db, limit_db):
    tmp = out_path + ".wav"
    sf.write(tmp, x.astype(np.float32), sr, subtype="FLOAT")
    lim = 10 ** (limit_db / 20)
    af = f"volume={gain_db:.3f}dB,alimiter=limit={lim:.4f}:attack=1:release=20:level=disabled"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-af", af, "-ac", "1", "-ar", "44100",
                    "-c:a", "libvorbis", "-q:a", "6", out_path], check=True)
    os.remove(tmp)

def process(x, sr, out_path, target=-20.0, peak=-3.0):
    """Обрезка тишины, ресемпл 44,1 кГц, подгонка под -20 LUFS (замер ffmpeg по готовому ogg, 2 прохода),
    лимитер на -3,6 dBFS (кодек Vorbis добавляет ~0,5 дБ пика)."""
    x = trim(x.astype(np.float64), sr)
    if sr != 44100:
        g = np.gcd(sr, 44100); x = resample_poly(x, 44100 // g, sr // g); sr = 44100
    gain = target - pyln.Meter(sr).integrated_loudness(np.concatenate([np.zeros(sr // 2), x, np.zeros(sr // 2)]))
    for _ in range(4):
        encode(x, sr, out_path, gain, peak - 0.6)
        I, P = ebur(out_path)
        if abs(I - target) < 0.3: break
        gain += target - I
    return dict(lufs=round(I, 2), peak_db=round(P, 2), dur_s=round(len(x) / sr, 2))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lines", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--voices", default="male,female"); ap.add_argument("--langs", default="ru,en")
    ap.add_argument("--seed", type=int, default=1234); ap.add_argument("--model", default=MODEL)
    ap.add_argument("--stats", default=None)
    a = ap.parse_args()
    from qwen_tts import Qwen3TTSModel
    cfg = json.load(open(a.lines))
    t0 = time.time()
    model = Qwen3TTSModel.from_pretrained(a.model, device_map="cuda:0", dtype=torch.bfloat16)
    load_s = time.time() - t0
    torch.cuda.reset_peak_memory_stats()
    stats = dict(model=a.model, load_s=round(load_s, 1), items=[])
    for v in a.voices.split(","):
        for lang in a.langs.split(","):
            for ln in cfg["lines"]:
                tone = ln["tone_en"]
                instruct = f'{cfg["voices"][v]} Emotion and delivery: {tone}.'
                torch.manual_seed(a.seed)
                t1 = time.time()
                wavs, sr = model.generate_voice_design(text=ln[lang], language=LANG[lang], instruct=instruct)
                gen_s = time.time() - t1
                d = os.path.join(a.out, v, lang); os.makedirs(d, exist_ok=True)
                p = os.path.join(d, ln["id"] + ".ogg")
                st = process(np.asarray(wavs[0]), sr, p)
                st.update(voice=v, lang=lang, id=ln["id"], gen_s=round(gen_s, 2), raw_dur_s=round(len(wavs[0]) / sr, 2))
                st = {k: (float(v) if isinstance(v, np.floating) else v) for k, v in st.items()}; stats["items"].append(st); print(st, flush=True)
    stats["peak_vram_gb"] = round(torch.cuda.max_memory_allocated() / 2**30, 2)
    if a.stats: json.dump(stats, open(a.stats, "w"), ensure_ascii=False, indent=1)
    print("peak VRAM GB", stats["peak_vram_gb"])

if __name__ == "__main__":
    main()
