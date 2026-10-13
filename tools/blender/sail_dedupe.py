"""Дедупликация карт паруса (assets/shaders/sail/): побайтово одинаковые *_normal.png / *_trans.png
остаются одним файлом (первый по алфавиту), остальные удаляются, соответствие пишется в
assets/shaders/sail/sail_maps.json {крыло: {normal: имя, trans: имя}} — читает SailMaterial.
Вызывается из sail_maps.make() (expand до записи карты, dedupe после), отдельно запускать не нужно;
вручную: python3 tools/blender/sail_dedupe.py (из корня проекта).
Размер: 48 нормалей -> 19, 48 просветов -> 30 (одинаковые параметры генерации у многих крыльев)."""
import hashlib
import json
import os
import shutil

KINDS = ("normal", "trans")


def _load(d: str) -> dict:
    p = os.path.join(d, "sail_maps.json")
    return json.load(open(p)) if os.path.exists(p) else {}


def expand(d: str) -> None:
    """Вернуть удалённые дубликаты копиями канонических файлов (перед перегенерацией карты)."""
    for wing, m in _load(d).items():
        for kind, canon in m.items():
            dst = os.path.join(d, "%s_%s.png" % (wing, kind))
            src = os.path.join(d, "%s_%s.png" % (canon, kind))
            if not os.path.exists(dst) and os.path.exists(src):
                shutil.copyfile(src, dst)


def dedupe(d: str) -> dict:
    """Слить одинаковые карты, записать sail_maps.json. Ожидает полный набор файлов (после expand)."""
    mapping = {}
    for kind in KINDS:
        suf = "_%s.png" % kind
        names = sorted(f[:-len(suf)] for f in os.listdir(d) if f.endswith(suf))
        canon = {}
        for n in names:
            h = hashlib.md5(open(os.path.join(d, n + suf), "rb").read()).hexdigest()
            c = canon.setdefault(h, n)
            mapping.setdefault(n, {})[kind] = c
            if c != n:
                for ext in ("", ".import"):
                    p = os.path.join(d, n + suf + ext)
                    if os.path.exists(p):
                        os.remove(p)
    with open(os.path.join(d, "sail_maps.json"), "w") as f:
        json.dump(dict(sorted(mapping.items())), f, indent=1, ensure_ascii=False)
    return mapping


if __name__ == "__main__":
    D = "assets/shaders/sail"
    expand(D)
    print("крыльев", len(dedupe(D)))
