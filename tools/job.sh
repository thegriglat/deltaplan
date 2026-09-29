#!/usr/bin/env bash
# Долгий запуск без опроса по имени процесса (pgrep -f находит сам цикл ожидания).
#   tools/job.sh start <имя> <таймаут_с> <команда…>  — запустить в фоне; печатает PID
#   tools/job.sh wait  <имя> [таймаут_с]             — ждать конца по PID; печатает код и хвост лога
#   tools/job.sh status <имя>                        — идёт / код выхода
# Файлы: ${JOB_DIR:-$HOME/.cache/deltaplan-jobs}/<имя>.{pid,log,rc}; rc пишется в конце всегда
# (124 — вышел таймаут). Одно имя — один запуск: start перезаписывает старые файлы.
set -u
dir="${JOB_DIR:-$HOME/.cache/deltaplan-jobs}"
mkdir -p "$dir"
cmd="${1:-}"; name="${2:-}"
[ -n "$cmd" ] && [ -n "$name" ] || { sed -n '2,7p' "$0"; exit 2; }
pidf="$dir/$name.pid"; log="$dir/$name.log"; rcf="$dir/$name.rc"

case "$cmd" in
start)
	limit="${3:?таймаут, с}"; shift 3
	rm -f "$rcf"
	# setsid — своя группа процессов: при таймауте гасится всё дерево (godot, python)
	setsid bash -c 'timeout -k 30 "$1" "${@:3}" >"$2.log" 2>&1; echo $? >"$2.rc"' \
		_ "$limit" "$dir/$name" "$@" </dev/null >/dev/null 2>&1 &
	echo $! >"$pidf"
	echo "$name: PID $!, лог $log"
	;;
wait)
	limit="${3:-86400}"
	pid="$(cat "$pidf" 2>/dev/null)" || { echo "$name: не запускался"; exit 2; }
	# tail --pid ждёт конца конкретного PID, без опроса по имени
	timeout "$limit" tail --pid="$pid" -f /dev/null
	if [ -f "$rcf" ]; then
		echo "$name: код $(cat "$rcf")"
		tail -n 20 "$log"
		exit "$(cat "$rcf")"
	fi
	echo "$name: ещё идёт (PID $pid) — ожидание прервано по таймауту $limit с"
	exit 3
	;;
status)
	if [ -f "$rcf" ]; then echo "$name: код $(cat "$rcf")"
	elif kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then echo "$name: идёт"
	else echo "$name: нет данных"; fi
	;;
*) sed -n '2,7p' "$0"; exit 2 ;;
esac
