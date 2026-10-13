"""Дедупликация карт паруса (assets/shaders/sail/): побайтово одинаковые *_normal.png / *_trans.png
остаются одним файлом (первый по алфавиту), остальные удаляются, соответствие пишется в
assets/shaders/sail/sail_maps.json {крыло: {normal: имя, trans: имя}} — читает SailMaterial.
Запуск после tools/blender/sail_maps.py: python3 tools/blender/sail_dedupe.py (из корня проекта).
Размер: 48 нормалей -> 19, 48 просветов -> 30 (одинаковые параметры генерации у многих крыльев)."""
import hashlib
import json
import os

D = "assets/shaders/sail/"
mapping = {}
for kind in ("normal", "trans"):
    suf = "_%s.png" % kind
    names = sorted(f[:-len(suf)] for f in os.listdir(D) if f.endswith(suf))
    canon = {}
    for n in names:
        h = hashlib.md5(open(D + n + suf, "rb").read()).hexdigest()
        c = canon.setdefault(h, n)
        mapping.setdefault(n, {})[kind] = c
        if c != n:
            for ext in ("", ".import"):
                if os.path.exists(D + n + suf + ext):
                    os.remove(D + n + suf + ext)
    # уже дедуплицированные крылья (файла нет) остаются в mapping из прежнего json
old = {}
if os.path.exists(D + "sail_maps.json"):
    old = json.load(open(D + "sail_maps.json"))
for n, v in old.items():
    mapping.setdefault(n, {}).update({k: x for k, x in v.items() if k not in mapping.get(n, {})})
json.dump(dict(sorted(mapping.items())), open(D + "sail_maps.json", "w"), indent=1, ensure_ascii=False)
print("модулей", len(mapping))
