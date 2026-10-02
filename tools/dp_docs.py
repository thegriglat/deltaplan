#!/usr/bin/env python3
"""dp docs — реестр и проверка документации Deltaplan (frontmatter, индекс, реестры, поиск).

  dp docs check                       frontmatter, живые md-ссылки, размер (код 1 при ошибках)
  dp docs index                       собрать docs/INDEX.md и docs/registry/{research,contracts,decisions}.md
  dp docs find [--type T] [--status S] [--module M] [текст]   строка на документ
  dp docs show <путь>                 frontmatter + оглавление (без тела)
  dp docs findings [текст] [--module M]   выдержки из docs/registry/findings.md
  dp docs init [--dry]                дописать frontmatter файлам без него (эвристики по пути и тексту)

Схема frontmatter (YAML, значения — JSON-строки/списки, читается и Obsidian, и Hugo):
  type: guide|plan|contract|research|reference|journal|registry
  status: active|idea|postponed|closed|superseded
  module, updated (ГГГГ-ММ-ДД), summary (1 строка), related: []
  research: conclusion, data, applied_in;  contract: contracts: [{id, version}]
  generated: true — файл собирается скриптом (проверка размера пропускается, руками не править)
Область проверки: docs/ (кроме docs/archive/, docs/plan/<модуль>/ с данными dp), tools/research/**/{README,summary}.md,
TODO.md, REQUIREMENTS.md.
"""
import argparse, json, os, re, subprocess, sys
from pathlib import Path

TYPES = {"guide", "plan", "contract", "research", "reference", "journal", "registry"}
STATUSES = {"active", "idea", "postponed", "closed", "superseded"}
MAX_KB = 40


def root():
    p = Path(__file__).resolve().parent.parent
    return p


ROOT = root()


# ---------- frontmatter ----------
def split_fm(text):
    """-> (dict|None, тело). Только плоский YAML: key: JSON-значение или голая строка."""
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---", 4)
    if end < 0:
        return None, text
    fm = {}
    for line in text[4:end].split("\n"):
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if not m:
            continue
        v = m.group(2).strip()
        try:
            fm[m.group(1)] = json.loads(v) if v else ""
        except ValueError:
            fm[m.group(1)] = v.strip("'\"")
    rest = text[end + 4:]
    return fm, rest[1:] if rest.startswith("\n") else rest


ORDER = ["type", "status", "module", "updated", "summary", "related", "conclusion", "data", "applied_in", "contracts", "generated"]


def dump_fm(fm):
    keys = [k for k in ORDER if k in fm] + [k for k in fm if k not in ORDER]
    return "---\n" + "".join(f"{k}: {json.dumps(fm[k], ensure_ascii=False)}\n" for k in keys) + "---\n"


def read(p):
    return Path(p).read_text(encoding="utf-8")


# ---------- область ----------
def scope():
    out = []
    for p in sorted((ROOT / "docs").rglob("*.md")):
        r = p.relative_to(ROOT).as_posix()
        if r.startswith("docs/archive/"):
            continue
        parts = r.split("/")
        if len(parts) > 3 and parts[1] == "plan" and (ROOT / "docs/plan" / parts[2] / "module.json").exists():
            continue
        out.append(r)
    for p in sorted((ROOT / "tools/research").rglob("*.md")):
        if p.name in ("README.md", "summary.md") and "/out/" not in p.as_posix():
            out.append(p.relative_to(ROOT).as_posix())
    out += [f for f in ("TODO.md", "REQUIREMENTS.md") if (ROOT / f).exists()]
    return out


def title_of(body, fallback):
    for l in body.split("\n"):
        if l.startswith("# "):
            return l[2:].strip()
    return fallback


def docs_all():
    res = []
    for r in scope():
        fm, body = split_fm(read(ROOT / r))
        res.append((r, fm, body))
    return res


# ---------- check ----------
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE = re.compile(r"```.*?```", re.S)


def check_links(r, body):
    bad = []
    body = FENCE.sub("", body)
    body = re.sub(r"`[^`\n]*`", "", body)
    for t in LINK.findall(body):
        if re.match(r"^[a-z][a-z0-9+.-]*:|^#", t):
            continue
        p = t.split("#")[0].split("?")[0]
        if not p:
            continue
        tgt = ROOT / p[1:] if p.startswith("/") else (ROOT / r).parent / p
        if not tgt.exists():
            bad.append(t)
    return bad


