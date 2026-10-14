"""Рабочие копии (git worktree): создание с git-crypt, подготовка, откат.

create() — `git worktree add --no-checkout`, ключи git-crypt в GIT_DIR копии, затем checkout: иначе smudge-фильтр
git-crypt падает (ключи лежат в общем .git, а у копии свой GIT_DIR). Неудача — копия и созданная ветка убираются.
setup() — то, чего нет в git, но без чего копия не рабочая: каталог хуков (core.hooksPath), игнорируемые файлы
из главной копии по шаблонам worktree.copy (копией) и worktree.link (жёсткими ссылками), команда worktree.setup.
"""
import fnmatch
import os
import shutil
import subprocess
from pathlib import Path

from . import config, gitx
from .util import DpError, pretty

CRYPT_MAGIC = b"\x00GITCRYPT"


def _git_dir(path, common=False):
    d = gitx.git("rev-parse", "--path-format=absolute", "--git-common-dir" if common else "--git-dir", cwd=path)
    return Path(d) if d else None


def _copy_crypt_keys(path):
    """Ключи git-crypt из общего .git в GIT_DIR копии (копией, не симлинком). → True, если git-crypt есть."""
    src = _git_dir(path, common=True) / "git-crypt"
    if not src.is_dir():
        return False
    dst = _git_dir(path) / "git-crypt"
    if not dst.exists():
        shutil.copytree(src, dst, symlinks=True)
    return True


def still_encrypted(path):
    """Файлы с filter=git-crypt, оставшиеся зашифрованными (начинаются с \\0GITCRYPT)."""
    files = gitx.gitr("ls-files", "-z", cwd=path).stdout
    if not files:
        return []
    r = subprocess.run(["git", "check-attr", "-z", "filter", "--stdin"], cwd=path, input=files,
                       capture_output=True, text=True)
    parts = r.stdout.split("\0")
    out = []
    for i in range(0, len(parts) - 2, 3):
        f, val = parts[i], parts[i + 2]
        if val != "git-crypt":
            continue
        try:
            with open(Path(path) / f, "rb") as fh:
                if fh.read(len(CRYPT_MAGIC)) == CRYPT_MAGIC:
                    out.append(f)
        except OSError:
            pass
    return out


def rollback(path, branch=None):
    """Убрать копию (и ветку, если её создали мы) после неудачи; ошибки отката не скрывают исходную."""
    gitx.gitr("worktree", "remove", "--force", "--force", str(path))
    if Path(path).exists() and not (Path(path) / ".git").exists():
        shutil.rmtree(path, ignore_errors=True)
    gitx.gitr("worktree", "prune")
    if branch and gitx.branch_exists(branch):
        gitx.gitr("branch", "-D", branch)
    gitx.reset_worktrees()


def create(path, branch, base=None):
    """Копия path на ветке branch; base задан — новая ветка от base. Неудача — откат и DpError.

    Расшифровку проверяет setup()."""
    path = Path(path)
    args = ["worktree", "add", "--no-checkout"] + (["-b", branch, str(path), base] if base else [str(path), branch])
    r = gitx.gitr(*args)
    gitx.reset_worktrees()
    if r.returncode:
        if base and not gitx.copy_of(branch) and gitx.branch_exists(branch):
            gitx.gitr("branch", "-D", branch)
        raise DpError(f"git worktree add {pretty(path)}: {gitx.gerr(r)}")
    try:
        _copy_crypt_keys(path)
        r = gitx.gitr("checkout", cwd=path)
        if r.returncode:
            raise DpError(f"checkout в {pretty(path)}: {gitx.gerr(r)}")
    except BaseException:
        rollback(path, branch if base else None)
        raise


def _match(rel_path, pats):
    """Шаблон без «/» — по имени (на любой глубине), со «/» — по пути от корня копии."""
    name = rel_path.rsplit("/", 1)[-1]
    return any(fnmatch.fnmatch(rel_path if "/" in p else name, p) for p in pats)


