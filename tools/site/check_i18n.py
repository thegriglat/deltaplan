"""Контрактный тест многоязычного сайта (docs/contracts/site-i18n.md, SI-К1…SI-К5).

    python3 tools/site/check_i18n.py [--only=K1,K2,K3,K4,K5] [--allow-missing] [--keep DIR]

K1 — конфигурация языков и URL-схема (site/hugo.toml);
K2 — содержимое по языкам: файлы site/content/**.{en,ru}.md, пары переводов, общие ключи frontmatter;
K3 — строки интерфейса: site/i18n/{en,ru}.yaml с одинаковыми id, без кириллицы в site/layouts;
K4 — сборка: hugo без WARN/ERROR, корни / (en) и /ru/ (ru), внутренние ссылки и картинки живые;
K5 — английский текст: в en-страницах из site/content почти нет кириллицы, правила публичных текстов.
--pages=a,b — K2 и K5 только для страниц, чья база (путь в site/content без .en.md/.ru.md) начинается с a или b
  (напр. --pages=mechanics/flight,releases/); задача перевода проверяет свои страницы.
--k5-skip=a,b — K5 не проверять у страниц с этими префиксами базы (ручной текст ещё не переведён другой задачей).
--allow-missing — не считать ошибкой ru-страницы без en-перевода (промежуточные этапы), только печатать число.
Код выхода 0 — всё по контракту, 1 — нарушения (список в выводе).
"""
import html.parser
import os
import re
import subprocess
import sys
import tempfile
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SITE = os.path.join(ROOT, "site")
CONTENT = os.path.join(SITE, "content")
CYR = re.compile(r"[А-Яа-яЁё]")
LAT = re.compile(r"[A-Za-z]")
# Ресурсы бандлов, а не страницы: текст девлога старых версий
RESOURCE_MD = re.compile(r"releases/[^/]+/devlog\.md$")
SHARED_FM = ("weight", "date", "cover", "type", "bookHidden", "bookCollapseSection", "bookFlatSection", "layout")
EN_CYR_MAX = 0.03  # доля кириллицы среди букв en-страницы
FORBIDDEN_EN = re.compile(r"\b(mom|mum|mother|dad|father|easter[- ]eggs?)\b", re.I)

errors: list[str] = []
allow_missing = False
pages: list[str] = []
k5_skip: list[str] = []


def err(k: str, msg: str) -> None:
    errors.append(f"{k}: {msg}")


def k1() -> None:
    with open(os.path.join(SITE, "hugo.toml"), "rb") as f:
        cfg = tomllib.load(f)
    if cfg.get("defaultContentLanguage") != "en":
        err("K1", f"defaultContentLanguage = {cfg.get('defaultContentLanguage')!r}, нужно 'en'")
    if cfg.get("defaultContentLanguageInSubdir", False):
        err("K1", "defaultContentLanguageInSubdir должен быть false (en — в корне)")
    langs = cfg.get("languages", {})
    if set(langs) != {"en", "ru"}:
        err("K1", f"languages = {sorted(langs)}, нужно ровно en и ru")
    elif not langs["en"].get("weight", 0) < langs["ru"].get("weight", 0):
        err("K1", "weight en должен быть меньше weight ru (en — первый)")
    for lang in ("en", "ru"):
        if lang in langs and langs[lang].get("contentDir"):
            err("K1", f"languages.{lang}.contentDir задан — перевод только по имени файла (SI-К2)")
    for m in cfg.get("module", {}).get("mounts", []):
        src, tgt = m.get("source", ""), m.get("target", "")
        if tgt.startswith("content") and src.startswith(".."):
            langs_m = (m.get("sites") or {}).get("matrix", {}).get("languages")
            if langs_m != ["ru"]:
                err("K1", f"монтирование {src} → {tgt} без sites.matrix.languages = ['ru'] (документы репозитория — только ru)")


def page_files() -> list[str]:
    out = []
    for d, _, fs in os.walk(CONTENT):
        for f in fs:
            if f.endswith(".md"):
                rel = os.path.relpath(os.path.join(d, f), CONTENT).replace(os.sep, "/")
                if RESOURCE_MD.search(rel):
                    continue
                base = re.sub(r"(\.(en|ru))?\.md$", "", rel)
                if pages and not any(base.startswith(x) for x in pages):
                    continue
                out.append(rel)
    return sorted(out)


def frontmatter(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}
    fm = {}
    for line in m.group(1).splitlines():
        mm = re.match(r"^([A-Za-z_]+):\s*(.*)$", line)
        if mm:
            fm[mm.group(1)] = mm.group(2).strip().strip("'\"")
    return fm


