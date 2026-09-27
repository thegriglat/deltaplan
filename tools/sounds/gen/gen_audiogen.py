#!/usr/bin/env python3
"""Генерация кандидатов AudioGen (facebook/audiogen-medium, audiocraft; веса CC-BY-NC 4.0 → ⚠ NC).

  .venv-ag/bin/python gen_audiogen.py [--keys k1,k2] [--seeds 1,2,3]
Выход: out/audiogen/<key>_s<seed>.wav (16 кГц моно) + log.jsonl.
AudioGen обучен на 10-секундных фрагментах: для длинных — продолжение окнами (extend_stride).
"""
import argparse, json, os, time
import soundfile as sf, torch
from audiocraft.models import AudioGen
from prompts import PROMPTS

REPO = "facebook/audiogen-medium"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keys", default=",".join(PROMPTS))
    ap.add_argument("--seeds", default="1,2,3")
    a = ap.parse_args()
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "audiogen")
    os.makedirs(out, exist_ok=True)
    model = AudioGen.get_pretrained(REPO, device="cuda")
    log = open(os.path.join(out, "log.jsonl"), "a")
    for key in a.keys.split(","):
        prompt, _neg, dur = PROMPTS[key]
        for seed in map(int, a.seeds.split(",")):
            f = os.path.join(out, f"{key}_s{seed}.wav")
            if os.path.exists(f):
                continue
            torch.manual_seed(seed)
            params = dict(duration=float(dur), use_sampling=True, top_k=250, temperature=1.0, cfg_coef=3.0, extend_stride=5.0)
            model.set_generation_params(**params)
            t = time.time()
            wav = model.generate([prompt])[0].cpu().numpy().T
            sf.write(f, wav, model.sample_rate, subtype="FLOAT")
            rec = dict(model=REPO, key=key, prompt=prompt, seed=seed, **params, sr=model.sample_rate,
                       gen_s=round(time.time() - t, 1))
            log.write(json.dumps(rec) + "\n"); log.flush()
            print(rec, flush=True)


if __name__ == "__main__":
    main()
