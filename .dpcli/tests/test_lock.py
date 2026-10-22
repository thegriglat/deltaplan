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
