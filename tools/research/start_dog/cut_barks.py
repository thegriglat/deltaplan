"""DOG-K3: нарезка одиночных гавков (Freesound, CC0) -> assets/easter_eggs/start_dog/bark_<n>.ogg.

Запуск: python3 -I tools/research/start_dog/cut_barks.py <каталог_с_mp3> <out_dir> [<json_out>]
Каждый источник: ffmpeg -> моно 48 кГц float; огибающая RMS 5 мс; гавк = первый (или самый громкий —
по BARKS[id]["pick"]) непрерывный участок выше порога -32 дБ от пика; края: 8 мс до начала, хвост
до спада ниже порога + 20 мс, затухание 15 мс; нормировка пика к -3 dBFS; ogg vorbis q5.
Печатает длительность, пик, тишину по краям, основной тон (автокорреляция) и спектральный центроид.
"""
import json, os, subprocess, sys
import numpy as np

SR = 48000
BARKS = {  # id Freesound -> что брать
    "630648": {"pick": "loudest"},   # haulaway: single bark - small to medium dog
    "535457": {"pick": "loudest"},   # exe2be: Single bark of a dog
    "277058": {"pick": "loudest"},   # kwahmah_02: Single Dog Bark
    "699822": {"pick": "loudest"},   # 8bitmyketison: Dog Bark.wav
}


def decode(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()


def envelope_db(x, win=int(0.005 * SR)):
    n = len(x) // win
    rms = np.sqrt(np.mean(x[: n * win].reshape(n, win) ** 2, axis=1) + 1e-12)
    return 20 * np.log10(rms / (rms.max() + 1e-12)), win


def segments(mask):
    segs, start = [], None
    for i, m in enumerate(mask):
        if m and start is None:
            start = i
        if not m and start is not None:
            segs.append((start, i)); start = None
    if start is not None:
        segs.append((start, len(mask)))
    return segs


def f0_acf(x):
    x = x - x.mean()
    a = np.correlate(x, x, "full")[len(x) - 1:]
    lo, hi = int(SR / 1500), int(SR / 120)
    k = lo + int(np.argmax(a[lo:hi]))
    return SR / k


def edge_silence_ms(y, thr_db=-40):
    env, win = envelope_db(y, int(0.002 * SR))
    above = np.where(env > thr_db)[0]
    return (above[0] * win / SR * 1000, (len(env) - 1 - above[-1]) * win / SR * 1000) if len(above) else (0, 0)


def main():
    src, out = sys.argv[1], sys.argv[2]
    jout = sys.argv[3] if len(sys.argv) > 3 else None
    os.makedirs(out, exist_ok=True)
    res = []
    for n, (sid, opt) in enumerate(BARKS.items(), start=1):
        x = decode(os.path.join(src, sid + ".mp3"))
        env, win = envelope_db(x)
        segs = [s for s in segments(env > -32) if (s[1] - s[0]) * win / SR > 0.06]
        # склеить участки с разрывом < 40 мс (один гавк с провалом)
        merged = []
        for s in segs:
            if merged and (s[0] - merged[-1][1]) * win / SR < 0.04:
                merged[-1] = (merged[-1][0], s[1])
            else:
                merged.append(s)
        seg = max(merged, key=lambda s: env[s[0]:s[1]].max() + 0.001 * (s[1] - s[0]))
        a = max(0, seg[0] * win - int(0.008 * SR))
        b = min(len(x), seg[1] * win + int(0.020 * SR))
        y = x[a:b].copy()
        fade = int(0.015 * SR)
        y[-fade:] *= np.linspace(1, 0, fade)
        y[: int(0.002 * SR)] *= np.linspace(0, 1, int(0.002 * SR))
        y *= 10 ** (-3 / 20) / np.abs(y).max()
        dst = os.path.join(out, "bark_%d.ogg" % n)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", "-",
                        "-c:a", "libvorbis", "-q:a", "5", dst], input=y.astype(np.float32).tobytes(), check=True)
        chk = decode(dst)
        sil = edge_silence_ms(chk)
        spec = np.abs(np.fft.rfft(y)); fr = np.fft.rfftfreq(len(y), 1 / SR)
        r = {"file": os.path.basename(dst), "freesound_id": sid, "segments": len(merged),
             "dur_s": round(len(chk) / SR, 3), "peak_dbfs": round(float(20 * np.log10(np.abs(chk).max())), 2),
             "edge_silence_ms": [round(float(s), 1) for s in sil], "f0_hz": round(float(f0_acf(y)), 0),
             "centroid_hz": round(float((spec * fr).sum() / spec.sum()), 0)}
        res.append(r)
        print(json.dumps(r, ensure_ascii=False))
    if jout:
        with open(jout, "w") as fh:
            json.dump(res, fh, ensure_ascii=False, indent=1)


main()