def contract_ids(body):
    res = []
    for l in body.split("\n"):
        m = re.match(r"^##\s+([A-ZА-ЯЁ]+\d+[a-z]*)[.\s].*?(?:\bv|версия\s+)(\d+)", l)
        if m:
            res.append({"id": m.group(1), "version": int(m.group(2))})
    return res


def cmd_check(a):
    err, warn = [], []
    items = docs_all()
    for r, fm, body in items:
        if fm is None:
            err.append(f"{r}: нет frontmatter")
            continue
        t, s = fm.get("type"), fm.get("status")
        if t not in TYPES:
            err.append(f"{r}: type '{t}' не из {sorted(TYPES)}")
        if s not in STATUSES:
            err.append(f"{r}: status '{s}' не из {sorted(STATUSES)}")
        if not str(fm.get("summary", "")).strip():
            err.append(f"{r}: пустой summary")
        if "\n" in str(fm.get("summary", "")):
            err.append(f"{r}: summary в несколько строк")
        if not fm.get("updated"):
            warn.append(f"{r}: нет updated")
        if not isinstance(fm.get("related", []), list):
            err.append(f"{r}: related — не список")
        if t == "research":
            for k in ("conclusion", "data", "applied_in"):
                if k not in fm:
                    warn.append(f"{r}: у research нет ключа {k}")
        if t == "contract":
            c = fm.get("contracts")
            if not isinstance(c, list):
                err.append(f"{r}: у contract нет списка contracts")
            else:
                live = {x["id"]: x["version"] for x in contract_ids(body)}
                have = {x.get("id"): x.get("version") for x in c if isinstance(x, dict)}
                if live and live != have:
                    warn.append(f"{r}: contracts во frontmatter ≠ заголовкам (dp docs init --refresh-contracts)")
        for rel in fm.get("related", []) if isinstance(fm.get("related"), list) else []:
            if not (ROOT / rel).exists():
                err.append(f"{r}: related → нет файла {rel}")
        for t_ in check_links(r, body):
            err.append(f"{r}: битая ссылка {t_}")
        kb = (ROOT / r).stat().st_size / 1024
        if kb > MAX_KB and not fm.get("generated"):
            warn.append(f"{r}: {kb:.0f} КБ > {MAX_KB} КБ — разбить или вынести данные")
    for e in err:
        print("ОШИБКА  " + e)
    for w in warn:
        print("предупр. " + w)
    print(f"dp docs check: файлов {len(items)}, ошибок {len(err)}, предупреждений {len(warn)}")
    return 1 if err else 0


# ---------- init (эвристики) ----------
MODULE_BY_NAME = [
    (r"air[-_]nn", "air-nn"), (r"air[-_]start", "air-start"), (r"air[-_]model|air_field|wind_field|slope_wind|thermals|surface_params|weather", "air-model"),
    (r"atmosphere", "atmosphere"), (r"flight|glider_polars|pilot_mass|control", "flight"), (r"net|multiplayer|itch", "net"),
    (r"wing|glider|atlas|models|telltale", "wings"), (r"terrain", "terrain"), (r"vegetation", "vegetation"),
    (r"instrument|vario|sound", "instruments"), (r"world|easter", "world"), (r"game|tasks|competition|xc_", "game"),
    (r"visual_cues|calibration|experimental|ordodi|start", "flight"), (r"ui", "ui"), (r"site", "site"),
]


def guess_module(r):
    name = Path(r).stem if Path(r).name not in ("README.md", "summary.md") else Path(r).parent.name
    for rx, m in MODULE_BY_NAME:
        if re.search(rx, name, re.I):
            return m
    return ""


PLAN_STATUS = {
    "docs/plan/README.md": "superseded", "docs/plan/wind_field.md": "superseded", "docs/plan/air_nn.md": "postponed", "docs/plan/air_nn_progress.md": "postponed",
    "docs/plan/air_model.md": "postponed", "docs/plan/air_model_a2.md": "postponed", "docs/plan/heat_ca_prototype.md": "idea",
    "docs/plan/offline_world_data.md": "postponed", "docs/plan/osm_vector_pack.md": "postponed",
    "docs/plan/on_demand_location.md": "idea", "docs/plan/multiplayer.md": "postponed",
}


