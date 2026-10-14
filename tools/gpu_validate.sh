#!/usr/bin/env bash
# Проверка GPU на загрузке места до полёта: слой валидации Vulkan, пики RAM/VRAM, сбои.
# Матрица прогонов (места × пресеты × боты × ветер), каждый — меню → «Лететь» → <secs> с полёта
# (LaunchOptions --perf) с автопилотом; итог — tools/gpu_validate/summary.py (ошибки по шейдеру/VUID).
#   tools/gpu_validate.sh [--mode=vk|lvp|wine] [--check=core|gpuav|sync|none]
#     [--places=askarovo,altai|<lat>,<lon>;…] [--presets=low,medium,high] [--bots=4,8]
#     [--wind=auto,off] [--secs=8] [--res=1280x720] [--exe=build/windows/deltaplan.exe] [--out=папка]
#     [--driver=d3d12|vulkan]  (только wine: драйвер рендера Windows-сборки)
#     [--cold]  холодный старт: каждый прогон — пустой профиль (кроме настроек), пустые кэши шейдеров
#               Godot/драйвера/vkd3d; место собирается заново (первая загрузка после обновления)
#   tools/gpu_validate.sh --tests=<фильтр> [--mode=vk|lvp] [--check=…] — вместо загрузки GPU-тесты
#     (tools/gpu_tests.sh --filter) под слоем: ядра ветра без шейдеров сцены (GPU-AV на NVIDIA падает
#     в компиляторе на шейдерах сцены, на ядрах — работает)
# Режимы: vk — Vulkan на своей карте; lvp — lavapipe (программный Vulkan, медленно: --res=320x240);
# wine — Windows-сборка (--exe) под wine с vkd3d-proton (d3d12) + DXVK dxgi; релизы качаются
# в ~/.cache/dp-wine (не в репозиторий), префикс там же. --check в wine: core|gpuav|sync — слой
# валидации хоста под vkd3d-proton (ловит выходы за буфер в переведённых шейдерах), none — без.
# Профиль Godot — постоянный профиль копии (~/.cache/dp-xdg/<копия>; кэш мест), пресет и режим
# ветра пишутся туда (tools/gpu_validate/setup.tscn). Нужен дисплей (DISPLAY=:0).
set -uo pipefail
cd "$(dirname "$0")/.."
root=$PWD

mode=vk check=core places=askarovo presets=low bots=4 winds=auto secs=8 res=1280x720
exe=build/windows/deltaplan.exe out="" drv=d3d12 tests="" cold=0
for a in "$@"; do
	case "$a" in
		--mode=*) mode=${a#*=} ;; --check=*) check=${a#*=} ;; --places=*) places=${a#*=} ;;
		--presets=*) presets=${a#*=} ;; --bots=*) bots=${a#*=} ;; --wind=*) winds=${a#*=} ;;
		--secs=*) secs=${a#*=} ;; --res=*) res=${a#*=} ;; --exe=*) exe=${a#*=} ;; --out=*) out=${a#*=} ;; --driver=*) drv=${a#*=} ;; --tests=*) tests=${a#*=} ;; --cold) cold=1 ;;
		*) sed -n '2,19p' "$0" >&2; exit 2 ;;
	esac
done
out=${out:-build/gpu_validate/$(date +%m%d-%H%M%S)-$mode-$check}
mkdir -p "$out"
out=$(realpath "$out")
exe=$(realpath "$exe" 2>/dev/null || echo "$exe")
export DISPLAY="${DISPLAY:-:0}"
export XDG_DATA_HOME="$HOME/.cache/dp-xdg/$(basename "$root")"
pg_backup=$(mktemp)
cp project.godot "$pg_backup"
trap 'cmp -s project.godot "$pg_backup" || cp "$pg_backup" project.godot; rm -f "$pg_backup"' EXIT

# --- слой валидации: файл настроек (vk_layer_settings.txt) на прогон
layer_settings() {  # $1 — файл журнала слоя
	[[ $check == none ]] && return
	cat <<EOF
khronos_validation.report_flags = error,warn
khronos_validation.debug_action = VK_DBG_LAYER_ACTION_LOG_MSG
khronos_validation.log_filename = $1
khronos_validation.duplicate_message_limit = 3
EOF
	case "$check" in
		gpuav) cat <<EOF
