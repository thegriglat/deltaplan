"""module new, sync, merge, gc — ветки и рабочие копии."""
import fnmatch
import subprocess
from pathlib import Path

from .. import config, copies, gitx
from ..journal import (FINAL, add_event, all_modules, by_default, check_area, check_code, ensure_module, guard_main,
                       is_work_branch, module_base, module_meta, task_cards, task_states)
from ..util import DpError, pretty, subgroup


def resolve_branch(x):
    """модуль или имя ветки → ветка."""
    if gitx.branch_exists(x):
        return x
    mb = config.module_branch(x)
    if gitx.branch_exists(mb):
        return mb
    raise DpError(f"ветки {x} (или {mb}) нет")


def cmd_module_new(a):
    mod = a.module
    br = config.module_branch(mod)
    copy = config.module_copy(mod)
    if gitx.branch_exists(br):
        raise DpError(f"ветка {br} уже есть")
    if copy.exists():
        raise DpError(f"{copy} уже существует")
    base = a.from_ or gitx.git("branch", "--show-current", cwd=gitx.toplevel())
    if not base:
        raise DpError("текущая копия не на ветке — указать базу модуля --from <ветка>")
    if is_work_branch(base):
        raise DpError(f"{base} — ветка модуля или задачи dpcli; модуль заводится от фичеветки задачи: --from <ветка>")
    if not gitx.branch_exists(base):
        raise DpError(f"базовой ветки {base} нет")
    if a.code:
        check_code(a.code, mod)  # до git worktree add: неверный код не оставляет ветку и копию
    check_area(a.area)
    copies.create(copy, br, base)
    try:
        home = copy / config.plan_dir() / mod
        ensure_module(mod, home, copy=pretty(copy), code=a.code, area=a.area, base=base)
        add_event(home, None, "note", by_default(a), note=f"модуль заведён от {base}")
        h = gitx.commit_paths(copy, [home], f"{mod}: заведён модуль dpcli (module.json, events.jsonl)")
    except BaseException:
        copies.rollback(copy, br)  # не оставлять ветку модуля без копии и журнала
        raise
    print(f"{mod}: {br} от {base} @ {pretty(copy)}, коммит {h}")
    for ln in copies.setup(copy):
        print(f"  {ln}")


def cmd_copy_setup(a):
    path = Path(a.path).expanduser() if a.path else gitx.toplevel()
    if not (path / ".git").exists():
        raise DpError(f"{pretty(path)} — не рабочая копия git")
    for ln in copies.setup(path):
        print(ln)


def cmd_sync(a):
    br = resolve_branch(a.target)
    path = gitx.copy_of(br)
    if not path:
        raise DpError(f"у ветки {br} нет рабочей копии")
    main = base_of(br)
    h, n, kind = gitx.do_merge(path, main, a.message or f"Слияние {main} в {br}", trailers=a.trailer)
    print(f"{br}: {main} уже влит" if kind == "up-to-date" else f"{br}: влит {main}, {h}, файлов {n}")


def base_of(br):
    """Куда по умолчанию вливается ветка и откуда она подтягивает свежее: ветка задачи → её base из карточки
    (ветка модуля), ветка модуля → база модуля (фичеветка), иначе — None."""
    mod = config.module_of_branch(br)
    mods = all_modules()
    if mod and mod in mods:
        return module_base(module_meta(mod, mods[mod]))
    f = config.task_branch_fields(br)
    if f and f.get("module") in mods:
        card = task_cards(mods[f["module"]]).get(f.get("task")) or {}
        return card.get("base") or config.module_branch(f["module"])
    return None


def cmd_merge(a):
    from .search import sem_index_bg
    br = resolve_branch(a.branch)
    into = a.into or base_of(br)
    if not into:
        raise DpError(f"{br} — не ветка модуля или задачи dpcli: указать --into <ветка>")
    guard_main(into, bool(a.into))
    path = gitx.copy_of(into)
    if not path:
        raise DpError(f"ветка {into} нигде не выписана — нужна копия, где она открыта")
    subj = gitx.gitr("log", "-1", "--format=%s", br, "--").stdout.strip()
    h, n, kind = gitx.do_merge(path, br, a.message or f"Слияние {br}: {subj}", ff=False, trailers=a.trailer)
    out = f"{into}: {br} уже влита" if kind == "up-to-date" else f"{into} {h}: слияние {br}, файлов {n}"
    if a.push:
        r = gitx.gitr("push", "origin", into, cwd=path)
        if r.returncode:
            raise DpError(f"{out}; push не удался: {gitx.gerr(r)}")
        out += "; pushed"
    if into == config.main_branch() and kind != "up-to-date" and not a.no_index:
        msg = sem_index_bg()
        out += f"; {msg}" if msg else ""
    print(out)


