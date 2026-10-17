"""Чтение слоёв места (far.webp, far_surface.webp, far_water.webp) в numpy. Запуск: python3 -I."""
import json, os
import numpy as np
from PIL import Image


def load_place(d):
    meta = json.load(open(os.path.join(d, "meta.json")))
    out = {}
    for L in meta["layers"]:
        im = Image.open(os.path.join(d, L["file"])).convert("RGB")
        a = np.asarray(im).astype(np.uint32)
        v = (a[..., 0] << 16) | (a[..., 1] << 8) | a[..., 2]
        out[L["id"]] = dict(h=L["height_min_m"] + L["height_step_m"] * v.astype(np.float64), info=L)
    far = out["far"]
    far["surface"] = np.asarray(Image.open(os.path.join(d, "far_surface.webp")).convert("L")) \
        if os.path.exists(os.path.join(d, "far_surface.webp")) else None
    far["water"] = np.asarray(Image.open(os.path.join(d, "far_water.webp")).convert("L")) \
        if os.path.exists(os.path.join(d, "far_water.webp")) else None
    return meta, out