def first_para(body):
    body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
    for para in re.split(r"\n\s*\n", body):
        lines = [l.strip() for l in para.strip().split("\n")]
        if not lines or not lines[0] or lines[0].startswith(("#", "|", "```", "---", "![", "<", "- [")):
            continue
        t = " ".join(l.lstrip("> ").lstrip("-* ").strip() for l in lines)
        t = re.sub(r"\*\*|`|\[([^\]]*)\]\([^)]*\)", lambda m: m.group(1) or "", t)
        t = re.sub(r"\s+", " ", t).strip()
        if len(t) < 12 or re.match(r"^(План\b|Внутренний документ|Статус:|Ветка |Задача |Требования:|[0-9.]+\s+Статус)", t):
            continue
        m = re.match(r"(.{40,}?[.!?])(\s|$)", t)
        t = m.group(1) if m and len(m.group(1)) <= 230 else t
        return (t[:227] + "…") if len(t) > 230 else t
    return ""


def conclusion_of(body):
    m = re.search(r"^#{2,4}\s+[^\n]*(?:Итог|Вывод|Резюме|Заключение|Результат)[^\n]*\n(.*?)(?=^#{1,4}\s|\Z)", body, re.S | re.M | re.I)
    return first_para(m.group(1)) if m else ""


def git_date(r):
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%cs", "--", r], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        return out or ""
    except OSError:
        return ""


def default_fm(r, body):
    if r.startswith("docs/contracts/"):
        t = "contract"
    elif r.startswith("docs/guide/"):
        t = "guide"
    elif r.startswith("docs/research/") or r.startswith("tools/research/"):
        t = "research"
    elif r.startswith("docs/plan/"):
        t = "journal" if r.endswith("_progress.md") else "plan"
    elif r in ("TODO.md", "REQUIREMENTS.md") or r.startswith("docs/registry/") or r == "docs/INDEX.md":
        t = "registry"
    else:
        t = "reference" if r.startswith("docs/screenshots/") else "guide"
    status = PLAN_STATUS.get(r, "active" if t in ("guide", "contract", "reference", "registry") else "closed")
    if r.startswith("docs/plan/game/"):
        status = "idea" if Path(r).name.startswith("04-") else "closed"
    fm = {"type": t, "status": status}
    mod = guess_module(r)
    if r.startswith("docs/contracts/"):
        mod = Path(r).stem
    fm["module"] = mod
    fm["updated"] = git_date(r) or __import__("datetime").date.today().isoformat()
    ttl = re.sub(r"\s+", " ", re.sub(r"`|\*\*", "", title_of(body, Path(r).stem)))
    para = first_para(body)
    fm["summary"] = (ttl + (" — " + para if para and para.lower() not in ttl.lower() else ""))[:300]
    fm["related"] = []
    if t == "research":
        fm["conclusion"] = conclusion_of(body)
        fm["data"] = str(Path(r).parent) + "/" if r.startswith("tools/research/") else ""
        fm["applied_in"] = ""
    if t == "contract":
        fm["contracts"] = contract_ids(body)
    if r in ("docs/INDEX.md",) or r.startswith("docs/registry/"):
        fm["generated"] = r != "docs/registry/findings.md"
        if not fm["generated"]:
            del fm["generated"]
    return fm


def cmd_init(a):
    n = 0
    for r in scope():
        p = ROOT / r
        fm, body = split_fm(read(p))
        if fm is not None:
            if a.refresh_contracts and fm.get("type") == "contract":
                fm["contracts"] = contract_ids(body)
                p.write_text(dump_fm(fm) + body, encoding="utf-8")
            continue
        fm = default_fm(r, body)
        n += 1
        if a.dry:
            print(r, fm["type"], fm["status"], fm["module"], "|", fm["summary"][:80])
        else:
            p.write_text(dump_fm(fm) + body, encoding="utf-8")
    print(f"frontmatter добавлен: {n}")
    return 0


