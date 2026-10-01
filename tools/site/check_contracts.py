"""Контрактный тест обновления сайта (docs/plan/site_update.md, «Контракты», v1).

    uv run -q --with pillow python tools/site/check_contracts.py [--only=C1,C2,C3]

C1 — рендеры крыльев docs/models/screenshots/glider_<id>/iso45.jpg;
C2 — страницы «Модели аппаратов»: tools/site/gen_wings.py --check (если генератор уже есть);
C3 — скриншоты сайта docs/screenshots/{gameplay,e2e,site}.
Код выхода 0 — всё по контракту, 1 — есть нарушения (список в выводе).
"""
import glob
import os
import subprocess
import sys

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
os.chdir(ROOT)
errors: list[str] = []


def jpeg(path: str, size: tuple | None, kb_min: float, kb_max: float) -> None:
    if not os.path.isfile(path):
        errors.append(f"нет файла {path}")
        return
    kb = os.path.getsize(path) / 1024
    if not kb_min <= kb <= kb_max:
        errors.append(f"{path}: {kb:.0f} КБ вне {kb_min:.0f}–{kb_max:.0f}")
    with Image.open(path) as im:
        if im.format != "JPEG":
            errors.append(f"{path}: формат {im.format}, нужен JPEG")
        if size and im.size != size:
            errors.append(f"{path}: {im.size[0]}×{im.size[1]}, нужен {size[0]}×{size[1]}")


def wing_ids() -> list[str]:
    return sorted(os.path.basename(f)[:-5] for f in glob.glob("configs/wings/*.json"))


def c1() -> None:
    total = 0.0
    for wid in wing_ids():
        p = f"docs/models/screenshots/glider_{wid}/iso45.jpg"
        jpeg(p, (1280, 720), 40, 250)
        if os.path.isfile(p):
            total += os.path.getsize(p) / 1024
    if total > 8 * 1024:
        errors.append(f"C1: все рендеры вместе {total / 1024:.1f} МБ > 8 МБ")


def c2() -> None:
    gen = "tools/site/gen_wings.py"
    if not os.path.isfile(gen):
        print("C2: генератора ещё нет — пропуск")
        return
    r = subprocess.run([sys.executable, gen, "--check"], capture_output=True, text=True)
    if r.returncode != 0:
        errors.append(f"C2: {gen} --check, код {r.returncode}:\n{r.stdout}{r.stderr}".rstrip())


def c3() -> None:
    for n in ("cockpit", "chase", "free"):
        jpeg(f"docs/screenshots/gameplay/{n}.jpg", None, 20, 1500)
    for f in sorted(glob.glob("configs/locations/*.json")):
        loc = os.path.basename(f)[:-5]
        for kind in ("flight", "result"):
            jpeg(f"docs/screenshots/e2e/{loc}_{kind}.jpg", None, 20, 1500)
    site = sorted(glob.glob("docs/screenshots/site/*.jpg"))
    if not site:
        errors.append("C3: нет кадров docs/screenshots/site/*.jpg")
    for p in site:
        jpeg(p, (1600, 900), 20, 350)
    if site and not os.path.isfile("docs/screenshots/site/README.md"):
        errors.append("C3: нет docs/screenshots/site/README.md (команды съёмки)")
    for p in glob.glob("docs/screenshots/site/*.png") + glob.glob("docs/screenshots/e2e/*.png"):
        errors.append(f"C3: png не по контракту: {p}")


def main() -> int:
    only = {"C1", "C2", "C3"}
    for a in sys.argv[1:]:
        if a.startswith("--only="):
            only = set(a[7:].upper().split(","))
    for name, fn in (("C1", c1), ("C2", c2), ("C3", c3)):
        if name in only:
            n = len(errors)
            fn()
            print(f"{name}: {'ок' if len(errors) == n else f'нарушений {len(errors) - n}'}")
    for e in errors:
        print(" -", e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
