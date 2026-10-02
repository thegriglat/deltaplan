#!/usr/bin/env python3
"""Разовый (повторяемый) перевод старых журналов docs/plan/*_progress.md в формат tools/dp.

    python3 tools/dp_migrate.py [--dry] [--only файл_или_модуль …]

Для каждого журнала создаёт docs/plan/<модуль>/ (module.json, tasks/<ID>.json, tasks/<ID>.report.json,
events.jsonl, decisions.jsonl). Исходные _progress.md не меняются. Всё, что не разобралось, — событие `note`
модуля с исходным текстом (до 400 символов) и ссылкой src на строку исходного файла.
Перезапуск перезаписывает каталоги модулей целиком (миграция детерминирована).
"""
import shutil, argparse, datetime as dt, json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLAN = ROOT / "docs/plan"
YEAR = "2026"
# файл журнала → имя модуля dp (как ветка feature/<модуль>)
MODULES = {
    "air-start": "air-start", "air_model": "air-model", "control-fix": "control-fix",
    "site_update": "site-update", "start_fixes": "start-fixes", "wing-physics-check": "wing-physics-check",
    "wings_models3d": "wings-models3d", "wings_passports": "wings-passports", "world_easter_eggs": "easter-eggs",
}
SKIP = {"ui-controls", "air_nn"}

USER_RX = re.compile(r"решени[яеий]\s+(?:\*\*)?пользовател|\(пользовател|пользовател[яь]\)|ответы пользовател|"
                     r"по решению пользовател|пользовател[ьея]:|требование пользовател|пользователь\b.{0,20}(?:решил|одобрил|снял)|"
                     r"решение пользователя|одобрени[ея] пользовател", re.I)
COORD_RX = re.compile(r"^\W*Решени[яе]\s+К\d", re.I)
DECISION_SEC = re.compile(r"Решени|Развилк|Шлюз", re.I)
HASH = re.compile(r"(?<![\w/.-])(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,10}(?![\w-])")
ID_RX = re.compile(r"^([A-ZА-ЯЁ]{1,4}[0-9]*(?:[.-][0-9A-Za-zА-я.]*[0-9A-Za-zА-я])?[а-я]?)(?=\s|$)")
DATE_RX = re.compile(r"^\W*?(?:(\d{4})-(\d{2})-(\d{2})|(\d{2})\.(\d{2})(?:\.(\d{4}))?)(?!\d)")
ANYDATE = re.compile(r"(?:(\d{4})-(\d{2})-(\d{2})|(?<![\d.])(\d{2})\.(\d{2})(?:\.(\d{4}))?(?![\d.]*\d))")

_ct = {}


def commit_time(h):
    """ISO-время коммита или None (хеша нет в истории)."""
    if h not in _ct:
        r = subprocess.run(["git", "-C", str(ROOT), "show", "-s", "--format=%cI", h], capture_output=True, text=True)
        v = r.stdout.strip() if r.returncode == 0 else ""
        _ct[h] = v[:19] if v else None
    return _ct[h]


def mkdate(m):
    """regex-совпадение (ANYDATE/DATE_RX) → YYYY-MM-DD (dd.mm в 2026-м)."""
    g = m.groups()
    if g[0]:
        return f"{g[0]}-{g[1]}-{g[2]}"
    if int(g[4]) > 12 or int(g[3]) > 31:
        return None
    return f"{g[5] or YEAR}-{g[4]}-{g[3]}"


def find_date(text):
    m = ANYDATE.search(text)
    return mkdate(m) if m else None


def clip(s, n=400):
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def plain(s):
    return s.replace("**", "").strip()


def dump(p, o):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(o, ensure_ascii=False, indent=2) + "\n")


def split_row(line, n):
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if n and len(cells) > n:  # «|» внутри текста — хвост в последнюю ячейку
        cells = cells[: n - 1] + [" | ".join(cells[n - 1:])]
    return cells


