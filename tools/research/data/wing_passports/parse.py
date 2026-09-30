"""Пакетный разбор текстов паспортов локальной LLM (ollama, температура 0, JSON по схеме).
Каждое число приходит как {value, unit, quote}; конвертация единиц и проверки — в validate.py.
Запуск: python3 parse.py [--model qwen3.5:9b] [--only подстрока] """
import re, json, sys, time, subprocess, hashlib, argparse, pathlib, requests
from bs4 import BeautifulSoup
from common import RAW, ROOT
ap = argparse.ArgumentParser(); ap.add_argument("--model", default="qwen3.5:9b"); ap.add_argument("--only", default="")
ap.add_argument("--limit", type=int, default=0); args = ap.parse_args()
OUT = ROOT / "out"; TXT = OUT / "text"; TXT.mkdir(parents=True, exist_ok=True)
EXT = OUT / f"extracted_{args.model.replace(':','_')}.jsonl"
NUM = ["area", "span", "aspect_ratio", "double_surface_pct", "wing_mass", "pilot_mass_min", "pilot_mass_max",
       "takeoff_mass_min", "takeoff_mass_max", "vne", "va", "stall_speed", "trim_speed", "vms", "vd",
       "vmin_vg0", "vmin_vg100", "vmax_vg0", "vmax_vg100", "best_glide", "nose_angle", "battens", "year"]
STR = ["manufacturer", "model", "size", "cert_class", "cert_standard"]
SCHEMA = {"type": "object", "properties": {"wings": {"type": "array", "items": {"type": "object",
    "properties": {**{k: {"type": "string"} for k in STR},
        "facts": {"type": "array", "items": {"type": "object", "properties": {"field": {"type": "string", "enum": NUM},
            "value": {"type": "number"}, "unit": {"type": "string"}, "quote": {"type": "string"}}, "required": ["field", "value", "unit", "quote"]}}},
    "required": STR + ["facts"]}}}, "required": ["wings"]}
PROMPT = """Ты извлекаешь технические характеристики дельтапланов (hang glider) из текста страницы или руководства.
Верни JSON: список wings, по одной записи на каждую модель И каждый типоразмер (например T3 144 и T3 154 - две записи). Числовые характеристики - в списке facts: по одному элементу {field, value, unit, quote} на каждое найденное значение; поля, которых нет в тексте, просто не включай.
Правила:
- Только то, что явно написано в тексте. Ничего не выдумывай и не вычисляй; отсутствующее не включай.
- value - число ровно как в тексте (без пересчёта единиц), unit - единица как в тексте (m2, sq ft, m, ft, in, kg, lb, km/h, mph, kt, %, deg, mm), quote - точный короткий фрагмент текста (до 120 символов), где это число.
- area=площадь крыла; span=размах; aspect_ratio=удлинение; double_surface_pct=доля двойной поверхности; wing_mass=масса самого крыла (glider weight);
  pilot_mass_min/max=диапазон массы пилота или hook-in/clip-in weight (без крыла); takeoff_mass_min/max=диапазон стартовой массы (take-off weight, Startgewicht, weight range);
  vne=never exceed speed; va=manoeuvring speed; stall_speed=скорость сваливания; trim_speed=трим/скорость трима; vms=скорость минимального снижения (Vms); vd=Vd min/скорость пикирования;
  vmin_vg0/vmin_vg100 и vmax_vg0/vmax_vg100=минимальная/максимальная скорость (Vmin/Vmax) при VG 0 % и VG 100 % (loose/tight, VG off/on);
  best_glide=заявленное лучшее качество (число X из X:1), условия в quote; nose_angle=угол при носе в градусах; battens=число латов; year=год сертификации/выпуска.
- Если у крыла указано несколько значений для разных размеров, а размер записи ясен - берите значение своего размера.
- manufacturer, model, size - строки (size пустая, если нет). cert_class - класс/категория (DHV 1/2/3, EN/LTF, Novice/Intermediate/Advanced и т.п.), cert_standard - номер сертификации, если есть.
- Если в тексте нет характеристик дельтаплана - верни {"wings": []}.
Источник: @SRC@
Текст:
@TXT@"""
def to_text(p: pathlib.Path) -> str:
    dest = TXT / (str(p.relative_to(RAW)).replace("/", "__") + ".txt")
    if dest.exists(): return dest.read_text()
    if p.suffix == ".pdf":
        t = subprocess.run(["pdftotext", "-layout", str(p), "-"], capture_output=True, text=True).stdout
    else:
        s = BeautifulSoup(p.read_bytes(), "html.parser")
        for x in s(["script", "style", "nav", "header", "footer", "noscript"]): x.decompose()
        t = s.get_text("\n")
    t = re.sub(r"[ \t ]+", " ", t); t = re.sub(r"\n\s*\n+", "\n", t)
    dest.write_text(t); return t
