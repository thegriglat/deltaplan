#!/usr/bin/env python3
"""Генерация кандидатов через diffusers: Stable Audio Open 1.0 и AudioLDM2 (base/large).

  .venv-ldm/bin/python gen_diffusers.py --model sao|ldm2|ldm2l [--keys k1,k2] [--seeds 1,2,3]
Выход: out/<model>/<key>_s<seed>.wav (+ out/<model>/log.jsonl с промптом, seed, шагами).
Лицензии моделей: SAO — Stability AI Community License; AudioLDM2 — CC-BY-NC-SA 4.0 (⚠ NC).
"""
import argparse, json, os, time
import numpy as np, soundfile as sf, torch
from prompts import PROMPTS

MODELS = {
    "sao": ("stabilityai/stable-audio-open-1.0", 100),
    "ldm2": ("cvssp/audioldm2", 200),
    "ldm2l": ("cvssp/audioldm2-large", 200),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, choices=MODELS)
    ap.add_argument("--keys", default=",".join(PROMPTS))
    ap.add_argument("--seeds", default="1,2,3")
    a = ap.parse_args()
    repo, steps = MODELS[a.model]
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", a.model)
    os.makedirs(out, exist_ok=True)
    if a.model == "sao":
        from diffusers import StableAudioPipeline
        pipe = StableAudioPipeline.from_pretrained(repo, torch_dtype=torch.float16).to("cuda")
        sr = pipe.vae.sampling_rate
    else:
        from diffusers import AudioLDM2Pipeline
        pipe = AudioLDM2Pipeline.from_pretrained(repo, torch_dtype=torch.float16).to("cuda")
        sr = 16000
    log = open(os.path.join(out, "log.jsonl"), "a")
    for key in a.keys.split(","):
        prompt, neg, dur = PROMPTS[key]
        for seed in map(int, a.seeds.split(",")):
            f = os.path.join(out, f"{key}_s{seed}.wav")
            if os.path.exists(f):
                continue
            g = torch.Generator("cuda").manual_seed(seed)
            t = time.time()
            if a.model == "sao":
                audio = pipe(prompt, negative_prompt=neg, num_inference_steps=steps, audio_end_in_s=float(dur),
                             num_waveforms_per_prompt=1, generator=g).audios[0].T.float().cpu().numpy()
            else:
                audio = pipe(prompt, negative_prompt=neg, num_inference_steps=steps, audio_length_in_s=float(dur),
                             num_waveforms_per_prompt=1, generator=g).audios[0]
            sf.write(f, audio, sr, subtype="FLOAT")  # FLOAT: выход модели бывает > 1, PCM16 клиппирует
            rec = dict(model=repo, key=key, prompt=prompt, negative_prompt=neg, seed=seed, steps=steps,
                       duration_s=dur, sr=sr, gen_s=round(time.time() - t, 1))
            log.write(json.dumps(rec) + "\n"); log.flush()
            print(rec, flush=True)


if __name__ == "__main__":
    main()