# ---------- find / show / findings ----------
def cmd_find(a):
    q = (a.text or "").lower()
    n = 0
    for r, fm, body in docs_all():
        if fm is None:
            continue
        if a.type and fm.get("type") != a.type or a.status and fm.get("status") != a.status or a.module and fm.get("module") != a.module:
            continue
        hay = " ".join([r, str(fm.get("summary", "")), str(fm.get("conclusion", "")), str(fm.get("module", ""))]).lower()
        if q and not all(w in hay for w in q.split()):
            continue
        print(f"{r} — {fm.get('type')} — {fm.get('status')} — {fm.get('summary', '')[:160]}")
        n += 1
    if not n:
        print("ничего не найдено")
    return 0


def cmd_show(a):
    p = Path(a.path)
    p = p if p.is_absolute() else ROOT / a.path
    if not p.exists():
        print("нет файла: " + a.path)
        return 1
    fm, body = split_fm(read(p))
    print(dump_fm(fm).rstrip() if fm else "(нет frontmatter)")
    print()
    for i, l in enumerate(body.split("\n"), 1):
        if re.match(r"^#{1,4}\s", l):
            print(f"{l}   (строка {i})")
    return 0


def cmd_findings(a):
    p = ROOT / "docs/registry/findings.md"
    if not p.exists():
        print("нет docs/registry/findings.md")
        return 1
    _, body = split_fm(read(p))
    mod, q, n = "", (a.text or "").lower(), 0
    for l in body.split("\n"):
        if l.startswith("## "):
            mod = l[3:].strip()
        elif l.startswith("- ") and (not a.module or mod == a.module) and (not q or all(w in l.lower() for w in q.split())):
            print(f"[{mod}] {l[2:]}")
            n += 1
    if not n:
        print("ничего не найдено")
    return 0


# ---------- index ----------
def row(r, fm):
    return f"| [{r}](/{r}) | {fm.get('type')} | {fm.get('status')} | {fm.get('module', '')} | {str(fm.get('summary', '')).replace('|', '/')} |"


GEN_HEAD = "Файл собран `dp docs index` — руками не править.\n\n"


def write_gen(path, title, summary, body, typ="registry"):
    fm = {"type": typ, "status": "active", "module": "", "updated": "", "summary": summary, "related": [], "generated": True}
    import datetime
    fm["updated"] = datetime.date.today().isoformat()
    Path(ROOT / path).parent.mkdir(parents=True, exist_ok=True)
    (ROOT / path).write_text(dump_fm(fm) + f"\n# {title}\n\n" + GEN_HEAD + body, encoding="utf-8")


