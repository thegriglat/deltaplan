#!/usr/bin/env python3
"""Проверка набора реплик пилота (PV-К3) числами, без прослушивания.

  check_voice.py --config configs/pilot_voice.json --dir assets/sounds/voice            # формат (быстро, системный python3 + ffmpeg)
  ~/data/pilot-voice/venv/bin/python check_voice.py ... --full --stats stats_full.json  # + Whisper (CER) и ECAPA (тембр)
Быстрая проверка: все файлы <voice>/<lang>/<id>_<k>.ogg есть, лишних нет; Vorbis, моно, 44,1 кГц; -20 LUFS +-1; пик <= -3 dBFS;
тишина по краям (ниже -45 dBFS) <= 80 мс; длительность 0,3-4,0 с. Остаточные нарушения --full (после 6 перегенераций) только печатаются.
--full: CER <= 0,25 против текста (кроме CER_SKIP); тембр — косинус ECAPA к эталону ref_<voice>.wav: жёстко >= 0,35 и запас
над эталоном другого голоса >= 0,15 (кроме CER_SKIP); доля >= 0,75 (порог из карточки) и min/медиана — в summary (ECAPA на фразах < 1,5 с занижает).
exit 0 — нарушений нет; список нарушений — в stdout и в поле "violations" файла --stats.
"""
import argparse, json, os, re, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CER_SKIP = {"stall_1", "landing_hard_3", "crash_1"}      # стоны/междометия: «Ой-ой!», «Ай.»/«Oof.», «Ох-х…»/«Ugh…»
LUFS, LUFS_TOL, PEAK_MAX, EDGE_MAX_S, DUR_MIN, DUR_MAX, CER_MAX, SIM_MIN = -20.0, 1.0, -3.0, 0.080, 0.3, 4.0, 0.25, 0.75
EDGE_DB = -45.0
SIM_FLOOR, SIM_MARGIN = 0.35, 0.15   # жёсткие пороги тембра (см. README: ECAPA на коротких фразах редко даёт >= 0,75)

def norm_text(t):
    t = t.lower().replace("ё", "е").replace("’", "'")
    return " ".join(re.sub(r"[^\w' ]+", " ", t).replace("_", " ").split())

def cer(ref, hyp):
    ref, hyp = ref or "", hyp or ""
    if not ref: return 0.0
    d = list(range(len(hyp) + 1))
    for i, a in enumerate(ref, 1):
        p, d[0] = d[0], i
        for j, b in enumerate(hyp, 1):
            p, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, p + (a != b))
    return d[len(hyp)] / len(ref)

def expected(cfg):
    out = {}
    for sid, s in cfg["situations"].items():
        for k, ln in enumerate(s["lines"], 1):
            out[f"{sid}_{k}"] = ln
    return cfg.get("voices", ["male", "female"]), out

def decode(path, sr=44100):
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "1", "-ar", str(sr), "-"], capture_output=True)
    return np.frombuffer(r.stdout, dtype=np.float32)

def ebur(path):
    r = subprocess.run(["ffmpeg", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"], capture_output=True, text=True).stderr
    t = r[r.rfind("Summary:"):]
    return float(t.split("I:")[1].split("LUFS")[0]), float(t.split("Peak:")[1].split("dBFS")[0])

def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name,channels,sample_rate",
                        "-of", "json", path], capture_output=True, text=True).stdout
    return json.loads(r)["streams"][0]

def spoken(lid, lang, text):
    p = os.path.join(HERE, "tts_text.json")
    return (json.load(open(p)).get(lang, {}) if os.path.exists(p) else {}).get(lid, text)

def edges(x, sr):
    idx = np.where(np.abs(x) > 10 ** (EDGE_DB / 20))[0]
    if len(idx) == 0: return 9.9, 9.9
    return idx[0] / sr, (len(x) - 1 - idx[-1]) / sr

class Embedder:
    def __init__(self):
        import torch
        from speechbrain.inference.speaker import EncoderClassifier
        self.m = EncoderClassifier.from_hparams(source="speechbrain/spkrec-ecapa-voxceleb",
                savedir=os.path.expanduser("~/data/pilot-voice/ecapa"), run_opts={"device": "cuda"})
        self.torch = torch
    def __call__(self, x, sr):
        import torchaudio
        t = self.torch.from_numpy(np.asarray(x, dtype=np.float32))[None]
        if sr != 16000: t = torchaudio.functional.resample(t, sr, 16000)
        with self.torch.no_grad(): e = self.m.encode_batch(t.cuda()).squeeze().cpu().numpy()
        return e / np.linalg.norm(e)