def gc_live_reason(b, merged, mods):
    """Почему влитую ветку нельзя убирать: у модуля/задачи идёт работа. None — можно."""
    mod = config.module_of_branch(b)
    is_mod = mod is not None
    if not is_mod:
        tf = config.task_branch_fields(b)
        mod = tf.get("module") if tf else None
    if not mod or mod not in mods:
        return None
    home = mods[mod]
    st = task_states(home)
    cards = task_cards(home)
    if is_mod:
        live = sorted(t for t in cards if st.get(t, {}).get("status", "created") not in FINAL)
        if live:
            return f"у модуля незакрытые задачи ({', '.join(live[:4])}{'…' if len(live) > 4 else ''})"
        subs = [x for x in gitx.local_branches()
                if x not in merged and (config.task_branch_fields(x) or {}).get("module") == mod]
        if subs:
            return f"живые ветки задач ({', '.join(subs[:3])})"
        return None
    for t, c in cards.items():
        if c and c.get("branch") == b and st.get(t, {}).get("status", "created") not in FINAL:
            return f"задача {t} не закрыта ({st.get(t, {}).get('status', 'created')})"
    return None


def gc_symlink_reason(path, wt_paths):
    """Симлинки из других копий внутрь path (например на .venv) — их сломает удаление копии."""
    root = Path(path).resolve()
    hits = []
    for other in wt_paths:
        if Path(other).resolve() == root:
            continue
        for xy, name in gitx.status_entries(other, "--ignored"):
            if xy not in ("??", "!!"):
                continue
            f = Path(other) / name.rstrip("/")
            if f.is_symlink():
                try:
                    tgt = f.resolve()
                except OSError:
                    continue
                if tgt == root or root in tgt.parents:
                    hits.append(f"{pretty(f)} → {pretty(tgt)}")
    return f"на неё ссылаются симлинки других копий ({'; '.join(hits[:2])})" if hits else None


def ignored_dirs(path):
    """Игнорируемые git каталоги копии, кроме кешей сборки gc.ignore_dirs (их тоже снимет удаление копии)."""
    skip = set(config.get("gc.ignore_dirs") or [])
    return [f for xy, f in gitx.status_entries(path, "--ignored") if xy == "!!" and f.endswith("/")
            and f.rstrip("/").split("/")[0] not in skip and not any(f"{d}/" in f for d in skip)]


def junk_ok(f):
    """Неотслеживаемый файл — сгенерированный (gc.ignore_globs, либо внутри каталога из gc.ignore_dirs), не работа."""
    name = f.rstrip("/").rsplit("/", 1)[-1]
    if set(f.rstrip("/").split("/")) & {str(d) for d in config.get("gc.ignore_dirs") or []}:
        return True
    return any(fnmatch.fnmatch(name, g) or fnmatch.fnmatch(f, g) for g in config.get("gc.ignore_globs") or [])


def remove_copy(path):
    """Снять копию: отказ (→ причина) при изменениях в отслеживаемых файлах и при неотслеживаемых файлах-работе;
    игнорируемое git и сгенерированное (gc.ignore_dirs, gc.ignore_globs) копию удалять не мешает. → (причина|None, игнорируемые каталоги)."""
    d = gitx.dirty(path)
    if d:
        return f"грязная копия ({len(d)} файлов)", []
    junk = [f for xy, f in gitx.status_entries(path) if xy == "??"]
    other = [f for f in junk if not junk_ok(f)]
    if other:
        return f"неотслеживаемые файлы ({len(other)}: {', '.join(other[:3])})", []
    ign = ignored_dirs(path)
    # только сгенерированное — не работа: git отказывает на неотслеживаемом, поэтому --force
    r = gitx.gitr("worktree", "remove", *(["--force"] if junk else []), str(path))
    if r.returncode:
        return gitx.gerr(r), []
    return None, ign


