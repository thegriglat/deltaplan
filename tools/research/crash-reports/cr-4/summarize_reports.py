"""Сводка «Драйвер / API», «Рендер», стадия, графика и счётчик кодов ошибок D3D12 по отчётам.
Запуск: python3 -I summarize_reports.py <папка с json от gh issue view --json title,body>
Выводит только поля, разрешённые CR-К1 (без координат/мест/логов)."""
import collections, glob, json, re, sys

for f in sorted(glob.glob(sys.argv[1] + "/*.json")):
    b = json.load(open(f))["body"]
    g = lambda k: (re.search(k + r": (.*)", b) or [0, "?"])[1]
    codes = collections.Counter(re.findall(r"error (0x[0-9a-f]+)", b))
    fb = "Vulkan->D3D12 fallback" if "switching to Direct3D 12" in b else ""
    print(f.split("/")[-1], g("Версия"), g("Видеокарта"), g(r"Драйвер / API"), g("Рендер"),
          g("стадия"), g("graphics"), dict(codes), fb)