khronos_validation.gpuav_enable = true
khronos_validation.gpuav_shader_instrumentation = true
khronos_validation.gpuav_descriptor_checks = true
khronos_validation.gpuav_buffer_address_oob = false
khronos_validation.gpuav_validate_ray_query = false
khronos_validation.disables = VK_VALIDATION_FEATURE_DISABLE_CORE_CHECKS_EXT
EOF
			;;
		sync) cat <<EOF
khronos_validation.validate_sync = true
khronos_validation.syncval_shader_accesses_heuristic = true
khronos_validation.disables = VK_VALIDATION_FEATURE_DISABLE_CORE_CHECKS_EXT
EOF
			;;
	esac
}

# --- wine: vkd3d-proton + DXVK в ~/.cache/dp-wine
wine_setup() {
	local c=$HOME/.cache/dp-wine v=3.0.1 d=2.6.1
	export WINEPREFIX=$c/prefix WINEDEBUG=-all WINEDLLOVERRIDES="d3d12,d3d12core,dxgi=n,b"
	if [[ ! -f $WINEPREFIX/.dp-ready-$v-$d ]]; then
		mkdir -p "$c/dl" "$c/x"
		[[ -f $c/dl/vkd3d-$v.tar.zst ]] || curl -sSLo "$c/dl/vkd3d-$v.tar.zst" \
			"https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v$v/vkd3d-proton-$v.tar.zst"
		[[ -f $c/dl/dxvk-$d.tar.gz ]] || curl -sSLo "$c/dl/dxvk-$d.tar.gz" \
			"https://github.com/doitsujin/dxvk/releases/download/v$d/dxvk-$d.tar.gz"
		tar -C "$c/x" --zstd -xf "$c/dl/vkd3d-$v.tar.zst" && tar -C "$c/x" -xzf "$c/dl/dxvk-$d.tar.gz" || exit 1
		wineboot -i >/dev/null 2>&1
		cp "$c/x/vkd3d-proton-$v"/x64/*.dll "$c/x/dxvk-$d/x64/dxgi.dll" "$WINEPREFIX/drive_c/windows/system32/"
		touch "$WINEPREFIX/.dp-ready-$v-$d"
	fi
	wine_user="$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/Deltaplan"
	export VKD3D_DEBUG=warn VKD3D_SHADER_DEBUG=warn
}

# --- RAM (анонимная память cgroup прогона: вся игра, и под wine тоже) и VRAM (рост занятой
# памяти карты, nvidia-smi) раз в 0,5 с, пока жив pid
sample() {  # $1 — pid, $2 — файл, $3 — имя scope; пишет «ram_mb vram_mb» строками
	local base vram cg="" anon
	base=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
	while kill -0 "$1" 2>/dev/null; do
		[[ -z $cg ]] && cg=$(systemctl --user show -p ControlGroup --value "$3.scope" 2>/dev/null)
		anon=$(awk '$1 == "anon" {print int($2 / 1048576)}' "/sys/fs/cgroup$cg/memory.stat" 2>/dev/null)
		vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
		echo "${anon:-0} $(( ${vram:-0} - ${base:-0} ))" >>"$2"
		sleep 0.5
	done
}

if [[ -n $tests ]]; then
	log=$out/tests
	layer_settings "$log.vk.log" >"$log.vk.txt"
	envs=(XDG_DATA_HOME="$XDG_DATA_HOME")
	[[ $check != none ]] && envs+=(VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation VK_LAYER_SETTINGS_PATH="$log.vk.txt")
	[[ $mode == lvp ]] && envs+=(VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json)
	env "${envs[@]}" systemd-run --user --scope -q -p MemoryMax=8G tools/gpu_tests.sh "--filter=$tests" >"$log.out" 2>&1
	echo "exit=$?" >>"$log.out"
	grep -E "тестов|FAIL" "$log.out" | tail -5
	python3 -I tools/gpu_validate/summary.py "$out" | tee "$out/summary.txt"
	exit
fi
godot --headless --path . --import >/dev/null 2>&1 || true
[[ $mode == wine ]] && wine_setup
IFS=';' read -ra place_list <<<"${places//,/;}"
# «lat,lon» разрезаны запятой — склеить обратно пары чисел
pl=() i=0
while ((i < ${#place_list[@]})); do
	p=${place_list[$i]}
	if [[ $p =~ ^-?[0-9.]+$ ]]; then p="$p,${place_list[$((i + 1))]}"; i=$((i + 1)); fi
	pl+=("$p"); i=$((i + 1))
done

for wind in ${winds//,/ }; do
for preset in ${presets//,/ }; do
	godot --headless --path . res://tools/gpu_validate/setup.tscn -- "--preset=$preset" "--wind=$wind" \
		2>&1 | grep -E "gpu_validate setup" || { echo "setup: ошибка"; exit 1; }
	for place in "${pl[@]}"; do
	for nb in ${bots//,/ }; do
		tag="${place//[,.]/_}-$preset-b$nb-w$wind"
		log=$out/$tag
		layer_settings "$log.vk.log" >"$log.vk.txt"
		where=("--location=$place")
		[[ $place == *,* ]] && where=("--latlon=$place")
		args=(-- "${where[@]}" --autopilot "--bots=$nb" "--perf=$secs")
		chunks=$log.chunks.jsonl
		[[ $mode == wine ]] && chunks=$(winepath -w "$chunks" 2>/dev/null)
		envs=(DP_AIR_CHUNK_LOG="$chunks")
		unit=dpgv-$$-$RANDOM
		[[ $check != none ]] && envs+=(VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation VK_LAYER_SETTINGS_PATH="$log.vk.txt")
		[[ $mode == lvp ]] && envs+=(VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json)
		rm -f "$log.mem" "$log.vk.log" "$log.chunks.jsonl"
		# профиль прогона: настройки из профиля копии; --cold — всё остальное пустое
		prof=$XDG_DATA_HOME
		if [[ $cold == 1 ]]; then
			prof=$(mktemp -d) && mkdir -p "$prof/Deltaplan" "$prof/drv"
			cp -r "$XDG_DATA_HOME/Deltaplan/configs" "$XDG_DATA_HOME/Deltaplan/local" "$prof/Deltaplan/"
			envs+=(__GL_SHADER_DISK_CACHE_PATH="$prof/drv" MESA_SHADER_CACHE_DIR="$prof/drv"
				VKD3D_SHADER_CACHE_PATH="$prof/drv" DXVK_STATE_CACHE_PATH="$prof/drv")
		fi
		envs+=(XDG_DATA_HOME="$prof")
		if [[ $mode == wine ]]; then
			[[ $cold == 1 ]] && rm -rf "$wine_user"
			mkdir -p "$wine_user"
			rm -rf "$wine_user/configs" "$wine_user/local"
			cp -r "$XDG_DATA_HOME/Deltaplan/configs" "$XDG_DATA_HOME/Deltaplan/local" "$wine_user/"
		fi
		echo "== $tag"
		if [[ $mode == wine ]]; then
			env "${envs[@]}" timeout 1800 systemd-run --user --scope -q --unit="$unit" -p MemoryMax=8G \
				wine "$exe" --audio-driver Dummy --rendering-driver "$drv" --resolution "$res" "${args[@]}" \
				>"$log.out" 2>&1 &
		else
			env "${envs[@]}" timeout 1800 systemd-run --user --scope -q --unit="$unit" -p MemoryMax=8G \
				godot --path . --audio-driver Dummy --resolution "$res" --disable-vsync "${args[@]}" \
				>"$log.out" 2>&1 &
		fi
		pid=$!
		sample "$pid" "$log.mem" "$unit" &
		wait "$pid"
		echo "exit=$?" >>"$log.out"
		wait
		[[ $cold == 1 ]] && rm -rf "$prof"
	done
	done
done
done
python3 -I tools/gpu_validate/summary.py "$out" | tee "$out/summary.txt"
