#!/usr/bin/env python3
"""Полный набор реплик пилота (PVO-3): Design -> Clone (Qwen3-TTS), PV-К3.

  ref   : gen_full.py ref  --out . [--seeds 5]          эталоны: ref_<voice>_<lang>.wav (VoiceDesign на своём языке, лучший seed)
  tone  : gen_full.py tone --config configs/pilot_voice.json --out assets/sounds/voice   реплики из tone_lines.json (VoiceDesign с тоном)
  lines : gen_full.py lines --config configs/pilot_voice.json --out assets/sounds/voice [--only voice/lang/id,...] [--attempt N]
Эталон выбирается не «на вкус»: медоид по косинусу эмбеддинга диктора (ECAPA) среди seed-кандидатов с CER=0 (Whisper).
Реплики: Base-модель, клон эталона своего языка (ref_audio+ref_text). Клон с английского эталона даёт акцент в русском,
длинный ровный эталон — дикторское чтение; поэтому эталон — короткие разговорные реплики на языке реплик.
Base не принимает instruct, поэтому тон — только текстом реплики и манерой эталона.
Попытка N: seed = 1000*N + индекс реплики (перегенерация при нарушении check_voice).
"""
import argparse, json, os, sys, time
import numpy as np, soundfile as sf, torch
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_voice import process, LANG

HERE = os.path.dirname(os.path.abspath(__file__))
REF_TEXT = {"ru": "Так, пошёл. Ох, болтает! Ну, держись.",
            "en": "Okay, here we go. Whoa, bumpy! Come on, hang in there."}
CASUAL = {"ru": " Native Russian speaker, speaking Russian with no foreign accent.",
          "en": " Native American English speaker."}
CASUAL_ALL = " Casual short remarks to oneself in flight, lively and spontaneous, not reading, not narrating."
DESIGN = "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
BASE = "Qwen/Qwen3-TTS-12Hz-1.7B-Base"

def load(name):
    from qwen_tts import Qwen3TTSModel
    return Qwen3TTSModel.from_pretrained(name, device_map="cuda:0", dtype=torch.bfloat16)

def do_ref(a):
    from check_voice import Embedder, Asr, norm_text, cer
    voices = json.load(open(os.path.join(HERE, "samples.json")))["voices"]
    m = load(DESIGN); emb = Embedder(); asr = Asr()
    info = {}
    for v, desc in voices.items():
      for lang in ("ru", "en"):
        cands = []; instr = desc + CASUAL[lang] + CASUAL_ALL
        for s in range(a.seeds):
            torch.manual_seed(100 + s)
            w, sr = m.generate_voice_design(text=REF_TEXT[lang], language=LANG[lang], instruct=instr)
            x = np.asarray(w[0], dtype=np.float32)
            e = emb(x, sr); c = cer(norm_text(REF_TEXT[lang]), norm_text(asr(x, sr, lang)))
            cands.append(dict(seed=100 + s, x=x, sr=sr, e=e, cer=c, dur=len(x) / sr))
        for i, c in enumerate(cands):
            c["sim"] = float(np.mean([float(c["e"] @ d["e"]) for j, d in enumerate(cands) if j != i]))
        ok = [c for c in cands if c["cer"] <= 0.05 and 2.0 <= c["dur"] <= 9.0] or cands
        best = max(ok, key=lambda c: c["sim"])
        sf.write(os.path.join(a.out, f"ref_{v}_{lang}.wav"), best["x"], best["sr"], subtype="PCM_16")
        info[f"{v}_{lang}"] = dict(seed=best["seed"], text=REF_TEXT[lang], description=instr,
                       candidates=[dict(seed=c["seed"], cer=round(c["cer"], 3), sim_to_others=round(c["sim"], 3), dur_s=round(c["dur"], 2)) for c in cands])
        print(v, lang, info[f"{v}_{lang}"], flush=True)
    json.dump(info, open(os.path.join(a.out, "refs.json"), "w"), ensure_ascii=False, indent=1)

def spoken(ln, lang):
    p = os.path.join(HERE, "tts_text.json")
    return (json.load(open(p)).get(lang, {}) if os.path.exists(p) else {}).get(ln["id"], ln[lang])

def config_lines(path):
    cfg = json.load(open(path)); out = []
    for sid, s in cfg["situations"].items():
        for k, ln in enumerate(s["lines"], 1):
            out.append(dict(id=f"{sid}_{k}", ru=ln["ru"], en=ln["en"], tone=ln["tone"]))
    return cfg.get("voices", ["male", "female"]), out