def parse_journal(src):
    """Журнал → (tasks, decisions, events, notes). Все записи несут 'line' — номер строки исходника."""
    lines = src.read_text().splitlines()
    tasks, decs, evs, notes = [], [], [], []
    sec, sec_date, last_date = "", None, None
    hdr = None
    first_date = find_date(src.read_text()) or "2026-10-01"
    i = 0
    n = len(lines)

    def block_end(j):
        """конец абзаца/пункта: до пустой строки, заголовка, таблицы или нового пункта на нулевом отступе"""
        k = j + 1
        while k < n and lines[k].strip() and not lines[k].startswith(("#", "|")) \
                and (lines[k][0] in " \t" or not re.match(r"^([-*]\s|\d+\.\s)", lines[k])):
            k += 1
        return k

    while i < n:
        ln = lines[i]
        if not ln.strip():
            hdr = None if hdr and not lines[i - 1].startswith("|") else hdr
            i += 1
            continue
        if ln.startswith("#"):
            sec = ln.lstrip("#").strip()
            sec_date = find_date(sec) or None
            if sec_date:
                last_date = sec_date
            hdr = None
            i += 1
            continue
        if ln.startswith("|"):
            if i + 1 < n and re.match(r"^\|[\s:|-]+\|?\s*$", lines[i + 1]) and not re.match(r"^\|[\s:|-]+\|?\s*$", ln):
                hdr = split_row(ln, 0)
                i += 2
                continue
            if re.match(r"^\|[\s:|-]+\|?\s*$", ln):
                i += 1
                continue
            cells = split_row(ln, len(hdr) if hdr else 0)
            if hdr and hdr[0] in ("Задача", "Шаг"):
                tasks.append({"line": i + 1, "hdr": hdr, "cells": cells, "sec": sec})
            else:
                notes.append({"line": i + 1, "text": " | ".join(cells), "date": last_date or first_date, "why": "строка таблицы"})
            i += 1
            continue
        # пункт или абзац
        j = block_end(i)
        text = " ".join(l.strip() for l in lines[i:j])
        body = re.sub(r"^([-*]|\d+\.)\s+", "", text)
        is_bullet = bool(re.match(r"^([-*]|\d+\.)\s", text))
        dm = DATE_RX.match(plain(body))
        own = mkdate(dm) if dm else None
        if own:
            last_date = own
            body_clean = re.sub(r"^\W*?(?:\d{4}-\d{2}-\d{2}|\d{2}\.\d{2}(?:\.\d{4})?)\s*[—–:-]*\s*", "", plain(body), count=1) or body
        else:
            body_clean = plain(body)
        d = own or sec_date or last_date or first_date
        rec = {"line": i + 1, "text": body_clean, "date": d, "own": bool(own)}
        if USER_RX.search(body):
            decs.append({**rec, "by": "user"})
        elif (is_bullet and DECISION_SEC.search(sec)) or COORD_RX.search(body):
            decs.append({**rec, "by": "coordinator"})
        elif own and is_bullet:
            evs.append(rec)
        else:
            notes.append({**rec, "why": "без даты/классификации"})
        i = j
    return tasks, decs, evs, notes


def col(hdr, *keys):
    for k, h in enumerate(hdr):
        if any(x.lower() in h.lower() for x in keys):
            return k
    return None


