#!/usr/bin/env bash
# GDScript-тесты копии против базы: по файлу на процесс Godot headless, параллельно;
# новые падения (file::test) и таймауты, которых нет в базе → exit 1.
# tools/tests_vs_base.sh [--base <ref>] [--filter=<подстрока пути>] [-j N] [--timeout-file S] [--copy <путь>]
# Подробности — tools/tests_vs_base.py. Под замком cpu: .dpcli/dpcli lock cpu <имя> --no-tmux -- tools/tests_vs_base.sh …
set -uo pipefail
exec python3 -I "$(dirname "$0")/tests_vs_base.py" "$@"