def do_tone(a):
    """Ругань ровным голосом комична: реплики из tone_lines.json — VoiceDesign с тоном, N seed, ближайший по тембру к эталону."""
    from check_voice import Embedder
    tl = json.load(open(os.path.join(HERE, "tone_lines.json"))); voices, lines = config_lines(a.config)
    descs = json.load(open(os.path.join(HERE, "samples.json")))["voices"]; byid = {ln["id"]: ln for ln in lines}
    only = set(a.only.split(",")) if a.only else None
    m = load(DESIGN); emb = Embedder(); stats = []
    for v in voices:
        for lang in ("ru", "en"):
            w, sr0 = sf.read(os.path.join(HERE, f"ref_{v}_{lang}.wav"), dtype="float32"); ref = emb(w, sr0)
            instr0 = descs[v] + CASUAL[lang] + CASUAL_ALL + " Emotion and delivery: "
            for lid, tones in tl["lines"].items():
                if only and f"{v}/{lang}/{lid}" not in only: continue
                best = None
                for s in range(tl["seeds"]):
                    seed = 5000 + 100 * a.attempt + s; torch.manual_seed(seed)
                    w, sr = m.generate_voice_design(text=spoken(byid[lid], lang), language=LANG[lang], instruct=instr0 + tones[lang] + ".")
                    x = np.asarray(w[0], dtype=np.float32); sim = float(emb(x, sr) @ ref)
                    if best is None or sim > best[0]: best = (sim, x, sr, seed)
                d = os.path.join(a.out, v, lang); os.makedirs(d, exist_ok=True)
                st = process(best[1], best[2], os.path.join(d, lid + ".ogg"))
                st.update(voice=v, lang=lang, id=lid, mode="tone", seed=best[3], sim_ref=round(best[0], 3))
                st = {k: (float(x) if isinstance(x, np.floating) else x) for k, x in st.items()}
                stats.append(st); print(st, flush=True)
    if a.stats:
        old = json.load(open(a.stats)) if os.path.exists(a.stats) else []
        key = {(s["voice"], s["lang"], s["id"]): s for s in old}
        for s in stats: key[(s["voice"], s["lang"], s["id"])] = s
        json.dump(list(key.values()), open(a.stats, "w"), ensure_ascii=False, indent=1)

def do_lines(a):
    voices, lines = config_lines(a.config)
    only = set(a.only.split(",")) if a.only else None
    m = load(BASE); t0 = time.time(); stats = []
    for v in voices:
        for lang in ("ru", "en"):
            wav, sr0 = sf.read(os.path.join(HERE, f"ref_{v}_{lang}.wav"), dtype="float32")
            prompt = m.create_voice_clone_prompt(ref_audio=(wav, sr0), ref_text=REF_TEXT[lang])
            for i, ln in enumerate(lines):
                if only and f"{v}/{lang}/{ln['id']}" not in only: continue
                torch.manual_seed(1000 * a.attempt + i)
                t1 = time.time()
                w, sr = m.generate_voice_clone(text=spoken(ln, lang), language=LANG[lang], voice_clone_prompt=prompt)
                d = os.path.join(a.out, v, lang); os.makedirs(d, exist_ok=True)
                raw = os.path.join(a.raw, v, lang); os.makedirs(raw, exist_ok=True)
                sf.write(os.path.join(raw, ln["id"] + ".wav"), np.asarray(w[0], dtype=np.float32), sr)
                st = process(np.asarray(w[0]), sr, os.path.join(d, ln["id"] + ".ogg"))
                st.update(voice=v, lang=lang, id=ln["id"], attempt=a.attempt, gen_s=round(time.time() - t1, 2))
                st = {k: (float(x) if isinstance(x, np.floating) else x) for k, x in st.items()}
                stats.append(st); print(st, flush=True)
    if a.stats:
        old = json.load(open(a.stats)) if os.path.exists(a.stats) else []
        key = {(s["voice"], s["lang"], s["id"]): s for s in old}
        for s in stats: key[(s["voice"], s["lang"], s["id"])] = s
        json.dump(list(key.values()), open(a.stats, "w"), ensure_ascii=False, indent=1)
    print("total s", round(time.time() - t0), "peak VRAM GB", round(torch.cuda.max_memory_allocated() / 2**30, 2))

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("cmd", choices=["ref", "lines", "tone"])
    ap.add_argument("--out", default=HERE); ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--config"); ap.add_argument("--only"); ap.add_argument("--attempt", type=int, default=0)
    ap.add_argument("--raw", default=os.path.expanduser("~/data/pilot-voice/raw")); ap.add_argument("--stats")
    a = ap.parse_args()
    {"ref": do_ref, "lines": do_lines, "tone": do_tone}[a.cmd](a)
