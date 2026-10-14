"""dpcli docs — реестр и проверка документации (frontmatter, индекс, реестры, поиск).

  docs check                          frontmatter, summary, живые md-ссылки, размер (код 1 при ошибках)
  docs index                          собрать {docs_dir}/INDEX.md и реестры {docs_dir}/registry/<docs.registries>.md
  docs find [--type T] [--status S] [--module M] [--long] [текст]   строка на документ: путь — summary
  docs show <путь>                    frontmatter + оглавление (без тела)
  docs section <путь> [раздел]        нумерованное оглавление или текст раздела (номер или начало заголовка)
  docs findings [текст] [--module M]  выдержки из {docs_dir}/registry/findings.md
  docs init [--dry]                   дописать frontmatter файлам без него (эвристики по пути и тексту)

Схема frontmatter (YAML, значения — JSON-строки/списки):
  type: guide|plan|contract|research|reference|journal|registry   (ключ конфига docs.types)
  status: active|idea|postponed|closed|superseded                 (docs.statuses)
  module, area (подпроект из ключа areas; обязателен у plan/contract/journal модуля, если areas задан),
  updated (ГГГГ-ММ-ДД), summary (вывод/назначение, 1 строка ≤ docs.summary_max), related: []
  research: conclusion, data, applied_in;  contract: contracts: [{id, version}]
  generated: true — файл собирается командой (проверка размера пропускается, руками не править)
  archive — у journal из deliver: тег/ссылка git с полным журналом модуля
Размер: > docs.max_kb — ошибка (docs.max_kb_mode: warn — предупреждение); архив и generated не проверяются.
Область проверки: {docs_dir}/**/*.md + docs.extra (globs от корня), минус docs.exclude (по умолчанию {docs_dir}/archive/**)
и каталоги модулей dpcli в plan_dir (с module.json).
"""
import datetime
import fnmatch
import json
import re
import subprocess
from pathlib import Path

from .. import config, yamlmini
from ..mdsec import headings, match_sections, section_body, toc
from ..util import CLI, DpError, short

DEFAULT_TYPES = ["guide", "plan", "contract", "research", "reference", "journal", "registry"]
DEFAULT_STATUSES = ["active", "idea", "postponed", "closed", "superseded"]
DEFAULT_MAX_KB = 40
DEFAULT_SUMMARY_MAX = 140
DEFAULT_REGISTRIES = ["research", "contracts"]
KNOWN_REGISTRIES = ["research", "contracts", "decisions"]
SUMMARY_TODO = "TODO"


# ---------- конфиг и корень ----------
def _cfg():
    """Настройки docs в виде словаря с умолчаниями; корень проекта — toplevel git (или cwd)."""
    c = {}
    if config is not None:
        try:
            c = config.load() or {}
        except DpError:
            raise
        except Exception:
            c = {}
    d = c.get("docs") if isinstance(c.get("docs"), dict) else {}

    def lst(v, default):
        if v is None:
            return list(default)
        return [v] if isinstance(v, str) else list(v)

    docs_dir = str(c.get("docs_dir") or "docs").strip("/")
    return {
        "docs_dir": docs_dir,
        "plan_dir": str(c.get("plan_dir") or f"{docs_dir}/plan").strip("/"),
        "contracts_dir": str(c.get("contracts_dir") or f"{docs_dir}/contracts").strip("/"),
        "extra": lst(d.get("extra"), []),
        "exclude": lst(d.get("exclude"), [f"{docs_dir}/archive/**"]),
        "types": lst(d.get("types"), DEFAULT_TYPES),
        "statuses": lst(d.get("statuses"), DEFAULT_STATUSES),
        "max_kb": float(d.get("max_kb") or DEFAULT_MAX_KB),
        "max_kb_mode": str(d.get("max_kb_mode") or "error").strip().lower(),
        "summary_max": int(d.get("summary_max") or DEFAULT_SUMMARY_MAX),
        "registries": lst(d.get("registries"), DEFAULT_REGISTRIES),
        "areas": lst(c.get("areas"), []),
    }