def k2() -> None:
    files = page_files()
    bad = [f for f in files if not re.search(r"\.(en|ru)\.md$", f)]
    for f in bad:
        err("K2", f"site/content/{f}: нет суффикса языка (.en.md / .ru.md)")
    ru = {f[: -len(".ru.md")] for f in files if f.endswith(".ru.md")}
    en = {f[: -len(".en.md")] for f in files if f.endswith(".en.md")}
    for b in sorted(en - ru):
        err("K2", f"site/content/{b}.en.md без русского оригинала {b}.ru.md")
    missing = sorted(ru - en)
    if missing:
        if allow_missing:
            print(f"K2: без en-перевода {len(missing)} из {len(ru)} (--allow-missing)")
        else:
            for b in missing:
                err("K2", f"site/content/{b}.ru.md без перевода {b}.en.md")
    for b in sorted(ru & en):
        fr = frontmatter(os.path.join(CONTENT, b + ".ru.md"))
        fe = frontmatter(os.path.join(CONTENT, b + ".en.md"))
        if not fe.get("title") and fr.get("title"):
            err("K2", f"{b}.en.md: нет title")
        for k in SHARED_FM:
            if fr.get(k) != fe.get(k):
                err("K2", f"{b}.en.md: {k} = {fe.get(k)!r}, в ru {fr.get(k)!r} (должны совпадать)")


def yaml_ids(path: str) -> set[str]:
    with open(path, encoding="utf-8") as f:
        return set(re.findall(r"^-\s*id:\s*['\"]?([^'\"\n]+?)['\"]?\s*$", f.read(), re.M))


def k3() -> None:
    pe, pr = os.path.join(SITE, "i18n", "en.yaml"), os.path.join(SITE, "i18n", "ru.yaml")
    if not os.path.exists(pe):
        err("K3", "нет site/i18n/en.yaml")
        return
    ie, ir = yaml_ids(pe), yaml_ids(pr)
    for i in sorted(ie - ir):
        err("K3", f"ключ {i!r} есть в en.yaml, нет в ru.yaml")
    for i in sorted(ir - ie):
        err("K3", f"ключ {i!r} есть в ru.yaml, нет в en.yaml")
    for d, _, fs in os.walk(os.path.join(SITE, "layouts")):
        for f in fs:
            p = os.path.join(d, f)
            with open(p, encoding="utf-8") as fh:
                t = fh.read()
            t = re.sub(r"\{\{-?\s*/\*.*?\*/\s*-?\}\}", "", t, flags=re.S)
            t = re.sub(r"<!--.*?-->", "", t, flags=re.S)
            for n, line in enumerate(t.splitlines(), 1):
                if CYR.search(line):
                    err("K3", f"{os.path.relpath(p, ROOT)}: кириллица вне комментария (строки интерфейса — через i18n): {line.strip()[:80]}")
                    break


