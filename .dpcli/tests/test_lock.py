"""Замок cpu: взвешенные слоты, очередь с добором и защитой от голодания, чистка мёртвых PID, таймаут."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "lib"
CLI = Path(__file__).resolve().parents[1] / "dpcli"
sys.path.insert(0, str(LIB))

from dpcli import config  # noqa: E402
from dpcli.commands import jobs  # noqa: E402


class Rule(unittest.TestCase):
    """cpu_can_start — чистая функция правила старта."""

    def st(self, holders, queue):
        return {"holders": [{"slots": n} for n in holders],
                "queue": [{"id": i, "slots": n, "enqueued": e} for i, n, e in queue]}

    def test_head_fits(self):
        d = self.st([2], [("a", 2, 0), ("b", 1, 1)])
        self.assertTrue(jobs.cpu_can_start(d, "a", 4, 300, 10))
        self.assertFalse(jobs.cpu_can_start(d, "a", 3, 300, 10))

    def test_backfill_first_fitting(self):
        d = self.st([2], [("a", 3, 0), ("b", 3, 1), ("c", 1, 2)])
        self.assertFalse(jobs.cpu_can_start(d, "a", 4, 300, 10))
        self.assertFalse(jobs.cpu_can_start(d, "b", 4, 300, 10))  # не влезает
        self.assertTrue(jobs.cpu_can_start(d, "c", 4, 300, 10))
        d = self.st([1], [("a", 4, 0), ("b", 2, 1), ("c", 1, 2)])
        self.assertTrue(jobs.cpu_can_start(d, "b", 4, 300, 10))
        self.assertFalse(jobs.cpu_can_start(d, "c", 4, 300, 10))  # первым — b

    def test_no_backfill_when_head_starves(self):
        d = self.st([2], [("a", 3, 0), ("c", 1, 2)])
        self.assertTrue(jobs.cpu_can_start(d, "c", 4, 300, 299))
        self.assertFalse(jobs.cpu_can_start(d, "c", 4, 300, 300))


class CliBase(unittest.TestCase):
    """Через dpcli lock: временный каталог с dpcli.json вне git."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name).resolve()
        self.locks = self.d / "locks"
        self.conf({})
        self.procs = []
        self.addCleanup(self.kill_all)

    def conf(self, jobs_extra):
        cfg = {"project": "t", "jobs": {"dir": str(self.d / "jobs"), "cpu_slots": 4, **jobs_extra}, "locks": str(self.locks)}
        (self.d / "dpcli.json").write_text(json.dumps(cfg))

    def env(self, **kw):
        e = {k: v for k, v in os.environ.items() if not k.startswith("DPCLI_")}
        e.update({"DPCLI_NO_TMUX": "1", "DPCLI_NO_REEXEC": "1", **kw})
        return e

    def start(self, *args, **env):
        p = subprocess.Popen([sys.executable, str(CLI), "lock", *args], cwd=self.d, env=self.env(**env),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.procs.append(p)
        return p

    def run_(self, *args, **env):
        r = subprocess.run([sys.executable, str(CLI), "lock", *args], cwd=self.d, env=self.env(**env),
                           capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout, r.stderr

    def kill_all(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.communicate()

    def state(self):
        try:
            return json.loads((self.locks / "cpu.json").read_text())
        except OSError:
            return {"holders": [], "queue": []}

    def wait_for(self, cond, limit=5.0):
        t = time.time() + limit
        while time.time() < t:
            s = self.state()
            if cond(s):
                return s
            time.sleep(0.05)
        self.fail(f"не дождались: {self.state()}")

    def held(self, s):
        return {h["holder"]: h["slots"] for h in s["holders"]}

class Cli(CliBase):
    def test_slots_accounting_and_status(self):
        a = self.start("cpu", "a", "--slots", "3", "--", "sleep", "1.5")
        self.wait_for(lambda s: self.held(s) == {"a": 3})
        b = self.start("cpu", "b", "--slots", "2", "--", "sleep", "0.3")
        s = self.wait_for(lambda s: [w["holder"] for w in s["queue"]] == ["b"])
        self.assertEqual(self.held(s), {"a": 3})  # 3 + 2 > 4 — b ждёт
        code, out, _ = self.run_("status")
        self.assertIn("cpu: занято 3/4", out)
        self.assertIn("a: 3 сл.", out)
        self.assertIn("очередь 1: b: 2 сл.", out)
        self.assertEqual(a.wait(10), 0)
        self.assertEqual(b.wait(10), 0)
        s = self.state()
        self.assertEqual((s["holders"], s["queue"]), ([], []))

    def test_backfill_small_job(self):
        self.start("cpu", "a", "--slots", "3", "--", "sleep", "2")
        self.wait_for(lambda s: "a" in self.held(s))
        big = self.start("cpu", "big", "--slots", "2", "--", "sleep", "0.2")
        self.wait_for(lambda s: s["queue"])
        small = self.start("cpu", "small", "--", "sleep", "0.3")
        s = self.wait_for(lambda s: "small" in self.held(s))
        self.assertEqual([w["holder"] for w in s["queue"]], ["big"])
        self.assertEqual(small.wait(10), 0)
        self.assertEqual(big.wait(10), 0)

    def test_no_backfill_after_starve(self):
        self.conf({"cpu_starve_s": 0.5})
        self.start("cpu", "a", "--slots", "3", "--", "sleep", "2.5")
        self.wait_for(lambda s: "a" in self.held(s))
        self.start("cpu", "big", "--slots", "2", "--", "sleep", "0.2")
        self.wait_for(lambda s: s["queue"])
        time.sleep(0.7)  # голова ждёт дольше cpu_starve_s
        small = self.start("cpu", "small", "--", "sleep", "0.2")
        time.sleep(1.2)
        s = self.state()
        self.assertNotIn("small", self.held(s))
        self.assertEqual([w["holder"] for w in s["queue"]], ["big", "small"])
        self.assertEqual(small.wait(15), 0)

    def test_dead_pid_cleaned(self):
        dead = subprocess.Popen(["true"])
        dead.wait()
        self.locks.mkdir(parents=True, exist_ok=True)
        (self.locks / "cpu.json").write_text(json.dumps({
            "holders": [{"id": "x", "holder": "ghost", "pid": dead.pid, "slots": 4, "cmd": "x", "cwd": "/", "since": "?"}],
            "queue": [{"id": "y", "holder": "ghost2", "pid": dead.pid, "slots": 4, "cmd": "y", "cwd": "/", "enqueued": 0}]}))
        code, _, err = self.run_("cpu", "a", "--timeout", "5", "--", "true")
        self.assertEqual(code, 0, err)
        s = self.state()
        self.assertEqual((s["holders"], s["queue"]), ([], []))

    def test_timeout_124_and_removed(self):
        self.start("cpu", "a", "--slots", "4", "--", "sleep", "3")
        self.wait_for(lambda s: "a" in self.held(s))
        code, _, err = self.run_("cpu", "b", "--timeout", "0.6", "--", "true")
        self.assertEqual(code, 124)
        self.assertIn("таймаут", err)
        self.assertEqual(self.state()["queue"], [])

    def test_sigterm_while_waiting_leaves_queue(self):
        self.start("cpu", "a", "--slots", "4", "--", "sleep", "3")
        self.wait_for(lambda s: "a" in self.held(s))
        b = self.start("cpu", "b", "--", "true")
        self.wait_for(lambda s: s["queue"])
        b.terminate()
        self.assertEqual(b.wait(5), 143)
        self.assertEqual(self.state()["queue"], [])

    def test_exit_code_passthrough(self):
        code, _, _ = self.run_("cpu", "a", "--", "sh", "-c", "exit 7")
        self.assertEqual(code, 7)

    def test_weights_and_slots_override(self):
        self.conf({"cpu_weights": [{"match": r"sleep 1\.2", "slots": 3}, {"match": "sleep", "slots": 2}]})
        self.start("cpu", "a", "--", "sleep", "1.2")  # первое совпадение — 3
        self.wait_for(lambda s: self.held(s) == {"a": 3})
        self.start("cpu", "c", "--slots", "1", "--", "sleep", "1.2")  # --slots сильнее весов
        self.wait_for(lambda s: self.held(s) == {"a": 3, "c": 1})
        code, _, err = self.run_("cpu", "e", "--slots", "9", "--timeout", "0.2", "--", "true")
        self.assertIn("беру 4", err)  # N > M обрезается до M
        self.assertEqual(code, 124)

    def test_weight_function(self):
        os.environ.pop("DPCLI_CPU_SLOTS", None)
        config.reset()
        self.addCleanup(config.reset)
        config._CFG = config.merge(config.DEFAULTS, {"jobs": {"cpu_slots": 8, "cpu_weights": [
            {"match": "godot.*--import", "slots": 2}, {"match": "godot", "slots": 3}]}})
        self.assertEqual(jobs.cpu_weight(["godot", "--headless", "--import"]), 2)
        self.assertEqual(jobs.cpu_weight(["godot", "-s", "run_tests.gd"]), 3)
        self.assertEqual(jobs.cpu_weight(["python3", "x.py"]), 1)
        self.assertEqual(jobs.cpu_total(), 8)

    def test_config_from_main_worktree(self):
        """Две копии с разным dpcli.json -> одна ёмкость и веса: из главной."""
        os.environ.pop("DPCLI_CPU_SLOTS", None)
        main = self.d / "main"
        main.mkdir()
        g = lambda *a, cwd=main: subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True)
        g("init", "-q", "-b", "main")
        g("config", "user.email", "t@t")
        g("config", "user.name", "t")
        (main / "dpcli.json").write_text(json.dumps({"project": "t", "jobs": {"cpu_slots": 6, "cpu_weights": [{"match": "heavy", "slots": 4}]}}))
        g("add", "."); g("commit", "-qm", "x")
        wt = self.d / "wt"
        g("worktree", "add", "-q", str(wt), "-b", "side")
        (wt / "dpcli.json").write_text(json.dumps({"project": "t", "jobs": {"cpu_slots": 3}}))
        self.addCleanup(config.reset)
        old = os.getcwd()
        self.addCleanup(os.chdir, old)
        for d in (main, wt):
            os.chdir(d)
            config.reset()
            self.assertEqual(jobs.cpu_total(), 6)
            self.assertEqual(jobs.cpu_weight(["heavy"]), 4)

    def test_clamp_oversized_in_decision(self):
        data = {"holders": [{"slots": 1}], "queue": [{"id": "a", "slots": 10, "enqueued": 0}]}
        self.assertFalse(jobs.cpu_can_start(data, "a", 4, 300, 1))
        data["holders"] = []
        self.assertTrue(jobs.cpu_can_start(data, "a", 4, 300, 1))

    def test_accept_tests_check_goes_through_queue(self):
        from dpcli.commands import accept
        self.conf({"cpu_weights": [{"match": "marker", "slots": 2}]})
        cfg = json.loads((self.d / "dpcli.json").read_text())
        cfg["checks"] = {"tests": "sleep 1.5 # marker {filter}"}
        (self.d / "dpcli.json").write_text(json.dumps(cfg))
        old = (os.getcwd(), dict(os.environ))
        def restore():
            os.chdir(old[0]); os.environ.clear(); os.environ.update(old[1]); config.reset()
        self.addCleanup(restore)
        os.chdir(self.d)
        os.environ.pop("DPCLI_IN_LOCK", None)
        os.environ.update({"DPCLI_NO_REEXEC": "1", "DPCLI_CPU_ENFORCE": "off", "DPCLI_NO_TMUX": "1"})
        config.reset()
        (self.d / "logs").mkdir()
        import threading
        res = []
        th = threading.Thread(target=lambda: res.append(accept.run_check({"tests": "x"}, self.d, self.d / "logs", 1, "T-1")))
        th.start()
        s = self.wait_for(lambda s: s["holders"])
        self.assertEqual(self.held(s), {"T-1": 2})
        th.join()
        self.assertTrue(res[0][1], res[0])
        # внутри lock: слотов второй раз не берём
        cfg["checks"] = {"tests": "sleep 1 # {filter}"}
        (self.d / "dpcli.json").write_text(json.dumps(cfg))
        config.reset()
        os.environ["DPCLI_IN_LOCK"] = "1"
        th = threading.Thread(target=lambda: res.append(accept.run_check({"tests": "x"}, self.d, self.d / "logs", 2, "T-2")))
        th.start()
        time.sleep(0.5)
        self.assertEqual(self.state()["holders"], [])
        th.join()
        self.assertTrue(res[1][1], res[1])


class Enforce(unittest.TestCase):
    """Физическое ограничение веса: команда systemd-run/taskset, выбор ядер, режим из env/конфига."""

    def test_cpu_pick(self):
        self.assertEqual(jobs.cpu_pick([], 3, [0, 1, 2, 3]), [0, 1, 2])
        self.assertEqual(jobs.cpu_pick([{"cpus": [0, 2]}], 2, [0, 1, 2, 3]), [1, 3])  # любой набор, не подряд
        self.assertEqual(jobs.cpu_pick([{"cpus": [0, 1, 2]}], 2, [0, 1, 2, 3]), [0, 3])  # не хватает — наименее занятые
        self.assertEqual(jobs.cpu_pick([], 9, [4, 5]), [4, 5])

    def test_cmd(self):
        c = ["godot", "--import"]
        self.assertEqual(jobs.cpu_enforce_cmd(c, 3, [1, 4, 5], "cgroup", probe=lambda: True),
                         (["systemd-run", "--user", "--scope", "--quiet", "-p", "CPUQuota=300%", "--", *c],
                          "cgroup CPUQuota=300%"))
        if shutil.which("taskset"):
            self.assertEqual(jobs.cpu_enforce_cmd(c, 3, [1, 4, 5], "cgroup", probe=lambda: False),
                             (["taskset", "-c", "1,4,5", *c], "taskset -c 1,4,5"))
            self.assertEqual(jobs.cpu_enforce_cmd(c, 1, [7], "taskset", probe=lambda: self.fail("probe"))[0],
                             ["taskset", "-c", "7", *c])
        self.assertEqual(jobs.cpu_enforce_cmd(c, 3, [1], "off", probe=lambda: self.fail("probe")), (c, "off"))

    def test_mode(self):
        config.reset()
        self.addCleanup(config.reset)
        self.addCleanup(os.environ.pop, "DPCLI_CPU_ENFORCE", None)
        os.environ.pop("DPCLI_CPU_ENFORCE", None)
        self.assertEqual(jobs.cpu_enforce_mode(), "cgroup")
        config._CFG = config.merge(config.DEFAULTS, {"jobs": {"cpu_enforce": "off"}})
        config._PATH = None  # конфиг подменён — главная копия не читается
        self.assertEqual(jobs.cpu_enforce_mode(), "off")
        os.environ["DPCLI_CPU_ENFORCE"] = "taskset"
        self.assertEqual(jobs.cpu_enforce_mode(), "taskset")
        os.environ["DPCLI_CPU_ENFORCE"] = "bad"
        with self.assertRaises(Exception):
            jobs.cpu_enforce_mode()


class EnforceCli(CliBase):
    """Через dpcli lock с подменным systemd-run в PATH: пишет свои аргументы и запускает команду после --."""

    FAKE = """#!/bin/sh
echo "$*" >>"$FAKE_LOG"
[ -n "$FAKE_FAIL" ] && exit 1
while [ "$1" != "--" ]; do [ "$1" = true ] && exit 0; shift; done
shift; exec "$@"
"""

    def setUp(self):
        super().setUp()
        b = self.d / "bin"
        b.mkdir()
        (b / "systemd-run").write_text(self.FAKE)
        (b / "systemd-run").chmod(0o755)
        self.log = self.d / "fake.log"

    def env(self, **kw):
        e = super().env(**kw)
        e["PATH"] = f"{self.d / 'bin'}:{e['PATH']}"
        e["FAKE_LOG"] = str(self.log)
        return e

    def test_cgroup(self):
        code, _, err = self.run_("cpu", "a", "--slots", "3", "--", "sh", "-c", "exit 7")
        self.assertEqual(code, 7, err)
        self.assertIn("CPUQuota=300%", err)
        lines = self.log.read_text().splitlines()
        self.assertEqual(lines[-1], "--user --scope --quiet -p CPUQuota=300% -- sh -c exit 7")

    @unittest.skipUnless(shutil.which("taskset"), "нет taskset")
    def test_fallback_taskset(self):
        code, out, err = self.run_("cpu", "a", "--slots", "2", "--", "sh", "-c", "grep Cpus_allowed_list /proc/self/status",
                                   FAKE_FAIL="1")
        self.assertEqual(code, 0, err)
        self.assertIn("taskset", err)
        allowed = out.split()[-1]
        n = sum(len(range(int(x.split("-")[0]), int(x.split("-")[-1]) + 1)) for x in allowed.split(","))
        self.assertEqual(n, min(2, len(jobs.cpu_avail())))

    def test_off(self):
        code, _, err = self.run_("cpu", "a", "--", "true", DPCLI_CPU_ENFORCE="off")
        self.assertEqual(code, 0, err)
        self.assertFalse(self.log.exists())
        self.assertNotIn("lock cpu:", err)

    def test_sigterm_reaches_command(self):
        p = self.start("cpu", "a", "--", "sh", "-c", "trap 'exit 42' TERM; while :; do sleep 0.1; done")
        self.wait_for(lambda s: self.held(s) == {"a": 1})
        time.sleep(0.5)
        p.terminate()
        self.assertEqual(p.wait(10), 42)
        self.assertEqual(self.state()["holders"], [])


class JobState(unittest.TestCase):
    """job_state: чужое пространство PID — по окну tmux; job_start стирает следы прошлого запуска с тем же именем."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        os.environ["DPCLI_JOB_DIR"] = self.tmp.name
        self.addCleanup(os.environ.pop, "DPCLI_JOB_DIR", None)
        self.d = Path(self.tmp.name)

    def test_foreign_ns(self):
        (self.d / "x.pid").write_text("1")  # PID 1 жив, но он из «чужого» пространства — верить нельзя
        (self.d / "x.ns").write_text("pid:[0]")
        self.assertEqual(jobs.job_state("x"), "unknown")
        (self.d / "x.win").write_text("@999999")
        if shutil.which("tmux"):
            self.assertEqual(jobs.job_state("x"), "gone")
        (self.d / "x.rc").write_text("0")
        self.assertEqual(jobs.job_state("x"), "done")

    def test_start_clears_stale(self):
        for ext, v in (("pid", "1"), ("rc", "0"), ("ns", "pid:[0]"), ("win", "@1")):
            (self.d / f"y.{ext}").write_text(v)
        jobs.job_start("y", 10, ["sleep", "0.5"])
        self.assertEqual(jobs.job_state("y"), "running")
        self.assertFalse((self.d / "y.win").exists())
        t = time.time() + 5
        while jobs.job_state("y") == "running" and time.time() < t:
            time.sleep(0.05)
        self.assertEqual(jobs.job_state("y"), "done")
        self.assertEqual((self.d / "y.rc").read_text().strip(), "0")


@unittest.skipUnless(shutil.which("tmux") and shutil.which("script"), "нет tmux/script")
class TmuxLock(CliBase):
    """lock с окном tmux (свой сервер tmux в TMUX_TMPDIR): держит замок до конца команды и отдаёт её код —
    и из песочницы со своим пространством PID (bwrap), где PID окна не виден."""

    def env(self, **kw):
        e = super().env(**kw)
        e.pop("DPCLI_NO_TMUX")
        e.pop("TMUX", None)
        e.update({"TMUX_TMPDIR": str(self.d), "DPCLI_TMUX_SESSION": "t"})
        return e

    def setUp(self):
        super().setUp()
        self.addCleanup(subprocess.run, ["tmux", "kill-server"], env=self.env(), capture_output=True)
        # сервер tmux — вне песочницы, как у агента (иначе он умер бы вместе с её пространством PID)
        subprocess.run(["tmux", "new-session", "-d", "-s", "t"], env=self.env(), cwd=self.d, check=True,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def check_held(self, wrap):
        t = time.time()
        p = subprocess.Popen([*wrap, sys.executable, str(CLI), "lock", "cpu", "a", "--", "sh", "-c", "sleep 1.5; exit 5"],
                             cwd=self.d, env=self.env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.procs.append(p)
        self.wait_for(lambda s: self.held(s) == {"a": 1})
        time.sleep(0.8)
        self.assertIsNone(p.poll(), "lock вернулся раньше команды")
        self.assertEqual(self.held(self.state()), {"a": 1})
        self.assertEqual(p.wait(15), 5, p.stderr.read() if p.stderr else "")
        self.assertGreater(time.time() - t, 1.4)
        self.assertIn("окно tmux", p.stdout.read())
        self.assertEqual(self.state()["holders"], [])

    def test_held_until_end(self):
        self.check_held([])

    @unittest.skipUnless(shutil.which("bwrap") and subprocess.run(
        ["bwrap", "--dev-bind", "/", "/", "--unshare-pid", "--proc", "/proc", "true"], capture_output=True).returncode == 0,
        "нет bwrap с --unshare-pid")
    def test_held_until_end_sandbox(self):
        self.check_held(["bwrap", "--dev-bind", "/", "/", "--unshare-pid", "--proc", "/proc"])

    def test_same_holder_parallel(self):
        a = self.start("cpu", "h", "--", "sh", "-c", "sleep 1; exit 3")
        time.sleep(0.3)
        b = self.start("cpu", "h", "--", "sh", "-c", "sleep 2; exit 4")
        self.assertEqual(a.wait(15), 3)
        self.assertEqual(b.wait(15), 4)


if __name__ == "__main__":
    unittest.main()
