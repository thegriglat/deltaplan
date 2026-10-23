"""job (долгие запуски без опроса по имени процесса, окно tmux) и lock (общие замки: gpu — один держатель, cpu — очередь со взвешенными слотами)."""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from .. import config, reexec
from ..util import CLI, DpError, age, now


def job_dir():
    env = os.environ.get("DPCLI_JOB_DIR")
    d = Path(os.path.expanduser(env)) if env else config.expand(config.get("jobs.dir", "~/.cache/dpcli/{project}/jobs"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def job_files(name):
    d = job_dir()
    return d / f"{name}.pid", d / f"{name}.log", d / f"{name}.rc"


def my_ns():
    """Пространство PID этого процесса (песочница агента — своё: PID окна tmux оттуда не видны)."""
    try:
        return os.readlink("/proc/self/ns/pid")
    except OSError:
        return None


def job_state(name):
    """done (есть .rc) | running | gone (умер без кода) | unknown (PID из чужого пространства и окна tmux нет в записи).
    PID из другого пространства PID (.ns не совпал) не проверяем — смотрим, живо ли окно tmux (.win)."""
    pidf, _, rcf = job_files(name)
    d = job_dir()
    if rcf.exists():
        return "done"
    try:
        pid = int(pidf.read_text())
    except (OSError, ValueError):
        return "gone"
    try:
        ns = (d / f"{name}.ns").read_text().strip()
    except OSError:
        ns = None
    if not ns or ns == my_ns():
        if job_alive(pid):
            return "running"
    else:
        try:
            win = (d / f"{name}.win").read_text().strip()
        except OSError:
            return "done" if rcf.exists() else "unknown"
        if tmux_win_alive(win):
            return "running"
    return "done" if rcf.exists() else "gone"


def tmux_win_alive(win):
    r = subprocess.run(["tmux", "display-message", "-p", "-t", win, "#{window_id}"], capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == win


def job_start(name, limit, cmd, tm=None):
    """tm — сессия tmux (tmux_opts) или None; нет tmux/сессии → фон с предупреждением `dpcli: …`."""
    pidf, log, rcf = job_files(name)
    d = job_dir()
    for f in (rcf, pidf, d / f"{name}.ns", d / f"{name}.win"):  # следы прошлого запуска с тем же именем
        f.unlink(missing_ok=True)
    if tm and tmux_job(name, limit, cmd, tm):
        return
    # setsid — своя группа: при таймауте гасится всё дерево; rc пишется всегда (124 — таймаут)
    pr = subprocess.Popen(["setsid", "bash", "-c", 'timeout -k 30 "$1" "${@:3}" >"$2.log" 2>&1; echo $? >"$2.rc"', "_", str(limit),
                           str(d / name), *cmd],
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=False,
                          env={**os.environ, "DPCLI_NO_TMUX": "1"})
    ns = my_ns()
    if ns:
        (d / f"{name}.ns").write_text(ns)
    pidf.write_text(str(pr.pid))
    print(f"{name}: PID {pr.pid}, лог {log}")


# окно tmux = outer (bash; по завершении окно закрывается) → runner (PID в .pid, код в .rc) → script (настоящий tty; лог без \r-перерисовок)
TMUX_RUNNER = r"""#!/bin/bash
# dpcli job: runner <таймаут> <база> <команда…>; PID — этого процесса, код — в <база>.rc
limit=$1; base=$2; shift 2
readlink /proc/$$/ns/pid >"$base.ns" 2>/dev/null
echo $$ >"$base.pid"
rm -f "$base.rc" "$base.cpid" "$base.fifo"
printf -v c '%q ' "$@"
c="echo \$\$ >$(printf %q "$base.cpid"); exec timeout -k 30 $limit $c"
mkfifo "$base.fifo"
awk '/^Script (started|done) on /{next} {n=split($0,a,"\r"); s=a[n]; if(s==""&&n>1)s=a[n-1]; print s; fflush()}' <"$base.fifo" >"$base.log" &
ap=$!
sig=0
script -qefc "$c" "$base.fifo" <&0 &
sp=$!
fw() { sig=$1; [ -s "$base.cpid" ] && kill -TERM "$(cat "$base.cpid")" 2>/dev/null; kill -TERM $sp 2>/dev/null; }
trap 'fw 143' TERM
trap 'fw 129' HUP
while :; do wait $sp; rc=$?; kill -0 $sp 2>/dev/null || break; done
wait $ap 2>/dev/null
rm -f "$base.fifo" "$base.cpid"
[ "$sig" != 0 ] && rc=$sig
echo $rc >"$base.rc"
exit $rc
"""
TMUX_OUTER = r"""runner=$1; shift; base=$2
trap : TERM
export DPCLI_NO_TMUX=1
bash "$runner" "$@"
"""
TMUX_ATTACH = r"""pid=$1; log=$2; rcf=$3
if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then tail -n 40 -F --pid="$pid" "$log"; exit; fi
tail -n 40 "$log"; echo; echo "Задача выполнена (код $(cat "$rcf" 2>/dev/null || echo ?))"
exec bash
"""


def default_session():
    return os.environ.get("DPCLI_TMUX_SESSION") or str(config.get("jobs.tmux_session", "dp"))


def tmux_opts(a):
    """Сессия tmux или None. Окно — по умолчанию (сессия $DPCLI_TMUX_SESSION, иначе jobs.tmux_session; нет — создаётся);
    --no-tmux и DPCLI_NO_TMUX (внутри задачи job) выключают."""
    if getattr(a, "no_tmux", False) or os.environ.get("DPCLI_NO_TMUX"):
        return None
    return getattr(a, "tmux_session", None) or default_session()


def tmux_args(q):
    q.add_argument("--tmux", action="store_true", help="окно tmux (это и так по умолчанию)")
    q.add_argument("--no-tmux", dest="no_tmux", action="store_true", help="без окна tmux, только фон")
    q.add_argument("--tmux-session", dest="tmux_session", metavar="S",
                   help="сессия tmux (по умолчанию $DPCLI_TMUX_SESSION, иначе jobs.tmux_session)")


def tmux_ok(sess):
    why = None
    if not shutil.which("tmux"):
        why = "нет tmux"
    elif subprocess.run(["tmux", "has-session", "-t", "=" + sess], capture_output=True).returncode and \
            subprocess.run(["tmux", "new-session", "-d", "-s", sess, "-n", "dpcli", "-c", str(Path.home())], capture_output=True).returncode:
        why = f"не удалось создать сессию {sess}"
    elif not shutil.which("script"):
        why = "нет script (util-linux)"
    if why:
        print(f"dpcli: tmux: {why} — запуск в фоне", file=sys.stderr)
    return why is None


def tmux_window(name, sess, argv, env=False):
    """Новое окно в сессии (имя занято — name-2, name-3…; старые окна не трогаем). → (window_id, имя) или None."""
    r = subprocess.run(["tmux", "list-windows", "-t", "=" + sess + ":", "-F", "#{window_name}"], capture_output=True, text=True)
    used = set(r.stdout.split())
    wn, i = name, 1
    while wn in used:
        i += 1
        wn = f"{name}-{i}"
    a = ["tmux", "new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=" + sess + ":", "-n", wn, "-c", os.getcwd()]
    if env:
        for k, v in os.environ.items():
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k) and not k.startswith("TMUX") and k not in ("PWD", "OLDPWD", "SHLVL", "_"):
                a += ["-e", f"{k}={v}"]
    r = subprocess.run(a + argv, capture_output=True, text=True)
    if r.returncode:
        print(f"dpcli: tmux: окно не создано ({r.stderr.strip()[:100]}) — запуск в фоне", file=sys.stderr)
        return None
    return r.stdout.strip(), wn


def tmux_job(name, limit, cmd, sess):
    if not tmux_ok(sess):
        return False
    pidf, log, rcf = job_files(name)
    d = job_dir()
    runner = d / ".tmux_runner.sh"
    if not runner.exists() or runner.read_text() != TMUX_RUNNER:
        tmp = d / f".tmux_runner.{os.getpid()}"
        tmp.write_text(TMUX_RUNNER)
        tmp.rename(runner)
    pidf.unlink(missing_ok=True)
    w = tmux_window(name, sess, ["bash", "-c", TMUX_OUTER, "_", str(runner), str(limit), str(d / name), *cmd], env=True)
    if not w:
        return False
    (d / f"{name}.win").write_text(w[0])
    for _ in range(600):
        if pidf.exists() and pidf.read_text().strip():
            print(f"{name}: PID {pidf.read_text().strip()}, лог {log}, окно tmux {sess}:{w[1]}")
            return True
        time.sleep(0.05)
    # окно не отозвалось за 30 с — закрываем, чтобы команда не пошла дважды (окно + фон)
    subprocess.run(["tmux", "kill-window", "-t", w[0]], capture_output=True)
    (d / f"{name}.win").unlink(missing_ok=True)
    pidf.unlink(missing_ok=True)
    print(f"dpcli: tmux: окно {sess}:{w[1]} не запустило задачу", file=sys.stderr)
    return False


def job_attach(name, sess):
    pidf, log, rcf = job_files(name)
    if not log.exists():
        raise DpError(f"{name}: журнала нет ({log})")
    if not tmux_ok(sess):
        raise DpError("tmux недоступен — окно не открыто")
    try:
        pid = int(pidf.read_text())
    except (OSError, ValueError):
        pid = 0
    w = tmux_window(name, sess, ["bash", "-c", TMUX_ATTACH, "_", str(pid), str(log), str(rcf)])
    if not w:
        raise DpError("окно не открыто")
    print(f"{name}: окно tmux {sess}:{w[1]} (tail -F журнала)")


def job_alive(pid):
    try:
        os.kill(pid, 0)
        return Path(f"/proc/{pid}").exists() and Path(f"/proc/{pid}/stat").read_text().split()[2] != "Z"
    except OSError:
        return False


def job_stop(name):
    pidf = job_files(name)[0]
    try:
        pid = int(pidf.read_text())
    except (OSError, ValueError):
        raise DpError(f"{name}: не запускался")
    if not job_alive(pid):
        try:  # PID из чужого пространства (песочница) — гасим окно tmux: runner получит HUP и остановит команду
            win = (job_dir() / f"{name}.win").read_text().strip()
        except OSError:
            return False
        if job_state(name) != "running":
            return False
        subprocess.run(["tmux", "kill-window", "-t", win], capture_output=True)
        return pid
    if Path(f"/proc/{pid}").stat().st_uid != os.getuid() or \
            str(job_dir() / name) not in Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace"):
        raise DpError(f"PID {pid} — не наш запуск {name}, не трогаю")
    try:
        os.killpg(os.getpgid(pid), 15)
    except OSError:
        os.kill(pid, 15)
    return pid


def cmd_job(a):
    pidf, log, rcf = job_files(a.name) if a.name else (None, None, None)
    if a.action == "start":
        if not a.cmd or a.timeout is None:
            raise DpError(f"{CLI} job start <имя> <таймаут_с> <команда…>")
        cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
        if a.slots is not None and a.lock != "cpu":
            raise DpError("job start: --slots — только с --lock cpu")
        if a.lock:
            cmd = [*reexec.self_cmd(), "lock", a.lock, a.name, *(["--slots", str(a.slots)] if a.slots is not None else []), "--", *cmd]
        job_start(a.name, a.timeout, cmd, tmux_opts(a))
        return
    if a.action == "status" and not a.name:
        rows = []
        for f in job_dir().glob("*.pid"):
            n = f.stem
            rc = job_dir() / f"{n}.rc"
            js = job_state(n)
            st = f"код {rc.read_text().strip()}" if rc.exists() else "идёт" if js == "running" else "нет данных"
            mt = max(x.stat().st_mtime for x in (f, rc, job_dir() / f"{n}.log") if x.exists())
            rows.append((st == "идёт", mt, n, st))
        rows.sort(key=lambda r: (not r[0], -r[1]))
        run = [r for r in rows if r[0]]
        done = [r for r in rows if not r[0]]
        show = run + (done if a.all or "--all" in (a.cmd or []) else done[:max(0, 10 - len(run))] if done else [])
        for _, mt, n, st in show:
            print(f"{n}: {st}" + ("" if st == "идёт" else f" ({age(dt.datetime.fromtimestamp(mt).isoformat(timespec='seconds'))})"))
        if not rows:
            print("запусков нет")
        elif len(show) < len(rows):
            print(f"… ещё {len(rows) - len(show)} завершённых (--all)")
        return
    if not a.name:
        raise DpError(f"{CLI} job {a.action} <имя>")
    if a.action == "wait":
        try:
            pid = int(pidf.read_text())
        except (OSError, ValueError):
            print(f"{a.name}: не запускался")
            sys.exit(2)
        limit = a.timeout
        if limit is None:
            raise DpError(f"{CLI} job wait <имя> <таймаут_с> — таймаут обязателен")
        deadline = time.time() + limit
        while job_state(a.name) in ("running", "unknown") and time.time() < deadline:
            time.sleep(0.3)
        if rcf.exists():
            rc = int(rcf.read_text().strip() or 1)
            print(f"{a.name}: код {rc}")
            print("\n".join(log.read_text(errors="replace").splitlines()[-20:]))
            sys.exit(rc)
        if job_state(a.name) == "gone":
            print(f"{a.name}: прерван (нет кода выхода — остановлен job stop или убит)")
            sys.exit(143)
        print(f"{a.name}: ещё идёт (PID {pid}) — ожидание прервано по таймауту {limit} с")
        sys.exit(124)
    if a.action == "status":
        print(f"{a.name}: " + (f"код {rcf.read_text().strip()}" if rcf.exists()
                               else "идёт" if job_state(a.name) == "running" else "нет данных"))
        return
    if a.action == "stop":
        pid = job_stop(a.name)
        print(f"{a.name}: остановлен (PID {pid})" if pid else f"{a.name}: уже не идёт")
    if a.action in ("attach", "tmux"):
        job_attach(a.name, a.tmux_session or default_session())


# ---------------------------------------------------------------- lock

def locks_dir():
    v = config.get("locks")
    d = config.expand(v) if v else job_dir() / "locks"
    d.mkdir(parents=True, exist_ok=True)
    return d


GPU_LOCK = "gpu.lock"
CPU_STATE = "cpu.json"  # очередь и держатели cpu; меняется только под flock(cpu.json.lock)


def cpu_cfg(key):
    """jobs.<key> из конфига ГЛАВНОЙ копии (замок cpu общий на машину; копии на старых ветках имеют другой dpcli.yml);
    нет главной копии или файла в ней — из конфига текущей."""
    from .. import gitx
    try:
        mw = gitx.main_worktree() if config.path_of_config() else None
        if mw:
            for n in config.NAMES:
                f = Path(mw) / n
                if f.is_file():
                    v = (config.merge(config.DEFAULTS, config.parse_file(f)).get("jobs") or {}).get(key)
                    return v
    except (DpError, OSError):
        pass
    return config.get("jobs." + key)


def cpu_total():
    """M — всего слотов cpu (DPCLI_CPU_SLOTS, иначе jobs.cpu_slots главной копии, иначе половина логических ядер)."""
    return max(1, int(os.environ.get("DPCLI_CPU_SLOTS") or cpu_cfg("cpu_slots") or max(1, (os.cpu_count() or 8) // 2)))


def cpu_starve_s():
    v = os.environ.get("DPCLI_CPU_STARVE_S")
    if v is None:
        v = cpu_cfg("cpu_starve_s")
    return float(300 if v is None else v)


def cpu_weight(cmd):
    """Вес команды по jobs.cpu_weights главной копии (первое совпадение регэкспа по строке команды), иначе 1."""
    line = " ".join(cmd)
    for r in cpu_cfg("cpu_weights") or []:
        try:
            if re.search(str(r["match"]), line):
                return int(r["slots"])
        except (KeyError, TypeError, ValueError, re.error) as e:
            raise DpError(f"jobs.cpu_weights: неверное правило {r!r} ({e})")
    return 1


def cpu_enforce_mode():
    """cgroup | taskset | off: DPCLI_CPU_ENFORCE, иначе jobs.cpu_enforce главной копии (по умолчанию cgroup)."""
    v = str(os.environ.get("DPCLI_CPU_ENFORCE") or cpu_cfg("cpu_enforce") or "cgroup").strip().lower()
    if v not in ("cgroup", "taskset", "off"):
        raise DpError(f"jobs.cpu_enforce / DPCLI_CPU_ENFORCE: {v!r} — нужно cgroup|taskset|off")
    return v


def cpu_avail():
    try:
        return sorted(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        return list(range(os.cpu_count() or 1))


def cpu_pick(holders, n, avail):
    """N номеров ядер для taskset: сперва не занятые другими держателями (любой набор), не хватает — наименее занятые."""
    use = {c: 0 for c in avail}
    for h in holders:
        for c in h.get("cpus") or []:
            if c in use:
                use[c] += 1
    return sorted(sorted(avail, key=lambda c: (use[c], c))[:max(1, min(n, len(avail)))])


def cgroup_ok():
    """systemd-run --user --scope работает (пробный true; нет systemd/шины, песочница — нет)."""
    if not shutil.which("systemd-run"):
        return False
    try:
        return subprocess.run(["systemd-run", "--user", "--scope", "--quiet", "-p", "CPUQuota=100%", "true"],
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=15).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def cpu_enforce_cmd(cmd, n, cpus, mode, probe=cgroup_ok):
    """Команда с физическим ограничением веса N: cgroup — systemd-run --scope CPUQuota=N×100 % (пробный запуск
    не удался — откат на taskset); taskset — ядра cpus; off — как есть. → (команда, что применено)."""
    if mode == "cgroup":
        if probe():
            return ["systemd-run", "--user", "--scope", "--quiet", "-p", f"CPUQuota={n * 100}%", "--", *cmd], \
                f"cgroup CPUQuota={n * 100}%"
        print("lock cpu: systemd-run --user --scope недоступен — ограничение через taskset", file=sys.stderr)
        mode = "taskset"
    if mode == "taskset" and cpus and shutil.which("taskset"):
        lst = ",".join(map(str, cpus))
        return ["taskset", "-c", lst, *cmd], f"taskset -c {lst}"
    if mode == "taskset":
        print("lock cpu: нет taskset — без ограничения", file=sys.stderr)
    return list(cmd), "off"


def pid_alive(pid):
    """os.kill(pid, 0); где есть /proc — ещё и не зомби."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return True


class CpuState:
    """with CpuState() as st: st.data = {holders: [...], queue: [...]} — атомарно (flock), мёртвые PID вычищены."""

    def __enter__(self):
        import fcntl
        d = locks_dir()
        self.path = d / CPU_STATE
        self.f = open(d / (CPU_STATE + ".lock"), "a")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        try:
            self.data = json.loads(self.path.read_text())
            if not isinstance(self.data, dict):
                raise ValueError
        except (OSError, ValueError):
            self.data = {}
        self.data.setdefault("holders", [])
        self.data.setdefault("queue", [])
        for k in ("holders", "queue"):
            self.data[k] = [x for x in self.data[k] if pid_alive(int(x.get("pid") or 0))]
        return self

    def __exit__(self, et, ev, tb):
        try:
            if et is None:
                tmp = self.path.with_name(f".{CPU_STATE}.{os.getpid()}")
                tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=1))
                tmp.replace(self.path)
        finally:
            self.f.close()  # закрытие снимает flock
        return False


def cpu_can_start(data, my_id, total, starve, t):
    """Правило старта: голова очереди — если влезает; любой другой (первый подходящий по очереди) — добор,
    если влезает и голова ждёт меньше starve с."""
    free = total - sum(int(h["slots"]) for h in data["holders"])
    q = data["queue"]
    need = lambda w: min(int(w["slots"]), total)  # N > M обрезается до M при каждом решении
    if not q:
        return False
    if q[0]["id"] == my_id:
        return need(q[0]) <= free
    if t - float(q[0]["enqueued"]) >= starve:
        return False
    for w in q[1:]:
        if need(w) <= free:
            return w["id"] == my_id
    return False


def cpu_acquire(holder, slots, cmd, timeout):
    """Встать в очередь и дождаться старта; → (id держателя, ядра для taskset). Таймаут — выход 124; SIGTERM/SIGINT — выход из очереди."""
    import signal
    my_id = f"{os.getpid()}-{time.time_ns()}"
    t0 = time.time()
    rec = {"id": my_id, "holder": holder, "pid": os.getpid(), "slots": slots, "cmd": " ".join(cmd)[:200],
           "cwd": os.getcwd()}

    got = []  # сигнал в ожидании; обработчик только отмечает — замок файла состояния не бросаем посреди записи

    def on_sig(sig, _):
        got.append(sig)

    old = {sg: signal.signal(sg, on_sig) for sg in (signal.SIGTERM, signal.SIGINT)}
    try:
        with CpuState() as st:
            st.data["queue"].append({**rec, "enqueued": t0})
        while True:
            if got:
                cpu_drop(my_id)
                print(f"lock cpu: прервано сигналом {int(got[0])} в ожидании", file=sys.stderr)
                sys.exit(128 + int(got[0]))
            with CpuState() as st:
                t = time.time()
                total, starve = cpu_total(), cpu_starve_s()  # перечитываем: конфиг мог смениться
                if cpu_can_start(st.data, my_id, total, starve, t):
                    st.data["queue"] = [w for w in st.data["queue"] if w["id"] != my_id]
                    cpus = cpu_pick(st.data["holders"], slots, cpu_avail())  # ядра для taskset (если до него дойдёт)
                    st.data["holders"].append({**rec, "slots": min(slots, total), "since": now(), "since_ts": t, "cpus": cpus})
                    return my_id, cpus
            if timeout is not None and time.time() - t0 > timeout:
                cpu_drop(my_id)
                print(f"lock cpu: таймаут {timeout:g} с в ожидании", file=sys.stderr)
                sys.exit(124)
            for _ in range(5):
                if got:
                    break
                time.sleep(0.1)
    finally:
        for sg, h in old.items():
            signal.signal(sg, h)


def cpu_drop(my_id):
    """Убрать запись (держатель или ожидающий)."""
    with CpuState() as st:
        for k in ("holders", "queue"):
            st.data[k] = [x for x in st.data[k] if x["id"] != my_id]


def lock_status():
    import fcntl
    lp = locks_dir() / GPU_LOCK
    f = open(lp, "a")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print("gpu: свободен")
    except OSError:
        try:
            x = json.loads(Path(str(lp) + ".info").read_text())
            print(f"gpu: занят — {x['holder']}, PID {x['pid']}, «{x['cmd']}», с {x['since']}, копия {x['cwd']}")
        except (OSError, ValueError):
            print(f"gpu: занят (держит процесс не через {CLI} lock)")
    finally:
        f.close()
    total = cpu_total()
    with CpuState() as st:
        hs, q = st.data["holders"], st.data["queue"]
    busy = sum(int(h["slots"]) for h in hs)
    print(f"cpu: занято {busy}/{total}" + ("" if hs or q else " (свободен)"))
    for h in hs:
        print(f"  {h['holder']}: {h['slots']} сл., PID {h['pid']}, «{h['cmd']}», с {h['since']}, копия {h['cwd']}")
    t = time.time()
    for i, w in enumerate(q, 1):
        print(f"  очередь {i}: {w['holder']}: {w['slots']} сл., ждёт {int(t - float(w['enqueued']))} с, PID {w['pid']}, «{w['cmd']}»")


def run_held(holder, cmd, tm, release):
    """Запустить команду под уже взятым замком; release() — снять замок. Выход — код команды."""
    import signal
    if tm and re.fullmatch(r"[\w.-]+", holder):
        # команда — в окне tmux, замок держим здесь до её конца; код — из .rc. Имя задачи своё на каждый запуск
        # (<holder>.<случайный суффикс>; PID не годится — в песочницах он мал и повторяется): параллельные lock
        # с одним holder не делят .pid/.rc. Ждём по job_state — он видит и PID из чужого пространства
        # (песочница агента): тогда по окну tmux.
        name = f"{holder}.{os.urandom(3).hex()}"
        try:
            job_start(name, 0, cmd, tm)
            _, _, rcf = job_files(name)
            for sg in (signal.SIGTERM, signal.SIGINT):
                signal.signal(sg, lambda sig, _: job_stop(name))
            while (st := job_state(name)) == "running":
                time.sleep(0.3)
            for _ in range(20):  # окно закрыто (kill-window) — runner дописывает .rc уже после
                if st != "gone":
                    break
                time.sleep(0.1)
                st = job_state(name)
            try:
                rc = int(rcf.read_text().strip()) if st == "done" else 143
            except (OSError, ValueError):
                rc = 1
        finally:
            release()
        sys.exit(rc)
    try:
        child = subprocess.Popen(cmd)
        for sg in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sg, lambda sig, _: child.send_signal(sig))
        rc = child.wait()
    finally:
        release()
    sys.exit(rc)


def cmd_lock(a):
    import fcntl
    args = list(a.args)
    if args[:1] == ["status"]:
        return lock_status()
    usage = (f"{CLI} lock cpu|gpu <имя> [--slots N (cpu)] [--timeout СЕК] [--no-tmux] [--tmux-session S] -- <команда…>"
             f"  |  {CLI} lock status")
    if "--" not in args or len(args) < 4 or args[0] not in ("cpu", "gpu"):
        raise DpError(usage)
    k = args.index("--")
    head, cmd = args[:k], args[k + 1:]
    if not cmd or len(head) < 2:
        raise DpError(usage)
    res, holder = head[0], head[1]
    opts = {"--timeout": None, "--slots": None, "--tmux-session": None}
    flags = set()
    i = 2
    while i < len(head):
        if head[i] in opts and i + 1 < len(head):
            opts[head[i]] = head[i + 1]
            i += 2
        elif head[i] in ("--no-tmux", "--tmux"):
            flags.add(head[i])
            i += 1
        else:
            raise DpError(f"lock: неизвестный аргумент {head[i]}\n{usage}")
    try:
        timeout = float(opts["--timeout"]) if opts["--timeout"] is not None else None
        slots = int(opts["--slots"]) if opts["--slots"] is not None else None
    except ValueError:
        raise DpError(usage)
    tm = tmux_opts(argparse.Namespace(no_tmux="--no-tmux" in flags, tmux_session=opts["--tmux-session"]))
    if res == "cpu":
        total = cpu_total()
        n = slots if slots is not None else cpu_weight(cmd)
        if n < 1:
            raise DpError("lock cpu: --slots ≥ 1")
        if n > total:
            print(f"lock cpu: {n} слотов > всего {total} — беру {total}", file=sys.stderr)
            n = total
        mode = cpu_enforce_mode()
        os.environ["DPCLI_IN_LOCK"] = "1"  # вложенные проверки (accept) не берут слоты второй раз
        my_id, cpus = cpu_acquire(holder, n, cmd, timeout)
        try:
            run_cmd, how = cpu_enforce_cmd(cmd, n, cpus, mode)
        except BaseException:
            cpu_drop(my_id)
            raise
        if how != "off":
            print(f"lock cpu: {n} сл., {how}", file=sys.stderr)
        run_held(holder, run_cmd, tm, lambda: cpu_drop(my_id))
    if slots is not None:
        raise DpError("lock gpu: --slots только для cpu")
    lp = locks_dir() / GPU_LOCK
    deadline = time.time() + timeout if timeout else None
    while True:
        f = open(lp, "a")
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            f.close()
        if deadline and time.time() > deadline:
            print(f"lock {res}: таймаут {opts['--timeout']} с в ожидании", file=sys.stderr)
            sys.exit(124)
        time.sleep(0.2)
    ip = Path(str(lp) + ".info")
    ip.write_text(json.dumps({"holder": holder, "pid": os.getpid(), "cmd": " ".join(cmd)[:200], "since": now(), "cwd": os.getcwd()}))

    def release():
        ip.unlink(missing_ok=True)
        f.close()
    run_held(holder, cmd, tm, release)


def register(sp):
    q = sp.add_parser("job", help="долгий запуск в фоне: start <имя> <таймаут_с> <команда…> | wait <имя> <таймаут_с> | status [имя] | stop <имя>")
    q.add_argument("action", choices=["start", "wait", "status", "stop", "attach", "tmux"]); q.add_argument("name", nargs="?")
    q.add_argument("timeout", nargs="?", type=int); q.add_argument("cmd", nargs=argparse.REMAINDER)
    q.add_argument("--lock", metavar="cpu|gpu", help="start: выполнять под lock cpu|gpu (держатель — имя задачи)")
    q.add_argument("--slots", type=int, metavar="N", help="start с --lock cpu: занять N слотов (по умолчанию — по jobs.cpu_weights, иначе 1)")
    q.add_argument("--all", action="store_true", help="status без имени: все запуски (по умолчанию идущие + последние 10)")
    tmux_args(q)
    q.set_defaults(func=cmd_job)

    q = sp.add_parser("lock", help="команда под общим замком: lock cpu|gpu <имя> [--slots N] [--timeout СЕК] -- <команда…> | lock status")
    q.add_argument("args", nargs=argparse.REMAINDER)
    q.set_defaults(func=cmd_lock)