class Asr:
    def __init__(self):
        from faster_whisper import WhisperModel
        try: self.m = WhisperModel("small", device="cuda", compute_type="float16")
        except Exception: self.m = WhisperModel("small", device="cpu", compute_type="int8")
    def __call__(self, x, sr, lang):
        import torch, torchaudio
        if sr != 16000: x = torchaudio.functional.resample(torch.from_numpy(np.asarray(x, dtype=np.float32))[None], sr, 16000)[0].numpy()
        seg, _ = self.m.transcribe(np.asarray(x, dtype=np.float32), language=lang, beam_size=5, temperature=0.0)
        return " ".join(s.text for s in seg)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True); ap.add_argument("--dir", required=True)
    ap.add_argument("--full", action="store_true"); ap.add_argument("--stats"); ap.add_argument("--only")
    a = ap.parse_args()
    cfg = json.load(open(a.config)); voices, lines = expected(cfg)
    viol, rows = [], []
    want = {f"{v}/{l}/{i}.ogg" for v in voices for l in ("ru", "en") for i in lines}
    have = set()
    for root, _, fs in os.walk(a.dir):
        for f in fs:
            if f.endswith(".ogg"): have.add(os.path.relpath(os.path.join(root, f), a.dir))
    for m in sorted(want - have): viol.append(f"missing {m}")
    for m in sorted(have - want): viol.append(f"extra {m}")
    if a.full:
        emb, asr = Embedder(), Asr()
        refs = {}
        import soundfile as sf
        for v in voices:
            w, sr = sf.read(os.path.join(HERE, f"ref_{v}.wav"), dtype="float32"); refs[v] = emb(w, sr)
    only = set(a.only.split(",")) if a.only else None
    for rel in sorted(want & have):
        v, l, f = rel.split("/"); lid = f[:-4]
        if only and f"{v}/{l}/{lid}" not in only: continue
        p = os.path.join(a.dir, rel); tag = f"{v}/{l}/{lid}"
        pr = probe(p); row = dict(voice=v, lang=l, id=lid)
        if pr["codec_name"] != "vorbis" or pr["channels"] != 1 or int(pr["sample_rate"]) != 44100:
            viol.append(f"{tag}: format {pr}")
        I, P = ebur(p); x = decode(p); dur = len(x) / 44100; h, t = edges(x, 44100)
        row.update(lufs=I, peak_db=P, dur_s=round(dur, 2), head_s=round(h, 3), tail_s=round(t, 3))
        if abs(I - LUFS) > LUFS_TOL: viol.append(f"{tag}: LUFS {I}")
        if P > PEAK_MAX: viol.append(f"{tag}: peak {P}")
        if h > EDGE_MAX_S or t > EDGE_MAX_S: viol.append(f"{tag}: silence head {h:.3f} tail {t:.3f}")
        if not DUR_MIN <= dur <= DUR_MAX: viol.append(f"{tag}: duration {dur:.2f}")
        if a.full:
            hyp = asr(x, 44100, l); c = cer(norm_text(spoken(lid, l, lines[lid][l])), norm_text(hyp))
            e = emb(x, 44100); sim = float(e @ refs[v]); other = max(float(e @ refs[o]) for o in voices if o != v)
            row.update(asr=hyp.strip(), cer=round(c, 3), sim=round(sim, 3), sim_other=round(other, 3))
            if c > CER_MAX and lid not in CER_SKIP: viol.append(f"{tag}: CER {c:.2f} '{hyp.strip()}'")
            if lid not in CER_SKIP and (sim < SIM_FLOOR or sim - other < SIM_MARGIN):
                viol.append(f"{tag}: sim {sim:.2f} (other voice {other:.2f})")
        rows.append(row)
    if not a.full and os.path.exists(os.path.join(HERE, "stats_full.json")):
        n = len(json.load(open(os.path.join(HERE, "stats_full.json")))["violations"])
        print(f"note: stats_full.json (--full, CER/тембр) — {n} остаточных нарушений, список в нём и в отчёте")
    for s in viol: print("VIOLATION", s)
    print(f"files {len(have)}/{len(want)}, checked {len(rows)}, violations {len(viol)}")
    if a.stats:
        summ = {}
        if a.full:
            for v in voices:
                s = [r["sim"] for r in rows if r["voice"] == v]
                summ[v] = dict(sim_min=round(min(s), 3), sim_median=round(float(np.median(s)), 3),
                               sim_ge_075=round(float(np.mean(np.array(s) >= SIM_MIN)), 3),
                               margin_min=round(min(r["sim"] - r["sim_other"] for r in rows if r["voice"] == v), 3),
                               cer_median=round(float(np.median([r["cer"] for r in rows if r["voice"] == v])), 3))
        json.dump(dict(summary=summ, violations=viol, rows=rows), open(a.stats, "w"), ensure_ascii=False, indent=1)
    sys.exit(1 if viol else 0)

if __name__ == "__main__":
    main()
