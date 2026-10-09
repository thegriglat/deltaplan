#!/usr/bin/env python3
"""Записать hang_drop_m в configs/wings/<id>.json (visual) из вывода tools/flight/hang_drop_fit.gd.
Использование: python3 tools/research/pilot_view/apply_hang_drop.py drop.json
Правит текст (формат файлов сохраняется): вставляет/заменяет ключ сразу после "visual": {."""
import json, re, sys
DOC = ("Длина подвески под крыло (A3.5 v8): на сколько пилот в полёте ниже модельной подвески "
       "pilot.json → hang_length_m, м. Даёт зазор низ тела — верх штанги = pilot.json → bar_gap_m "
       "у этого крыла; считает tools/flight/hang_drop_fit.gd (пересчитать при смене модели крыла/штанги)")
drops = json.load(open(sys.argv[1]))
for wid, d in drops.items():
    p = f"configs/wings/{wid}.json"
    s = open(p, encoding="utf-8").read()
    s = re.sub(r'\n\s*"hang_drop_m(_doc)?": [^\n]*,(?=\n)', "", s)
    m = re.search(r'"visual": \{\n(\s*)', s)
    ind = m.group(1)
    ins = f'{ind}"hang_drop_m": {d},\n{ind}"hang_drop_m_doc": {json.dumps(DOC, ensure_ascii=False)},\n{ind}'
    s = s[:m.end() - len(ind)] + ins + s[m.end():]
    json.loads(s)
    open(p, "w", encoding="utf-8").write(s)
print(len(drops), "крыльев")