def _root():
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip() else Path.cwd()


class Ctx:
    def __init__(self, root=None):
        self.c = _cfg()
        self.root = Path(root) if root else _root()
        self.docs = self.root / self.c["docs_dir"]
        if self.c["max_kb_mode"] not in ("error", "warn"):
            raise DpError(f"docs.max_kb_mode: '{self.c['max_kb_mode']}' — нужно error или warn")

    @property
    def index_path(self):
        return f"{self.c['docs_dir']}/INDEX.md"

    @property
    def reg(self):
        return f"{self.c['docs_dir']}/registry"

    @property
    def archive(self):
        return f"{self.c['docs_dir']}/archive"

    def need_docs(self):
        if not self.docs.is_dir():
            raise DpError(f"нет каталога документов {self.c['docs_dir']}/ (ключ docs_dir) в {self.root}")


# ---------- frontmatter ----------
def split_fm(text):
    """-> (dict|None, тело). YAML через yamlmini (списки блоком и inline); не разобрался — плоский разбор «key: JSON|строка»."""
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---", 4)
    if end < 0:
        return None, text
    fm = _yaml_fm(text[4:end])
    if fm is None:
        fm = _flat_fm(text[4:end])
    rest = text[end + 4:]
    return fm, rest[1:] if rest.startswith("\n") else rest


def _yaml_fm(block):
    try:
        fm = yamlmini.loads(block, use_pyyaml=False)  # без PyYAML: даты остаются строками
    except (yamlmini.YamlError, ValueError):
        return None
    return fm if isinstance(fm, dict) else None


def _flat_fm(block):
    fm = {}
    for line in block.split("\n"):
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if not m:
            continue
        v = m.group(2).strip()
        try:
            fm[m.group(1)] = json.loads(v) if v else ""
        except ValueError:
            fm[m.group(1)] = v.strip("'\"")
    return fm


ORDER = ["type", "status", "module", "area", "updated", "summary", "related", "conclusion", "data", "applied_in", "contracts", "archive", "generated"]


def dump_fm(fm):
    keys = [k for k in ORDER if k in fm] + [k for k in fm if k not in ORDER]
    return "---\n" + "".join(f"{k}: {json.dumps(fm[k], ensure_ascii=False)}\n" for k in keys) + "---\n"


def read(p):
    return Path(p).read_text(encoding="utf-8")


# ---------- область ----------
def scope(x, archive=False):
    """Файлы под проверкой; archive=True — плюс {docs_dir}/archive/** (даже если исключён)."""
    seen, out = set(), []
    cands = sorted(x.docs.rglob("*.md"))
    for g in x.c["extra"]:
        cands += sorted(x.root.glob(g))
    plan = x.c["plan_dir"]
    for p in cands:
        if not p.is_file():
            continue
        try:
            r = p.relative_to(x.root).as_posix()
        except ValueError:
            continue
        if r in seen or not r.endswith(".md"):
            continue
        seen.add(r)
        if any(fnmatch.fnmatch(r, g) for g in x.c["exclude"]) and not (archive and _under(r, x.archive)):
            continue
        parts = r.split("/")
        pp = plan.split("/")
        if r.startswith(plan + "/") and len(parts) > len(pp) + 1 and (x.root / plan / parts[len(pp)] / "module.json").exists():
            continue  # каталог данных модуля dpcli
        out.append(r)
    return out


def docs_all(x, archive=False):
    return [(r, *split_fm(read(x.root / r))) for r in scope(x, archive)]


# ---------- check ----------
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE = re.compile(r"```.*?```", re.S)


