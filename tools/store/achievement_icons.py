#!/usr/bin/env python3
"""Иконки ачивок Steam (SA-К4 v3): пакетная детерминированная генерация на локальной NVIDIA.

  python3 tools/store/achievement_icons.py --config configs/achievements.json \
      --prompts tools/store/achievements/prompts.json --out steam/store/achievements [--dry]

--dry: без GPU, без torch и без загрузки модели; печатает план и строку
`ICONS PLAN ok=<n> missing=<m>` (код 1, если missing > 0). Только стандартная библиотека.
Без --dry: нужны зависимости из tools/store/achievements/pyproject.toml (uv) и GPU.
Список ачивок — только из --config (S6 модуля steam: achievements[].api).
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

OUT_SIZE = 256
LOCKED_BRIGHTNESS = 0.55  # закрытая версия: оттенки серого и затемнение


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def make_plan(cfg, prompts):
    """[(api, статус, seed, полный промпт)]; статус 'ok' или 'missing'."""
    icons = prompts.get("icons", {})
    plan = []
    for a in cfg["achievements"]:
        api = a["api"]
        ic = icons.get(api)
        if ic and str(ic.get("subject", "")).strip() and isinstance(ic.get("seed"), int):
            plan.append((api, "ok", ic["seed"], prompts["style"] + ic["subject"].strip()))
        else:
            plan.append((api, "missing", None, None))
    return plan


def print_plan(plan, cfg, prompts):
    names = {a["api"]: a.get("name", {}).get("en", "") for a in cfg["achievements"]}
    for api, st, seed, _ in plan:
        print(f"{api:24s} {st:8s} seed={seed} {names[api]}")
    extra = sorted(set(prompts.get("icons", {})) - set(names))
    for api in extra:
        print(f"{api:24s} extra    (есть в prompts.json, нет в конфиге — пропускается)")
    ok = sum(1 for p in plan if p[1] == "ok")
    miss = len(plan) - ok
    print(f"ICONS PLAN ok={ok} missing={miss}")
    return miss


def locked_from(img):
    """Закрытая иконка из открытой: оттенки серого + затемнение (детерминированно, Pillow)."""
    from PIL import ImageEnhance
    return ImageEnhance.Brightness(img.convert("L").convert("RGB")).enhance(LOCKED_BRIGHTNESS)


def save_pair(src, out_dir, api):
    from PIL import Image
    img = src.convert("RGB").resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)
    img.save(out_dir / f"{api}.jpg", quality=92, subsampling=0)
    locked_from(img).save(out_dir / f"{api}_locked.jpg", quality=92, subsampling=0)


def _flux_imports():
    import torch
    if not torch.cuda.is_available():
        sys.exit("CUDA недоступна — генерация только на NVIDIA GPU (проверка: --dry)")
    return torch, torch.bfloat16


def encode_prompts(model, texts):
    """Стадия 1: только CLIP + T5 (nf4) на GPU; эмбеддинги всех промптов — на CPU, модели выгружаются."""
    torch, dt = _flux_imports()
    from diffusers import FluxPipeline
    from transformers import BitsAndBytesConfig as TfBnb, T5EncoderModel
    t5 = T5EncoderModel.from_pretrained(
        model["id"], revision=model["revision"], subfolder="text_encoder_2", torch_dtype=dt,
        quantization_config=TfBnb(load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_compute_dtype=dt))
    pipe = FluxPipeline.from_pretrained(model["id"], revision=model["revision"], transformer=None, vae=None,
                                        text_encoder_2=t5, torch_dtype=dt)
    pipe.text_encoder.to("cuda:0")
    out = {}
    with torch.no_grad():
        for t in texts:
            pe, pooled, _ = pipe.encode_prompt(prompt=t, prompt_2=None, device="cuda:0", max_sequence_length=256)
            out[t] = (pe.cpu(), pooled.cpu())
    del pipe, t5
    import gc
    gc.collect()
    torch.cuda.empty_cache()
    return out


def load_pipeline(model):
    """Стадия 2: transformer в nf4 (bitsandbytes) + VAE целиком на GPU; текстовых кодировщиков нет."""
    torch, dt = _flux_imports()
    from diffusers import BitsAndBytesConfig as DiffBnb, FluxPipeline, FluxTransformer2DModel
    tr = FluxTransformer2DModel.from_pretrained(
        model["id"], revision=model["revision"], subfolder="transformer", torch_dtype=dt,
        quantization_config=DiffBnb(load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_compute_dtype=dt))
    pipe = FluxPipeline.from_pretrained(model["id"], revision=model["revision"], transformer=tr,
                                        text_encoder=None, tokenizer=None, text_encoder_2=None,
                                        tokenizer_2=None, torch_dtype=dt)
    pipe.to("cuda:0")  # nf4 transformer ≈ 6 ГБ + VAE помещаются; выгрузка на CPU ломает 4-битный gemv bnb
    # декодирование 1024² целиком не влезает рядом с transformer; порог тайла у VAE FLUX — 1024, снижаем
    pipe.vae.enable_tiling()
    pipe.vae.tile_sample_min_size, pipe.vae.tile_latent_min_size = 512, 64
    return pipe


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True, help="configs/achievements.json (S6)")
    ap.add_argument("--prompts", required=True, help="tools/store/achievements/prompts.json")
    ap.add_argument("--out", required=True, help="каталог результата (steam/store/achievements)")
    ap.add_argument("--dry", action="store_true", help="только план, без GPU и модели")
    ap.add_argument("--cache", default=str(Path(__file__).parent / "achievements" / ".cache"),
                    help="кэш исходных PNG size×size (не в git)")
    ap.add_argument("--only", action="append", default=[], help="только эти API (можно несколько раз)")
    ap.add_argument("--force", action="store_true", help="перегенерировать, даже если кэш есть")
    args = ap.parse_args()

    cfg, prompts = load_json(args.config), load_json(args.prompts)
    plan = make_plan(cfg, prompts)
    if args.only:
        plan = [p for p in plan if p[0] in args.only]
    miss = print_plan(plan, cfg, prompts) if args.dry or any(p[1] == "missing" for p in plan) else 0
    if args.dry:
        return 1 if miss else 0
    if miss:
        print("Не все ачивки имеют промпт — дополните prompts.json (см. --dry).", file=sys.stderr)
        return 1

    from PIL import Image
    out, cache = Path(args.out), Path(args.cache)
    out.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    size = int(prompts["size"])
    pipe = None
    manifest = {"model": prompts["model"], "steps": prompts["steps"], "guidance": prompts["guidance"],
                "size": size, "icons": {}}
    def key_of(prompt, seed):
        return hashlib.sha256(f"{prompts['model']['revision']}|{prompt}|{seed}|{size}|{prompts['steps']}"
                              .encode()).hexdigest()[:16]
    todo = [prompt for api, _, seed, prompt in plan
            if args.force or not (cache / f"{api}_{key_of(prompt, seed)}.png").exists()]
    # 12 ГБ: кодировщики и transformer на GPU не одновременно — сначала все эмбеддинги, потом генерация
    embeds = encode_prompts(prompts["model"], sorted(set(todo))) if todo else {}
    for api, _, seed, prompt in plan:
        key = key_of(prompt, seed)
        png = cache / f"{api}_{key}.png"
        if prompt in embeds and (args.force or not png.exists()):
            if pipe is None:
                pipe = load_pipeline(prompts["model"])
            import torch
            gen = torch.Generator("cpu").manual_seed(seed)
            pe, pooled = (t.to("cuda:0") for t in embeds[prompt])  # пайплайн сам не переносит
            # FLUX.1-schnell — distilled, без CFG: поле negative контракта не используется моделью
            img = pipe(prompt_embeds=pe, pooled_prompt_embeds=pooled, height=size, width=size,
                       num_inference_steps=int(prompts["steps"]),
                       guidance_scale=float(prompts["guidance"]), generator=gen).images[0]
            img.save(png)
        save_pair(Image.open(png), out, api)
        manifest["icons"][api] = {"seed": seed, "prompt_key": key}
        print(f"{api} -> {out / (api + '.jpg')}")
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"ICONS DONE n={len(plan)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