KEY = re.compile(r"(?i)(m2|m²|sq\.? ?ft|kg|lb|km/h|mph|span|area|fläche|spannweite|gewicht|aspect|speed|vne|vmax|vmin)")
def chunks(t, n=7000, ov=500):
    if len(t) <= n: return [t]
    out, i = [], 0
    while i < len(t):
        out.append(t[i:i + n]); i += n - ov
    return out
# документы: DHV - пара карточка+тест-отчёт в один текст; остальные - по файлу
docs = []
idx = json.load(open(RAW / "dhv/index.json")) if (RAW / "dhv/index.json").exists() else []
seen = set()
for r in [x for x in idx if x.get("data_file")]:
    t = to_text(RAW / r["data_file"]); 
    if r.get("test_file") and (RAW / r["test_file"]).exists(): t += "\n--- Testbericht ---\n" + to_text(RAW / r["test_file"])
    docs.append(dict(src=f"dhv:{r['data_file']}", url=r["url"], text=t, maker_hint=r["maker"], name_hint=r["name"]))
SKIP = ("archive_index", "production-history", "airworthiness", "bob-wills", "index.html", "Video", "Dealers", "Revisions", "Palmares")
for p in sorted(RAW.rglob("*")):
    if p.is_dir() or p.suffix not in (".html", ".pdf") or p.parts[len(RAW.parts)] in ("dhv",): continue
    if any(s in p.name for s in SKIP): continue
    docs.append(dict(src=str(p.relative_to(RAW)), url=None, text=to_text(p)))
mk = {}; 
try: mk = json.load(open(RAW / "makers_index.json"))
except Exception: pass
for d in docs:
    if d["url"] is None: d["url"] = mk.get(d["src"], {}).get("url", "file:" + d["src"])
done = set()
if EXT.exists():
    for l in EXT.read_text().splitlines(): done.add(json.loads(l)["chunk_id"])
todo = []
for d in docs:
    if args.only and args.only not in d["src"]: continue
    for i, c in enumerate(chunks(d["text"])):
        if len(KEY.findall(c)) < 4: continue
        cid = f"{d['src']}#{i}"
        if cid not in done: todo.append((cid, d, c))
if args.limit: todo = todo[:args.limit]
print(f"документов {len(docs)}, чанков к разбору {len(todo)}, модель {args.model}", flush=True)
t0 = time.time(); ntok = 0
with open(EXT, "a") as fo:
    for k, (cid, d, c) in enumerate(todo):
        hint = d["url"] + (f" (DHV: {d['name_hint']}, {d['maker_hint']})" if "name_hint" in d else "")
        body = {"model": args.model, "stream": False, "think": False, "format": SCHEMA,
                "messages": [{"role": "user", "content": PROMPT.replace("@SRC@", hint).replace("@TXT@", c)}],
                "options": {"temperature": 0, "num_ctx": 8192, "num_predict": 4000, "seed": 1}}
        try:
            r = requests.post("http://localhost:11434/api/chat", json=body, timeout=900).json()
            js = json.loads(r["message"]["content"]); ntok += r.get("eval_count", 0)
        except Exception as e:
            print("FAIL", cid, e, flush=True); js = {"wings": [], "error": str(e)}
        fo.write(json.dumps({"chunk_id": cid, "src": d["src"], "url": d["url"], "wings": js.get("wings", []), "error": js.get("error"),
                             "chunk_sha": hashlib.sha1(c.encode()).hexdigest()[:10]}, ensure_ascii=False) + "\n"); fo.flush()
        if k % 10 == 0: print(k, len(todo), f"{time.time()-t0:.0f}s", flush=True)
print(f"готово: {time.time()-t0:.0f}s, сгенерировано токенов {ntok}")