def check_links(x, r, body):
    bad = []
    body = FENCE.sub("", body)
    body = re.sub(r"`[^`\n]*`", "", body)
    for t in LINK.findall(body):
        if re.match(r"^[a-z][a-z0-9+.-]*:|^#", t):
            continue
        p = t.split("#")[0].split("?")[0]
        if not p:
            continue
        tgt = x.root / p[1:] if p.startswith("/") else (x.root / r).parent / p
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


SUMMARY_HINT = "заполнить summary: вывод/назначение в одну строку"


def explicit_paths(x, args, in_scope):
    """Пути из командной строки (от текущего каталога или от корня) → пути от корня: файл как есть, каталог — файлы области под ним."""
    out = []
    for arg in args:
        p = Path(arg)
        cands = [p.resolve()] if p.is_absolute() else [(Path.cwd() / p).resolve(), (x.root / p).resolve()]
        found = next((c for c in cands if c.exists()), None)
        if found is None:
            raise DpError(f"docs check: нет такого пути {arg}")
        try:
            r = found.relative_to(x.root.resolve()).as_posix()
        except ValueError:
            raise DpError(f"docs check: {arg} вне репозитория")
        got = [r] if found.is_file() else [f for f in in_scope if f.startswith(r.rstrip("/") + "/")] if r != "." else list(in_scope)
        if found.is_file() and not r.endswith(".md"):
            raise DpError(f"docs check: {arg} — не .md")
        out += [g for g in got if g not in out]
    return out


def cmd_check(x, a):
    x.need_docs()
    types, statuses, max_kb = x.c["types"], x.c["statuses"], x.c["max_kb"]
    err, warn = [], []
    items = docs_all(x)
    only = getattr(a, "paths", None)
    if only:
        items = [(r, *split_fm(read(x.root / r))) for r in explicit_paths(x, only, [i[0] for i in items])]
    for r, fm, body in items:
        if fm is None:
            err.append(f"{r}: нет frontmatter")
            continue
        t, s = fm.get("type"), fm.get("status")
        if t is None:
            err.append(f"{r}: нет type (одно из {sorted(types)})")
        elif t not in types:
            err.append(f"{r}: type '{t}' не из {sorted(types)}")
        if s is None:
            err.append(f"{r}: нет status (одно из {sorted(statuses)})")
        elif s not in statuses:
            err.append(f"{r}: status '{s}' не из {sorted(statuses)}")
        summ = str(fm.get("summary", "")).strip()
        if not summ:
            err.append(f"{r}: нет summary — {SUMMARY_HINT}")
        elif summ.upper() == SUMMARY_TODO:
            err.append(f"{r}: summary TODO — {SUMMARY_HINT}")
        elif "\n" in summ:
            err.append(f"{r}: summary в несколько строк — {SUMMARY_HINT}")
        elif len(summ) > x.c["summary_max"]:
            err.append(f"{r}: summary {len(summ)} симв. > {x.c['summary_max']} — сократить до вывода/назначения в одну строку")
        if not fm.get("updated"):
            warn.append(f"{r}: нет updated")
        areas, area = x.c["areas"], fm.get("area")
        if areas and area and area not in areas:
            err.append(f"{r}: area '{area}' не из {areas}")
        elif areas and not area and fm.get("module") and t in ("plan", "contract", "journal"):
            err.append(f"{r}: нет area у документа модуля (одно из {areas})")
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
                live = {y["id"]: y["version"] for y in contract_ids(body)}
                have = {y.get("id"): y.get("version") for y in c if isinstance(y, dict)}
                if live and live != have:
                    warn.append(f"{r}: contracts во frontmatter ≠ заголовкам (docs init --refresh-contracts)")
        for rel in fm.get("related", []) if isinstance(fm.get("related"), list) else []:
            if not (x.root / rel).exists():
                err.append(f"{r}: related → нет файла {rel}")
        for t_ in check_links(x, r, body):
            err.append(f"{r}: битая ссылка {t_}")
        kb = (x.root / r).stat().st_size / 1024
        if kb > max_kb and not fm.get("generated") and not _under(r, x.archive):
            (warn if x.c["max_kb_mode"] == "warn" else err).append(
                f"{r}: {kb:.0f} КБ > {max_kb:g} КБ — разбить на разделы-файлы или вынести данные")
    for e in err:
        print("ОШИБКА  " + e)
    for w in warn:
        print("предупр. " + w)
    print(f"docs check: файлов {len(items)}, ошибок {len(err)}, предупреждений {len(warn)}")
    return 1 if err else 0