def cmd_index(a):
    items = [(r, fm, body) for r, fm, body in docs_all() if fm is not None]
    sections = [
        ("Описания систем (guide)", lambda r, fm: r.startswith("docs/guide/")),
        ("Контракты стыков", lambda r, fm: r.startswith("docs/contracts/")),
        ("Исследования в docs/research", lambda r, fm: r.startswith("docs/research/")),
        ("Исследования в tools/research", lambda r, fm: r.startswith("tools/research/")),
        ("Планы (живые и отложенные)", lambda r, fm: r.startswith("docs/plan/")),
        ("Реестры", lambda r, fm: r.startswith("docs/registry/") or r in ("TODO.md", "REQUIREMENTS.md", "docs/INDEX.md")),
    ]
    used, out = set(), []
    for title, pred in sections:
        rows = [(r, fm) for r, fm, _ in items if pred(r, fm) and r not in used and r != "docs/INDEX.md"]
        used.update(r for r, _ in rows)
        if rows:
            out.append(f"## {title}\n\n| путь | тип | статус | модуль | summary |\n|---|---|---|---|---|")
            out += [row(r, fm) for r, fm in rows]
            out.append("")
    rest = [(r, fm) for r, fm, _ in items if r not in used and r != "docs/INDEX.md"]
    if rest:
        out.append("## Прочее\n\n| путь | тип | статус | модуль | summary |\n|---|---|---|---|---|")
        out += [row(r, fm) for r, fm in rest]
        out.append("")
    arch = sorted((ROOT / "docs/archive").rglob("*.md")) if (ROOT / "docs/archive").exists() else []
    out.append(f"## Архив\n\n`docs/archive/plan/` — планы и журналы закрытых работ ({len(arch)} md, без frontmatter, из поиска по умолчанию исключены). "
               "Выводы из них — в [реестре выводов](/docs/registry/findings.md); таблица переносов — [moves](/docs/archive/moves.tsv).\n")
    head = ("Точка входа в документацию. Что мы знаем про X — [выводы](/docs/registry/findings.md), `dp docs find`, `dp docs findings`, "
            "`dp search`. Файл собран `dp docs index` — руками не править.\n")
    write_gen("docs/INDEX.md", "Индекс документации", "Все документы docs/ и паспорта исследований: путь, тип, статус, summary; точка входа.",
              "\n".join(out))
    # переписать вступление INDEX
    idx = ROOT / "docs/INDEX.md"
    t = idx.read_text(encoding="utf-8").replace(GEN_HEAD, head + "\n", 1)
    idx.write_text(t, encoding="utf-8")

    # research
    rrows = ["| тема | вывод | данные | применено | путь |", "|---|---|---|---|---|"]
    for r, fm, body in items:
        if fm.get("type") != "research":
            continue
        rrows.append("| {} | {} | {} | {} | [{}](/{}) |".format(
            title_of(body, Path(r).stem).replace("|", "/")[:90], str(fm.get("conclusion") or fm.get("summary", "")).replace("|", "/")[:300],
            str(fm.get("data", "")).replace("|", "/"), str(fm.get("applied_in", "")).replace("|", "/"), r, r))
    write_gen("docs/registry/research.md", "Реестр исследований", "Все исследования docs/research и tools/research: тема, вывод, данные, где применено.",
              "\n".join(rrows) + "\n")

    # contracts
    crows = ["| модуль | контракты (id vN) | файл |", "|---|---|---|"]
    for r, fm, body in items:
        if fm.get("type") == "contract":
            cs = ", ".join(f"{c['id']} v{c['version']}" for c in fm.get("contracts", []) if isinstance(c, dict))
            crows.append(f"| {fm.get('module', '')} | {cs} | [{r}](/{r}) |")
    write_gen("docs/registry/contracts.md", "Реестр контрактов", "Контракты стыков по модулям: идентификаторы и версии из заголовков.", "\n".join(crows) + "\n")

    # decisions
    drows = []
    total = 0
    for d in sorted((ROOT / "docs/plan").glob("*/decisions.jsonl")):
        recs = []
        for l in d.read_text(encoding="utf-8").splitlines():
            try:
                recs.append(json.loads(l))
            except ValueError:
                pass
        if not recs:
            continue
        drows.append(f"## {d.parent.name}\n")
        for x in sorted(recs, key=lambda x: x.get("t", "")):
            txt = " ".join(str(x.get("text", "")).split())
            why = " ".join(str(x.get("why", "")).split())
            line = f"- {str(x.get('t', ''))[:10]} {x.get('kind', 'decision')}: {txt[:400]}" + (f" — почему: {why[:240]}" if why else "")
            drows.append(line)
            total += 1
        drows.append("")
    write_gen("docs/registry/decisions.md", "Реестр решений", f"Решения всех модулей из decisions.jsonl ({total} записей), по модулям.", "\n".join(drows))
    print(f"dp docs index: INDEX.md, registry/research|contracts|decisions.md (решений {total})")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="dp docs", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    sp.add_parser("check").set_defaults(fn=cmd_check)
    sp.add_parser("index").set_defaults(fn=cmd_index)
    q = sp.add_parser("find"); q.add_argument("text", nargs="?"); q.add_argument("--type"); q.add_argument("--status"); q.add_argument("--module"); q.set_defaults(fn=cmd_find)
    q = sp.add_parser("show"); q.add_argument("path"); q.set_defaults(fn=cmd_show)
    q = sp.add_parser("findings"); q.add_argument("text", nargs="?"); q.add_argument("--module"); q.set_defaults(fn=cmd_findings)
    q = sp.add_parser("init"); q.add_argument("--dry", action="store_true"); q.add_argument("--refresh-contracts", action="store_true"); q.set_defaults(fn=cmd_init)
    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