class Links(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.urls: list[str] = []
        self.lang = None
        self.text: list[str] = []
        self._art = 0
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "html":
            self.lang = a.get("lang")
        for k in ("href", "src"):
            if a.get(k) and tag in ("a", "img", "link", "script", "source", "iframe"):
                if not (tag == "link" and a.get("rel") in ("alternate", "canonical")):
                    self.urls.append(a[k])
        if tag == "article":
            self._art += 1
        if tag in ("script", "style", "code", "pre"):
            self._skip += 1

    def handle_endtag(self, tag):
        if tag == "article":
            self._art -= 1
        if tag in ("script", "style", "code", "pre"):
            self._skip -= 1

    def handle_data(self, data):
        if self._art > 0 and self._skip == 0:
            self.text.append(data)


def parse(path: str) -> Links:
    p = Links()
    with open(path, encoding="utf-8", errors="replace") as f:
        p.feed(f.read())
    return p


def build(out: str) -> bool:
    r = subprocess.run(["hugo", "--logLevel", "warn", "-d", out, "--cleanDestinationDir"],
                       cwd=SITE, capture_output=True, text=True)
    log = (r.stdout + r.stderr).strip()
    bad = [l for l in log.splitlines() if re.search(r"\b(WARN|ERROR)\b", l)]
    for l in bad[:20]:
        err("K4", f"hugo: {l[:200]}")
    if r.returncode != 0:
        err("K4", f"hugo завершился с кодом {r.returncode}")
        return False
    return True


def k4(out: str, base_path: str) -> None:
    for rel, lang in (("index.html", "en"), ("ru/index.html", "ru")):
        p = os.path.join(out, rel)
        if not os.path.exists(p):
            err("K4", f"нет {rel}")
        elif parse(p).lang not in (lang, lang + "-RU", lang + "-US", lang + "-GB"):
            err("K4", f"{rel}: <html lang> = {parse(p).lang!r}, ждали {lang}")
    en_dir = os.path.join(out, "en")
    if os.path.isdir(en_dir):
        # Hugo всегда пишет /en/index.html (редирект на корень) и /en/sitemap.xml — это допустимо
        extra = sorted(set(os.listdir(en_dir)) - {"index.html", "sitemap.xml"})
        if extra:
            err("K4", f"в /en/ лишнее {extra[:5]} — en должен быть в корне (допустим только редирект Hugo)")
        else:
            with open(os.path.join(en_dir, "index.html"), encoding="utf-8", errors="replace") as fh:
                if "http-equiv=\"refresh\"" not in fh.read().replace("http-equiv=refresh", "http-equiv=\"refresh\""):
                    err("K4", "/en/index.html — не редирект")
    broken: dict[str, set[str]] = {}
    checked = 0
    for d, _, fs in os.walk(out):
        for f in fs:
            if not f.endswith(".html"):
                continue
            p = os.path.join(d, f)
            for u in parse(p).urls:
                u = u.split("#")[0].split("?")[0]
                if not u or re.match(r"^[a-z]+:", u) or u.startswith("//"):
                    continue
                from urllib.parse import unquote
                if u.startswith("/"):
                    if not u.startswith(base_path):
                        broken.setdefault(u, set()).add(os.path.relpath(p, out))
                        continue
                    t = os.path.join(out, unquote(u[len(base_path):]))
                else:
                    t = os.path.join(d, unquote(u))
                checked += 1
                if not (os.path.isfile(t) or os.path.isfile(os.path.join(t, "index.html"))):
                    broken.setdefault(u, set()).add(os.path.relpath(p, out))
    print(f"K4: проверено внутренних ссылок {checked}, битых адресов {len(broken)}")
    for u, ps in sorted(broken.items())[:30]:
        err("K4", f"битая ссылка {u} (на {len(ps)} стр., напр. {sorted(ps)[0]})")
    if len(broken) > 30:
        err("K4", f"… всего битых адресов {len(broken)}")


def k5(out: str) -> None:
    for f in page_files():
        if not f.endswith(".en.md"):
            continue
        b = f[: -len(".en.md")]
        if any(b.startswith(x) for x in k5_skip):
            continue
        if b.endswith("/_index") or b == "_index":
            rel = b[: -len("_index")]
        elif b.endswith("/index"):
            rel = b[: -len("index")]
        else:
            rel = b + "/"
        p = os.path.join(out, rel, "index.html")
        if not os.path.exists(p):
            err("K5", f"{f}: нет собранной страницы /{rel}")
            continue
        text = " ".join(parse(p).text)
        cyr, lat = len(CYR.findall(text)), len(LAT.findall(text))
        if cyr + lat and cyr / (cyr + lat) > EN_CYR_MAX:
            err("K5", f"{f}: кириллицы {cyr / (cyr + lat):.1%} букв (> {EN_CYR_MAX:.0%}) — не переведено")
        with open(os.path.join(CONTENT, f), encoding="utf-8") as fh:
            m = FORBIDDEN_EN.search(fh.read())
        if m:
            err("K5", f"{f}: «{m.group(0)}» — нарушение правил публичных текстов (родители — только «the author's parents are pilots», пасхалки не упоминать)")


def main() -> int:
    global allow_missing
    only = {"K1", "K2", "K3", "K4", "K5"}
    keep = None
    for a in sys.argv[1:]:
        if a.startswith("--only="):
            only = set(a.split("=", 1)[1].split(","))
        elif a == "--allow-missing":
            allow_missing = True
        elif a.startswith("--k5-skip="):
            k5_skip.extend(x for x in a.split("=", 1)[1].split(",") if x)
        elif a.startswith("--pages="):
            pages.extend(x for x in a.split("=", 1)[1].split(",") if x)
        elif a.startswith("--keep="):
            keep = a.split("=", 1)[1]
    if "K1" in only:
        k1()
    if "K2" in only:
        k2()
    if "K3" in only:
        k3()
    if only & {"K4", "K5"}:
        with open(os.path.join(SITE, "hugo.toml"), "rb") as f:
            base = tomllib.load(f).get("baseURL", "/")
        base_path = "/" + base.split("://", 1)[-1].split("/", 1)[-1] if "://" in base else base
        out = keep or tempfile.mkdtemp(prefix="site_i18n_")
        if build(out):
            if "K4" in only:
                k4(out, base_path)
            if "K5" in only:
                k5(out)
    for e in errors:
        print(e)
    print(f"нарушений {len(errors)}" + (f" ({','.join(sorted(only))})" if only else ""))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