def build_module(stem, mod, out):
    src = PLAN / f"{stem}_progress.md"
    text = src.read_text()
    jr = f"docs/plan/{stem}_progress.md"
    tasks, decs, evs, notes = parse_journal(src)
    home = PLAN / mod
    if home.exists():
        shutil.rmtree(home)
    first_date = find_date(text) or "2026-10-01"
    events, decisions, taskdump = [], [], []
    seen = {}
    wp = 0
    for t in tasks:
        hdr, cells = t["hdr"], t["cells"]
        get = lambda *k: (cells[col(hdr, *k)] if col(hdr, *k) is not None and col(hdr, *k) < len(cells) else "")
        first = plain(cells[0])
        m = ID_RX.match(first)
        if hdr[0] == "Шаг":
            wp += 1
            tid, title = f"WP-{wp}", first
        elif m:
            tid, title = m.group(1).rstrip("."), first[m.end():].strip() or first
        else:
            notes.append({"line": t["line"], "text": " | ".join(cells), "date": first_date, "why": "строка таблицы задач без ID"})
            continue
        seen[tid] = seen.get(tid, 0) + 1
        if seen[tid] > 1:
            tid = f"{tid}~{seen[tid]}"
        status = plain(get("Статус"))
        exe = plain(get("Исполнитель"))
        copy_br = get("Копия")
        numcol = col(hdr, "Числа", "Ключевые", "Заметки")
        commitcol = col(hdr, "Коммит")
        numtxt = plain(cells[numcol]) if numcol is not None and numcol < len(cells) else ""
        ctext = cells[commitcol] if commitcol is not None and commitcol < len(cells) else ""
        merge_hashes = []
        for mm in re.finditer(r"(?:слияни[ея]|влит[аы]?|слит[аы]?)\s+(?:в\s+\S+\s+)?(?:итог\s+)?(" + HASH.pattern + ")", ctext + " " + status):
            merge_hashes.append(mm.group(1))
        hashes = list(dict.fromkeys(HASH.findall(ctext)))
        commits = [h for h in hashes if h not in merge_hashes]
        bt = re.findall(r"`([^`]+)`", copy_br)
        card_copy = next((b for b in bt if b.startswith(("~", "/"))), "")
        card_branch = next((b for b in bt if "/" in b and not b.startswith(("~", "/"))), "")
        typ = (re.search(r"dp-[a-z]+", exe) or [None])[0] or (exe.split("(")[0].strip() or "coordinator")
        sd = find_date(status) or find_date(ctext) or first_date
        sl = status.lower()
        if sl.startswith(("снят", "отмен")):
            fin = "cancelled"
        elif re.search(r"принят|готов|сделано|зел[её]н|влит|слит", sl):
            fin = "accepted"
        else:
            fin = None
        # времена
        rep_t = None
        for h in reversed(commits):
            rep_t = commit_time(h)
            if rep_t:
                break
        mrg_t = None
        for h in merge_hashes:
            mrg_t = commit_time(h) or mrg_t
        t0 = f"{sd}T08:00:00"
        if rep_t and rep_t[:10] > sd:  # коммит позже даты статуса — доверяем статусу
            rep_t = None
        rep_t = rep_t or f"{sd}T12:00:00"
        times = [x for x in (commit_time(h) for h in commits) if x and x[:10] <= sd]
        if times and min(times) < t0:  # начало — до первого коммита
            t0 = (dt.datetime.fromisoformat(min(times)) - dt.timedelta(minutes=1)).isoformat()
        acc_t = max(mrg_t or "", rep_t, f"{sd}T12:00:01") if fin else None
        card = {"id": tid, "module": mod, "type": typ, "title": clip(title, 200), "goal": clip(title, 200),
                "plan_ref": tid, "contracts": [], "copy": card_copy, "branch": card_branch, "base": f"feature/{mod}",
                "scope": [], "dont_touch": [], "accept": [], "report_extra": [],
                "notes": f"перенесено из {jr}:{t['line']}", "created": t0, "migrated": True}
        dump(home / "tasks" / f"{tid}.json", card)
        add = lambda tt, by, ev, note="", commits_=None: events.append(
            {"t": tt, "by": by, "task": tid, "ev": ev, **({"commits": commits_} if commits_ else {}), **({"note": note} if note else {}),
             "src": f"{jr}:{t['line']}"})
        add(t0, "coordinator", "created", clip(title, 200))
        if fin or re.search(r"работ|запущ|идёт|идет", sl):
            add((dt.datetime.fromisoformat(t0) + dt.timedelta(seconds=1)).isoformat(), "coordinator", "started", exe or "")
        if fin != "cancelled" and (numtxt or commits):
            summary = (status + (" | " if status and numtxt else "") + numtxt)
            summary = summary if len(summary) <= 4000 else summary[:3999] + "…"
            dump(home / "tasks" / f"{tid}.report.json", {
                "status": "done" if fin else "partial", "summary": summary, "commits": commits,
                "checks": [], "not_done": [], "questions": [], "images": [],
                "how_to_check": f"историческая запись; исходник {jr}:{t['line']}", "dp_feedback": "",
                "t": rep_t, "by": typ, "migrated": True})
            add(rep_t, typ, "reported", "done" if fin else "partial", commits)
        if fin == "accepted":
            add(acc_t, "coordinator", "accepted", clip(status, 300), [])
        elif fin == "cancelled":
            add(f"{sd}T12:00:02", "coordinator", "cancelled", clip(status + " " + numtxt, 300))
        else:
            add(f"{sd}T12:00:02", "coordinator", "note", clip("статус в журнале: " + status, 300))
        if merge_hashes:
            add(mrg_t or f"{sd}T12:00:03", "coordinator", "merged", "", merge_hashes)
    unparsed = 0
    # события и заметки
    for e in evs:
        events.append({"t": f"{e['date']}T12:00:00", "by": "coordinator", "task": None, "ev": "note",
                       "note": clip(e["text"]), "src": f"{jr}:{e['line']}"})
    for nn in notes:
        unparsed += 1
        events.append({"t": f"{nn['date']}T12:00:00", "by": "coordinator", "task": None, "ev": "note",
                       "note": clip(nn["text"]), "src": f"{jr}:{nn['line']}", "unparsed": nn["why"]})
    ids = list(seen)
    for d in decs:
        rec = {"t": d["date"], "by": d["by"], "kind": "decision", "text": d["text"], "src": f"{jr}:{d['line']}"}
        mm = next((x for x in ids if re.search(r"(?<![\w-])" + re.escape(x) + r"(?![\w-])", d["text"])), None)
        if mm:
            rec["task"] = mm
        decisions.append(rec)
    events.sort(key=lambda e: e["t"])
    decisions.sort(key=lambda e: e["t"])
    copy_m = re.search(r"`(~/deltaplan-[\w-]+)`", text)
    contr = re.search(r"`?(docs/[\w/.-]*contracts?[\w.-]*\.md)`?", text)
    plan = f"docs/plan/{stem}.md"
    dump(home / "module.json", {
        "module": mod, "plan": plan if (ROOT / plan).exists() else f"docs/plan/{mod}.md",
        "contracts": contr.group(1) if contr else f"docs/{mod}_contracts.md", "branch": f"feature/{mod}",
        "copy": copy_m.group(1) if copy_m else f"~/deltaplan-{mod}", "created": f"{first_date}T00:00:00",
        "legacy_journal": jr, "migrated_from": f"{jr} (tools/dp_migrate.py)"})
    (home / "events.jsonl").write_text("".join(json.dumps(e, ensure_ascii=False) + "\n" for e in events))
    (home / "decisions.jsonl").write_text("".join(json.dumps(e, ensure_ascii=False) + "\n" for e in decisions))
    out.append((mod, len(seen), len(events), len(decisions), unparsed))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*")
    a = ap.parse_args()
    out = []
    for stem, mod in MODULES.items():
        if a.only and stem not in a.only and mod not in a.only:
            continue
        build_module(stem, mod, out)
    print("модуль | задач | событий | решений | неразобранных строк")
    for r in out:
        print(" | ".join(map(str, r)))


if __name__ == "__main__":
    main()
