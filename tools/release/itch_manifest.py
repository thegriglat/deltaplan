#!/usr/bin/env python3
"""Манифест itch (.itch.toml) для каталога сборки; вывод — в stdout.

  python3 tools/release/itch_manifest.py --bin deltaplan.exe --platform windows > build/windows/.itch.toml

Действия запуска (https://itch.io/docs/itch/integrating/manifest-actions.html):
- «play» — без аргументов: драйвер рендера берётся из сохранённого выбора игры
  (game.json -> display.rendering_driver, контракт CR-К3), иначе по умолчанию Godot;
- Windows: «Play (DirectX 12)» и «Play (Vulkan)» с --rendering-driver. Аргумент
  движка идёт до «--» и перекрывает сохранённый выбор (разовый запуск).
Других параметров игры, влияющих на видеокарту, нет (--gpu-report/--gpu-profile — замеры
для разработчиков), поэтому их в манифест не кладём. Linux: альтернативы драйверу нет.
"""
import argparse
import json

# платформа -> [(имя действия, аргументы движка)]
ACTIONS = {
    "windows": [
        ("Play (DirectX 12)", ["--rendering-driver", "d3d12"]),
        ("Play (Vulkan)", ["--rendering-driver", "vulkan"]),
    ],
    "linux": [],
}


def manifest(binary: str, platform: str) -> str:
    out = ["# Сгенерировано tools/release/itch_manifest.py (tools/build.sh); не править вручную.", ""]
    rows = [("play", [])] + ACTIONS[platform]
    for name, args in rows:
        out += ["[[actions]]", f"name = {json.dumps(name)}", f"path = {json.dumps(binary)}"]
        if args:
            out.append("args = " + json.dumps(args))
        out.append("")
    return "\n".join(out)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--bin", required=True, help="имя исполняемого файла в каталоге сборки")
    p.add_argument("--platform", required=True, choices=sorted(ACTIONS))
    a = p.parse_args()
    print(manifest(a.bin, a.platform), end="")


if __name__ == "__main__":
    main()