def _cp(src, dst, link):
    """cp -al (жёсткие ссылки; не вышло — обычная копия) или cp -a."""
    if link:
        r = subprocess.run(["cp", "-al", str(src), str(dst)], capture_output=True, text=True)
        if r.returncode == 0:
            return "ссылки"
        if Path(dst).is_dir():
            shutil.rmtree(dst, ignore_errors=True)
    r = subprocess.run(["cp", "-a", str(src), str(dst)], capture_output=True, text=True)
    if r.returncode:
        raise DpError(f"cp {src} → {dst}: {r.stderr.strip()}")
    return "копия"


def _copy_missing(src, dst):
    """Докопировать в dst файлы src, которых там нет (свои файлы копии не перезаписываются). → сколько добавлено."""
    n = 0
    for d, _dirs, files in os.walk(src):
        rel = Path(d).relative_to(src)
        (dst / rel).mkdir(parents=True, exist_ok=True)
        for f in files:
            t = dst / rel / f
            if not t.exists() and not t.is_symlink():
                shutil.copy2(Path(d) / f, t, follow_symlinks=False)
                n += 1
    return n


def hooks_dir(root=None):
    """Относительный core.hooksPath (напр. .husky/_) или None."""
    hp = gitx.git("config", "--get", "core.hooksPath", cwd=root)
    return hp.strip().rstrip("/").removeprefix("./") if hp and not os.path.isabs(os.path.expanduser(hp)) else None


def setup(path):
    """Подготовить копию по worktree.* конфига; идемпотентно (что уже есть — не трогает). → строки итога."""
    path = Path(path).resolve()
    main = gitx.main_worktree()
    lines = []
    if main is None or main.resolve() == path:
        return ["подготовка: это главная копия — нечего переносить"]
    main = main.resolve()
    if _copy_crypt_keys(path):
        enc = still_encrypted(path)
        if enc:
            lines.append(f"git-crypt: не расшифровано {len(enc)} ({', '.join(enc[:3])}) — git -C {path} crypt unlock")

    hp = hooks_dir(path) if config.get("worktree.hooks", True) else None
    if hp and (main / hp).is_dir() and not gitx.git("ls-files", "--", hp, cwd=path):
        added = _copy_missing(main / hp, path / hp)
        if added:
            lines.append(f"хуки: {hp} из главной копии ({added} файл(ов))")

    link = [str(x) for x in config.get("worktree.link") or []]
    copy = [str(x) for x in config.get("worktree.copy") or []]
    done = {"ссылки": [], "копия": []}
    if link or copy:
        out = gitx.gitr("-c", "core.quotepath=off", "ls-files", "-z", "--others", "--ignored", "--exclude-standard",
                        "--directory", cwd=main).stdout
        for ent in sorted(e.rstrip("/") for e in out.split("\0") if e):
            if hp and (ent == hp or ent.startswith(hp + "/")):
                continue
            is_link = _match(ent, link)
            if not is_link and not _match(ent, copy):
                continue
            src, dst = main / ent, path / ent
            if dst.exists() or dst.is_symlink() or not dst.parent.is_dir():
                continue  # уже есть или каталога нет в этой ветке
            done[_cp(src, dst, is_link)].append(ent)
    for k, v in done.items():
        if v:
            lines.append(f"из главной копии ({k}): {', '.join(v)}")

    cmd = config.get("worktree.setup")
    if cmd:
        env = dict(os.environ, DPCLI_COPY=str(path), DPCLI_MAIN_COPY=str(main),
                   DPCLI_BRANCH=gitx.git("branch", "--show-current", cwd=path))
        to = int(config.get("worktree.setup_timeout", 1800))
        try:
            r = subprocess.run(["bash", "-c", str(cmd)], cwd=path, env=env, capture_output=True, text=True, timeout=to)
            ok, tail = r.returncode == 0, (r.stderr.strip() or r.stdout.strip()).splitlines()[-3:]
        except subprocess.TimeoutExpired:
            ok, tail = False, [f"таймаут {to} с"]
        lines.append(f"worktree.setup: {'ок' if ok else 'ОШИБКА — ' + ' | '.join(tail)}")
        if not ok:
            lines.append(f"повторить: .dpcli/dpcli copy setup {path}")
    return lines or ["подготовка: переносить нечего"]