def cmd_gc(a):
    main = config.main_branch()
    main_tip = gitx.gitr("rev-parse", main).stdout.strip()
    merged = [b for b in gitx.gitr("branch", "--merged", main, "--format=%(refname:short)").stdout.split() if b != main]
    here = str(gitx.toplevel())
    wt = {b: p for p, b in gitx.worktrees()}
    n = 0
    if a.branches:
        want = {x if "/" in x else config.module_branch(x) for x in a.branches} | set(a.branches)
        miss = [x for x in a.branches if x not in merged and config.module_branch(x) not in merged]
        if miss:
            raise DpError(f"не влиты в {main} или нет такой ветки: {', '.join(miss)}")
        merged = [b for b in merged if b in want]
    mods = all_modules()
    for b in merged:
        if gitx.gitr("rev-parse", b).stdout.strip() == main_tip:
            continue  # ветка = главной (только что заведена или влита fast-forward) — не трогаем
        path = wt.get(b)
        label = f"{b}" + (f" @ {pretty(path)}" if path else " (без копии)")
        why = gc_live_reason(b, merged, mods) or (path and gc_symlink_reason(path, wt.values()))
        if why:
            print(f"пропуск {label}: {why}")
            continue
        if not a.remove:
            ign = ignored_dirs(path) if path else []
            print(label + (f" (снимет и игнорируемые: {', '.join(ign[:4])})" if ign else ""))
            n += 1
            continue
        if path and path == here:
            print(f"пропуск {label}: это текущая копия")
            continue
        ign = []
        if path:
            why_not, ign = remove_copy(path)
            if why_not:
                print(f"пропуск {label}: {why_not}")
                continue
        r = gitx.gitr("branch", "-d", b)
        print((f"удалено {label}" + (f" (с игнорируемыми: {', '.join(ign[:4])})" if path and ign else ""))
              if r.returncode == 0 else f"копия снята, ветка {b} осталась: {gitx.gerr(r)}")
        n += 1
    if not n:
        print("влитых веток нет")


def register(sp):
    msp = subgroup(sp, "module", "модуль: new (ветка + копия + журнал) | init (только журнал)")
    q = msp.add_parser("new", help="ветка модуля (module_branch) + git worktree (module_copy) + module.json/events.jsonl")
    q.add_argument("module"); q.add_argument("--from", dest="from_", default=None,
                                             help="база модуля — фичеветка задачи (по умолчанию текущая ветка главной копии)")
    q.add_argument("--by")
    q.add_argument("--code", help="код модуля для ID задач: 2–4 заглавные латинские (NN, UC), уникален")
    q.add_argument("--area", help="подпроект модуля (ключ areas в конфиге): чью продуктовую цель закрывает модуль")
    q.set_defaults(func=cmd_module_new)

    csp = subgroup(sp, "copy", "рабочие копии: setup (подготовить копию — хуки, env, node_modules, worktree.setup)")
    q = csp.add_parser("setup", help="перенести в копию из главной то, чего нет в git (конфиг worktree.*); идемпотентно")
    q.add_argument("path", nargs="?", help="путь к копии (по умолчанию текущая)")
    q.set_defaults(func=cmd_copy_setup)

    q = sp.add_parser("sync", help="влить базу модуля (ветку, от которой он заведён) в ветку модуля (в её копии)")
    q.add_argument("target", metavar="модуль|ветка")
    q.add_argument("--message", "-m", help="сообщение слияния вместо стандартного")
    q.add_argument("--trailer", action="append", help="доп. строка в конец сообщения (можно несколько)")
    q.set_defaults(func=cmd_sync)

    q = sp.add_parser("merge", help="слияние --no-ff ветки в целевую (в копии, где она выписана)")
    q.add_argument("branch", metavar="ветка|модуль")
    q.add_argument("--into", default=None, help="целевая ветка (по умолчанию: задача → ветка модуля, модуль → его база; "
                                               "в main_branch — только явно)")
    q.add_argument("--push", action="store_true")
    q.add_argument("--no-index", action="store_true", help="не обновлять смысловой индекс в фоне (при слиянии в главную ветку)")
    q.add_argument("--message", "-m", help="сообщение слияния вместо стандартного")
    q.add_argument("--trailer", action="append", help="доп. строка в конец сообщения (можно несколько)")
    q.set_defaults(func=cmd_merge)

    q = sp.add_parser("gc", help="копии и ветки, уже влитые в главную ветку (список; --remove — удалить)")
    q.add_argument("branches", nargs="*", metavar="ВЕТКА|МОДУЛЬ", help="только эти (модуль → ветка модуля)")
    q.add_argument("--remove", action="store_true")
    q.set_defaults(func=cmd_gc)
