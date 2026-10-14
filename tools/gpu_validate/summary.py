"""Сводка прогонов tools/gpu_validate.sh: по прогону — итог, загрузка, пики памяти, порции ветра;
по всем — сообщения слоя валидации Vulkan, ошибки Godot и vkd3d, сгруппированные без адресов.
  python3 -I tools/gpu_validate/summary.py <папка прогона>
"""

import collections
import json
import pathlib
import re
import sys

HEX = re.compile(r"0x[0-9a-fA-F]+")
NUM = re.compile(r"\b\d+\b")


def norm(s: str, n: int = 220) -> str:
    return NUM.sub("N", HEX.sub("0x…", s.strip()))[:n]


def layer_messages(path: pathlib.Path) -> list[tuple[str, str]]:
    """(заголовок «Validation Error: [ VUID ]», первая строка текста) на сообщение слоя."""
    if not path.exists():
        return []
    out = []
    lines = path.read_text(errors="replace").splitlines()
    for i, ln in enumerate(lines):
        if ln.startswith("Validation ") and "[" in ln:
            head = ln.split("|")[0].strip()
            body = lines[i + 1] if i + 1 < len(lines) else ""
            out.append((head, body))
    return out


def godot_errors(text: str) -> list[str]:
    out = []
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith(("ERROR:", "SCRIPT ERROR:", "WARNING:")) or s.startswith("err:"):
            out.append(s)
        elif "handle_crash" in s or "Program crashed" in s or "VK_ERROR" in s or "DEVICE_LOST" in s:
            out.append(s)
    return out


def main() -> int:
    d = pathlib.Path(sys.argv[1])
    runs = sorted(d.glob("*.out"))
    msgs: dict = collections.defaultdict(lambda: collections.Counter())
    errs: dict = collections.defaultdict(lambda: collections.Counter())
    print("прогон | выход | загрузка, с | ветер | RAM (anon) пик, МБ | VRAM пик, МБ | порция ветра макс, мс | слой: ош/пред")
    print("--- | --- | --- | --- | --- | --- | --- | ---")
    bad = 0
    for o in runs:
        tag = o.name[: -len(".out")]
        text = o.read_text(errors="replace")
        code = (re.findall(r"^exit=(\d+)", text, re.M) or ["?"])[-1]
        fly = re.findall(r"^PERF fly_ms=(\d+)", text, re.M)
        crashed = "handle_crash" in text or "Program crashed" in text
        wind = "поле" if re.search(r"air_model: поле .*\(загрузка\)", text) else (
            "ошибка" if "AirGpuJob:" in text or "air_model: ошибка" in text else "аналитика")
        mem = [ln.split() for ln in (d / f"{tag}.mem").read_text().splitlines()] if (d / f"{tag}.mem").exists() else []
        rss = max((int(m[0]) for m in mem if len(m) == 2), default=0)
        vram = max((int(m[1]) for m in mem if len(m) == 2), default=0)
        ch = d / f"{tag}.chunks.jsonl"
        chunk = max((json.loads(ln).get("gpu_ms", 0) for ln in ch.read_text().splitlines() if ln), default=0) if ch.exists() else 0
        lm = layer_messages(d / f"{tag}.vk.log")
        ne = sum(1 for h, _ in lm if h.startswith("Validation Error"))
        for h, b in lm:
            msgs[(h, norm(b))][tag] += 1
        for e in godot_errors(text):
            errs[norm(e, 160)][tag] += 1
        ok = code == "0" and fly and not crashed
        bad += 0 if ok else 1
        status = "сбой" if crashed else (code if ok else f"{code} (нет полёта)")
        print(f"{tag} | {status} | {int(fly[-1]) / 1000:.1f} | {wind} | {rss} | {vram} | {chunk:.1f} | {ne}/{len(lm) - ne}" if fly else
              f"{tag} | {status} | — | {wind} | {rss} | {vram} | {chunk:.1f} | {ne}/{len(lm) - ne}")
    print("\n== слой валидации (сообщение → прогоны, число до предела повторов)")
    for (h, b), c in sorted(msgs.items(), key=lambda kv: (not kv[0][0].startswith("Validation Error"), -sum(kv[1].values()))):
        print(f"{h}\n    {b}\n    {dict(c)}")
    if not msgs:
        print("(нет)")
    print("\n== ошибки Godot / vkd3d / сбои (без адресов, N — число)")
    for e, c in sorted(errs.items(), key=lambda kv: -sum(kv[1].values()))[:60]:
        print(f"{sum(c.values()):5d}  {e}  [{len(c)} прогонов]")
    if not errs:
        print("(нет)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