# ---------- init (эвристики) ----------
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


def git_date(x, r):
    try:
        return subprocess.run(["git", "log", "-1", "--format=%cs", "--", r], cwd=x.root, capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def _under(r, d):
    return r.startswith(d.rstrip("/") + "/")


def default_fm(x, r, body):
    dd, c = x.c["docs_dir"], x.c
    name = Path(r).name
    if _under(r, c["contracts_dir"]):
        t = "contract"
    elif _under(r, f"{dd}/guide"):
        t = "guide"
    elif _under(r, f"{dd}/research") or "research" in Path(r).parts[:-1]:
        t = "research"
    elif _under(r, c["plan_dir"]):
        t = "journal" if name.endswith("_progress.md") else "plan"
    elif _under(r, f"{dd}/registry") or r == f"{dd}/INDEX.md":
        t = "registry"
    else:
        t = "guide"
    t = t if t in c["types"] else (c["types"][0] if c["types"] else t)
    st = "active" if t in ("guide", "contract", "reference", "registry") else "closed"
    st = st if st in c["statuses"] else (c["statuses"][0] if c["statuses"] else st)
    fm = {"type": t, "status": st}
    mod = ""
    if _under(r, c["contracts_dir"]):
        mod = Path(r).stem
    elif _under(r, c["plan_dir"]):
        sub = r[len(c["plan_dir"]) + 1:].split("/")
        mod = sub[0] if len(sub) > 1 else ""
    fm["module"] = mod
    fm["updated"] = git_date(x, r) or datetime.date.today().isoformat()
    fm["summary"] = SUMMARY_TODO  # не выдумывать из текста: заполняет автор (docs check ругается на TODO)
    fm["related"] = []
    if t == "research":
        fm["conclusion"] = conclusion_of(body)
        fm["data"] = ""
        fm["applied_in"] = ""
    if t == "contract":
        fm["contracts"] = contract_ids(body)
    if r == x.index_path or _under(r, x.reg):
        fm["generated"] = r != f"{x.reg}/findings.md"
        if not fm["generated"]:
            del fm["generated"]
    return fm


def cmd_init(x, a):
    x.need_docs()
    n = 0
    for r in scope(x):
        p = x.root / r
        fm, body = split_fm(read(p))
        if fm is not None:
            if a.refresh_contracts and fm.get("type") == "contract":
                fm["contracts"] = contract_ids(body)
                p.write_text(dump_fm(fm) + body, encoding="utf-8")
            continue
        fm = default_fm(x, r, body)
        n += 1
        if a.dry:
            print(r, fm["type"], fm["status"], fm["module"] or "-")
        else:
            p.write_text(dump_fm(fm) + body, encoding="utf-8")
    print(f"frontmatter добавлен: {n}" + (f"; заполнить summary (сейчас TODO) — список: {CLI} docs check" if n and not a.dry else ""))
    return 0


# ---------- find / show / section / findings ----------
FIND_WIDTH = 160


def cmd_find(x, a):
    x.need_docs()
    q = (a.text or "").lower()
    n = 0
    arch = a.archive or a.status in ("closed", "superseded")  # закрытое ищется и в архиве
    for r, fm, body in docs_all(x, arch):
        if fm is None:
            continue
        if a.type and fm.get("type") != a.type or a.status and fm.get("status") != a.status or a.module and fm.get("module") != a.module:
            continue
        if a.area and fm.get("area") != a.area:
            continue
        hay = " ".join([r, str(fm.get("summary", "")), str(fm.get("conclusion", "")), str(fm.get("module", ""))]).lower()
        if q and not all(w in hay for w in q.split()):
            continue
        summ = str(fm.get("summary", ""))
        if a.long:
            print(f"{r} — {fm.get('type')} — {fm.get('status')} — {summ[:160]}")
        else:
            print(short(f"{r} — {summ}", FIND_WIDTH))
        n += 1
    if not n:
        print("ничего не найдено")
    return 0


def _doc_path(x, path):
    p = Path(path)
    if not p.is_absolute() and not p.exists():
        p = x.root / path
    if not p.is_file():
        raise DpError("нет файла: " + path)
    return p


def cmd_show(x, a):
    p = _doc_path(x, a.path)
    fm, body = split_fm(read(p))
    print(dump_fm(fm).rstrip() if fm else "(нет frontmatter)")
    print()
    for i, l in enumerate(body.split("\n"), 1):
        if re.match(r"^#{1,4}\s", l):
            print(f"{l}   (строка {i})")
    return 0


def cmd_section(x, a):
    path, sec = a.path, a.section
    if sec is None and "#" in path and not Path(path).exists():
        path, sec = path.split("#", 1)  # ссылка вида путь#раздел
    p = _doc_path(x, path)
    _, body = split_fm(read(p))
    lines, heads = headings(body)
    if not sec:
        print(f"{path} — {len(lines)} строк; {CLI} docs section {path} <номер|начало заголовка>")
        for t in toc(lines, heads, a.depth):
            print(t)
        if not heads:
            print("(заголовков нет)")
        return 0
    cands = match_sections(heads, sec)
    if not cands:
        raise DpError(f"раздел «{sec.strip()}» не найден; оглавление — {CLI} docs section {path}")
    if len(cands) > 1:
        print(f"раздел «{sec.strip()}» неоднозначен — указать номер:")
        for n in cands:
            _, lvl, t = heads[n]
            print(f"{n + 1:>3} {'  ' * (lvl - 1)}{short(t, 90)}")
        return 1
    print("\n".join(section_body(lines, heads, cands[0], a.max)))
    return 0


def cmd_findings(x, a):
    rel = f"{x.reg}/findings.md"
    p = x.root / rel
    if not p.exists():
        raise DpError(f"нет {rel} (реестр выводов пишется вручную)")
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
GEN_HEAD = "Файл собран `docs index` — руками не править.\n\n"
TYPE_TITLES = {"guide": "Описания систем", "plan": "Планы", "contract": "Контракты стыков", "research": "Исследования",
               "reference": "Справка", "journal": "Журналы", "registry": "Реестры"}


def write_gen(x, path, title, summary, body, head=GEN_HEAD, updated=None):
    """updated — самая поздняя дата исходных документов, не «сегодня»: две ветки с одинаковыми документами
    собирают один и тот же файл, и слияние не конфликтует на пустом месте."""
    fm = {"type": "registry", "status": "active", "module": "", "updated": updated or datetime.date.today().isoformat(),
          "summary": summary, "related": [], "generated": True}
    (x.root / path).parent.mkdir(parents=True, exist_ok=True)
    (x.root / path).write_text(dump_fm(fm) + f"\n# {title}\n\n" + head + body, encoding="utf-8")


def _link(frm, r):
    """Относительная ссылка из файла frm (от корня) на r (от корня)."""
    import os.path
    return os.path.relpath(r, os.path.dirname(frm) or ".")


def index_line(x, r, fm):
    st = fm.get("status")
    mark = f" [{st}]" if st and st != "active" else ""
    summ = " ".join(str(fm.get("summary", "")).split())
    return f"- [{r}]({_link(x.index_path, r)}) — {summ}{mark}"


def module_groups(x, items):
    """Модули по планам {plan_dir}/<м>.md: {модуль: {plan, docs: [(r, fm)], area}}; документ модуля — module во frontmatter
    или путь {plan_dir}/<м>/…; area — из плана, иначе из любого документа модуля."""
    plan = x.c["plan_dir"]
    mods = {}
    for r, fm, _ in items:
        if r.startswith(plan + "/") and r.count("/") == plan.count("/") + 1 and fm.get("type") == "plan":
            mods[Path(r).stem] = {"plan": (r, fm), "docs": []}
    for r, fm, _ in items:
        m = fm.get("module")
        if m not in mods and r.startswith(plan + "/"):
            m = r[len(plan) + 1:].split("/")[0]
        if m in mods and r != mods[m]["plan"][0]:
            mods[m]["docs"].append((r, fm))
    for m, g in mods.items():
        g["area"] = g["plan"][1].get("area") or next((fm.get("area") for _, fm in g["docs"] if fm.get("area")), None)
    return mods


def module_line(x, mod, g):
    """Строка модуля: summary плана, статус и дата; ссылки на план, контракты, решения, сводку; тег архива журнала."""
    r, fm = g["plan"]
    plan, contracts = x.c["plan_dir"], x.c["contracts_dir"]
    named = {f"{plan}/{mod}/decisions.md": "решения", f"{plan}/{mod}/summary.md": "сводка", f"{contracts}/{mod}.md": "контракты"}
    links = [f"[план]({_link(x.index_path, r)})"]
    rest, archive = [], None
    for k in ("контракты", "решения", "сводка"):
        links += [f"[{k}]({_link(x.index_path, d)})" for d, _ in g["docs"] if named.get(d) == k]
    for d, dfm in g["docs"]:
        archive = archive or dfm.get("archive")
        if d not in named:
            rest.append(index_line(x, d, dfm))
    st = " ".join(x_ for x_ in (fm.get("status") or "", str(fm.get("updated") or "")) if x_)
    summ = " ".join(str(fm.get("summary", "")).split())
    line = f"- **{mod}** — {summ} [{st}] — " + " · ".join(links) + (f" · полный журнал: `{archive}`" if archive else "")
    return [line] + [f"  {l}" for l in rest]


def cmd_index(x, a):
    x.need_docs()
    dd = x.c["docs_dir"]
    fp = x.root / x.reg / "findings.md"
    if not fp.exists():  # INDEX.md ссылается на реестр выводов — заготовка (дальше пишется вручную)
        fm = {"type": "registry", "status": "active", "module": "", "updated": datetime.date.today().isoformat(),
              "summary": "Реестр выводов: что мы знаем, по модулям (пишется вручную).", "related": []}
        fp.parent.mkdir(parents=True, exist_ok=True)
        fp.write_text(dump_fm(fm) + "\n# Реестр выводов\n\nПо модулю — раздел `## <модуль>`, вывод — пункт `- …` "
                      "(одна строка: вывод с числами и ссылка `путь#раздел`). Поиск — `docs findings`.\n", encoding="utf-8")
    regs = [k for k in x.c["registries"] if k in KNOWN_REGISTRIES]
    items = [(r, fm, body) for r, fm, body in docs_all(x) if fm is not None and r not in generated_paths(x)]
    upd = max((str(fm.get("updated") or "") for _, fm, _ in items), default="") or None

    out = []
    mods = module_groups(x, items)
    in_mod = {r for g in mods.values() for r in [g["plan"][0]] + [d for d, _ in g["docs"]]}
    found = {g["area"] for g in mods.values()}
    order = [ar for ar in x.c["areas"] if ar in found] + sorted(ar for ar in found if ar and ar not in x.c["areas"])
    order += [None] if None in found else []
    if mods:
        out.append("Модули — по подпроектам (area), внутри — по дате плана: строка на модуль, под ней — его прочие документы.\n")
    for ar in order:
        rows = sorted(((m, g) for m, g in mods.items() if g["area"] == ar), key=lambda mg: (str(mg[1]["plan"][1].get("updated") or ""), mg[0]))
        out.append(f"## {ar or 'Модули без area'}\n")
        for m, g in rows:
            out += module_line(x, m, g)
        out.append("")

    types = list(x.c["types"])
    groups = {}
    for r, fm, _ in items:
        if r in in_mod:
            continue
        t = fm.get("type")
        groups.setdefault(t if t in types else None, []).append((r, fm))
    if groups and mods:
        out.append("## Прочие документы\n")
    lvl = "###" if mods else "##"
    for t in types + [None]:
        rows = groups.get(t)
        if not rows:
            continue
        out.append(f"{lvl} {TYPE_TITLES.get(t, t) + f' ({t})' if t in TYPE_TITLES else (t or 'Прочее')}\n")
        out += [index_line(x, r, fm) for r, fm in rows]
        out.append("")
    arch = x.root / x.archive
    if arch.is_dir():
        n = len(list(arch.rglob("*.md")))
        out.append(f"архив: {n} документов — `{CLI} docs find --status closed`\n")
    findings = _link(x.index_path, f"{x.reg}/findings.md")
    head = (f"Точка входа; руками не править (`{CLI} docs index`). Читать по кусочку, не целиком:\n"
            f"- найти — `{CLI} docs find <слова>` (путь — summary), выводы — `{CLI} docs findings <слова>` "
            f"([реестр выводов]({findings})), журналы модулей — `{CLI} search`;\n"
            f"- читать — `{CLI} docs section <путь>` (оглавление), затем `{CLI} docs section <путь> <номер|заголовок>`.\n\n")
    write_gen(x, x.index_path, "Индекс документации", f"Точка входа: модули {dd}/ по подпроектам, прочие документы по типам.",
              "\n".join(out), head, upd)
    made = ["INDEX.md"]

    if "research" in regs:
        rows = []
        for r, fm, body in items:
            if fm.get("type") != "research":
                continue
            concl = " ".join(str(fm.get("conclusion") or fm.get("summary", "")).split())
            extra = "; ".join(f"{k}: {short(fm[k], 80)}" for k in ("data", "applied_in") if str(fm.get(k, "")).strip())
            rows.append(f"- [{r}]({_link(x.reg + '/research.md', r)}) — {short(concl, 200)}" + (f" ({extra})" if extra else ""))
        write_gen(x, f"{x.reg}/research.md", "Реестр исследований", "Исследования: вывод, данные, где применено.",
                  "\n".join(rows) + "\n", updated=upd)
        made.append("research")

    if "contracts" in regs:
        rows = []
        for r, fm, body in items:
            if fm.get("type") == "contract":
                cs = ", ".join(f"{k['id']} v{k['version']}" for k in fm.get("contracts", []) if isinstance(k, dict))
                rows.append(f"- {fm.get('module') or '-'}: {cs or '—'} — [{r}]({_link(x.reg + '/contracts.md', r)})")
        write_gen(x, f"{x.reg}/contracts.md", "Реестр контрактов", "Контракты стыков по модулям: id и версии из заголовков.",
                  "\n".join(rows) + "\n", updated=upd)
        made.append("contracts")

    total = 0
    if "decisions" in regs:  # дублирует журналы модулей; по умолчанию выключен (решения ищутся `search`)
        drows = []
        for d in sorted((x.root / x.c["plan_dir"]).glob("*/decisions.jsonl")):
            recs = []
            for l in d.read_text(encoding="utf-8").splitlines():
                try:
                    recs.append(json.loads(l))
                except ValueError:
                    pass
            recs = [k for k in recs if isinstance(k, dict)]
            if not recs:
                continue
            drows.append(f"## {d.parent.name}\n")
            for k in sorted(recs, key=lambda k: str(k.get("t", ""))):
                txt = " ".join(str(k.get("text", "")).split())
                why = " ".join(str(k.get("why", "")).split())
                drows.append(f"- {str(k.get('t', ''))[:10]} {k.get('kind', 'decision')}: {txt[:400]}" + (f" — почему: {why[:240]}" if why else ""))
                total += 1
            drows.append("")
        write_gen(x, f"{x.reg}/decisions.md", "Реестр решений", f"Решения модулей из decisions.jsonl ({total} записей).", "\n".join(drows),
                  updated=upd)
        made.append(f"decisions ({total})")
    print(f"docs index: {', '.join(made)}")
    return 0


def generated_paths(x):
    """Файлы, которые собирает docs index (от корня)."""
    return {x.index_path} | {f"{x.reg}/{k}.md" for k in KNOWN_REGISTRIES}


def resolve_generated(root, files):
    """Конфликт слияния только в файлах docs index → пересобрать их, git add; → True. Иначе ничего не трогать → False.
    Индекс — функция документов: при параллельных ветках (координаторы в одной фичеветке, фичеветки в main)
    он конфликтует всегда, а правильное разрешение одно — собрать заново из слитых документов."""
    files = [f for f in files if f]
    x = Ctx(root)
    if not files or not set(files) <= generated_paths(x) or not x.docs.is_dir():
        return False
    import contextlib
    import io
    with contextlib.redirect_stdout(io.StringIO()):
        cmd_index(x, None)
    gen = sorted(set(files) | {g for g in generated_paths(x) if (x.root / g).exists()})
    r = subprocess.run(["git", "add", "--", *gen], cwd=root, capture_output=True, text=True)
    return r.returncode == 0


# ---------- регистрация ----------
def _run(fn):
    def run(a):
        return fn(Ctx(), a) or 0
    return run


def register(sp):
    p = sp.add_parser("docs", help="реестр и проверка документации: check|index|find|show|section|findings|init")
    ds = p.add_subparsers(dest="docs_cmd", required=True)
    q = ds.add_parser("check", help="frontmatter, summary, ссылки, размер (можно только указанные файлы/каталоги)")
    q.add_argument("paths", nargs="*", metavar="путь", help="проверить только эти файлы (каталог — все документы под ним)")
    q.set_defaults(func=_run(cmd_check))
    ds.add_parser("index", help="собрать INDEX.md и реестры (docs.registries)").set_defaults(func=_run(cmd_index))
    q = ds.add_parser("find", help="найти документы: строка «путь — summary»")
    q.add_argument("text", nargs="?")
    q.add_argument("--type")
    q.add_argument("--status", help="closed/superseded ищутся и в архиве")
    q.add_argument("--module")
    q.add_argument("--area")
    q.add_argument("--archive", action="store_true", help="искать и в архиве")
    q.add_argument("--long", action="store_true", help="путь — type — status — summary")
    q.set_defaults(func=_run(cmd_find))
    q = ds.add_parser("show", help="frontmatter и оглавление")
    q.add_argument("path")
    q.set_defaults(func=_run(cmd_show))
    q = ds.add_parser("section", help="оглавление документа или раздел (номер или начало заголовка)")
    q.add_argument("path", metavar="путь[#раздел]")
    q.add_argument("section", nargs="?")
    q.add_argument("--depth", type=int, default=3, help="уровни заголовков в оглавлении (3)")
    q.add_argument("--max", type=int, default=0, help="строк раздела (0 — всё)")
    q.set_defaults(func=_run(cmd_section))
    q = ds.add_parser("findings", help="выводы из registry/findings.md")
    q.add_argument("text", nargs="?")
    q.add_argument("--module")
    q.set_defaults(func=_run(cmd_findings))
    q = ds.add_parser("init", help="дописать frontmatter файлам без него (summary: TODO)")
    q.add_argument("--dry", action="store_true")
    q.add_argument("--refresh-contracts", action="store_true")
    q.set_defaults(func=_run(cmd_init))
    return p
