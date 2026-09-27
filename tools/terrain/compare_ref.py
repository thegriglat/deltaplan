"""Сравнение кадров стенда T01 с эталонными фото (docs/plan/terrain/01-stend-kadry-zamery.md, шаг 5).

Запуск (из корня проекта, после tools/terrain/shots.sh):
    uv run --with numpy --with pillow python tools/terrain/compare_ref.py <папка_кадров> [--out metrics.json]
        [--pairs S3:b,S5:a,S5:c]

Читает tools/terrain/shots.json (кадры + прямоугольники «лес»/«луг», полосы «близко/средне/далеко»,
линия профиля) и data/terrain/reference/sources.json (3 реальных фото с теми же разметками).
Для каждого кадра/фото считает:
    brightness_<rect> — средняя яркость (0..255) по прямоугольнику;
    contrast_<rect>   — RMS-контраст (стандартное отклонение яркости) по прямоугольнику;
    forest_meadow_ratio — brightness(forest) / brightness(meadow);
    far_near_contrast   — contrast(far) / contrast(near);
    profile (только если в кадре есть "profile"): яркость вдоль линии, ширина перехода 10→90 %
        (в долях длины линии) и позиция провала (локальный минимум) у кромки.
Результат — <папка_кадров>/metrics.json. По --pairs (по умолчанию S3:b,S5:a,S5:c) кладёт рядом
montage_<кадр>_<фото>.png (кадр слева, фото справа, оба приведены к одной высоте).
"""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SHOTS_JSON = ROOT / "tools" / "terrain" / "shots.json"
SOURCES_JSON = ROOT / "data" / "terrain" / "reference" / "sources.json"
REF_DIR = ROOT / "data" / "terrain" / "reference"


def _load_gray(path: Path) -> np.ndarray:
    img = Image.open(path).convert("L")
    return np.asarray(img, dtype=np.float64)


def _rect_px(rect: list, w: int, h: int) -> tuple:
    x0, y0, x1, y1 = rect
    return (
        max(0, int(x0 * w)),
        max(0, int(y0 * h)),
        min(w, int(x1 * w)),
        min(h, int(y1 * h)),
    )


def _region_stats(gray: np.ndarray, rects: list) -> tuple:
    """Среднее и RMS-контраст по объединению прямоугольников (доли ширины/высоты)."""
    h, w = gray.shape
    vals = []
    for r in rects:
        px0, py0, px1, py1 = _rect_px(r, w, h)
        if px1 > px0 and py1 > py0:
            vals.append(gray[py0:py1, px0:px1].ravel())
    if not vals:
        return 0.0, 0.0
    arr = np.concatenate(vals)
    return float(arr.mean()), float(arr.std())


def _profile_metrics(gray: np.ndarray, p0: list, p1: list, n: int = 64) -> dict:
    h, w = gray.shape
    xs = np.linspace(p0[0] * w, p1[0] * w, n)
    ys = np.linspace(p0[1] * h, p1[1] * h, n)
    xs = np.clip(xs, 0, w - 1)
    ys = np.clip(ys, 0, h - 1)
    vals = gray[ys.astype(int), xs.astype(int)].astype(np.float64)
    lo, hi = float(vals.min()), float(vals.max())
    span = hi - lo if hi > lo else 1.0
    norm = (vals - lo) / span
    # Ширина перехода 10% -> 90% (в долях длины линии), от начала линии.
    idx10 = next((i for i, v in enumerate(norm) if v >= 0.1), 0)
    idx90 = next((i for i, v in enumerate(norm) if v >= 0.9), n - 1)
    width_frac = abs(idx90 - idx10) / max(1, n - 1)
    dip_i = int(np.argmin(vals))
    return {
        "values": [round(v, 1) for v in vals.tolist()],
        "transition_width_frac": round(width_frac, 3),
        "dip_pos_frac": round(dip_i / max(1, n - 1), 3),
        "dip_value": round(float(vals[dip_i]), 1),
    }


def compute_metrics(gray: np.ndarray, spec: dict) -> dict:
    m: dict = {}
    for name, rects in spec.get("rects", {}).items():
        mean, std = _region_stats(gray, rects)
        m[f"brightness_{name}"] = round(mean, 1)
        m[f"contrast_{name}"] = round(std, 1)
    for name, rects in spec.get("strips", {}).items():
        mean, std = _region_stats(gray, rects)
        m[f"brightness_{name}"] = round(mean, 1)
        m[f"contrast_{name}"] = round(std, 1)
    if "brightness_forest" in m and m.get("brightness_meadow", 0) > 0:
        m["forest_meadow_ratio"] = round(m["brightness_forest"] / m["brightness_meadow"], 3)
    if m.get("contrast_near", 0) > 0:
        m["far_near_contrast"] = round(m.get("contrast_far", 0.0) / m["contrast_near"], 3)
    if "profile" in spec:
        m["profile"] = _profile_metrics(gray, spec["profile"]["p0"], spec["profile"]["p1"])
    return m


def _resize_to_height(img: Image.Image, height: int) -> Image.Image:
    w, h = img.size
    return img.resize((max(1, int(w * height / h)), height))


def make_montage(frame_path: Path, photo_path: Path, out_path: Path, height: int = 720) -> None:
    left = _resize_to_height(Image.open(frame_path).convert("RGB"), height)
    right = _resize_to_height(Image.open(photo_path).convert("RGB"), height)
    montage = Image.new("RGB", (left.width + right.width + 4, height), (255, 0, 0))
    montage.paste(left, (0, 0))
    montage.paste(right, (left.width + 4, 0))
    montage.save(out_path)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("shots_dir", help="Папка с кадрами <id>.png (результат shots.sh)")
    ap.add_argument("--out", default=None, help="Путь metrics.json (по умолчанию <shots_dir>/metrics.json)")
    ap.add_argument("--pairs", default="S3:b,S5:a,S5:c", help="Пары кадр:фото для монтажей")
    args = ap.parse_args()

    shots_dir = Path(args.shots_dir)
    shots = json.loads(SHOTS_JSON.read_text(encoding="utf-8"))
    sources = json.loads(SOURCES_JSON.read_text(encoding="utf-8"))

    result: dict = {"frames": {}, "photos": {}}

    for frame in shots["frames"]:
        fid = frame["id"]
        img_path = shots_dir / f"{fid}.png"
        if not img_path.exists():
            print(f"пропуск {fid}: нет {img_path}")
            continue
        gray = _load_gray(img_path)
        result["frames"][fid] = compute_metrics(gray, frame)

    for photo in sources["photos"]:
        pid = photo["id"]
        img_path = REF_DIR / photo["file"]
        if not img_path.exists():
            print(f"пропуск фото {pid}: нет {img_path}")
            continue
        gray = _load_gray(img_path)
        result["photos"][pid] = compute_metrics(gray, photo)

    out_path = Path(args.out) if args.out else shots_dir / "metrics.json"
    out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"metrics: {out_path} (кадров {len(result['frames'])}, фото {len(result['photos'])})")

    photos_by_id = {p["id"]: p for p in sources["photos"]}
    for pair in args.pairs.split(","):
        if not pair.strip():
            continue
        fid, pid = pair.split(":")
        photo = photos_by_id.get(pid)
        frame_path = shots_dir / f"{fid}.png"
        if photo is None or not frame_path.exists():
            print(f"пропуск монтажа {fid}|{pid}")
            continue
        out_montage = shots_dir / f"montage_{fid}_{pid}.png"
        make_montage(frame_path, REF_DIR / photo["file"], out_montage)
        print(f"монтаж: {out_montage}")


if __name__ == "__main__":
    main()
