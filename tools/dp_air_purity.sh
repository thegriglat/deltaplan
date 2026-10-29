#!/usr/bin/env bash
# Аудит чистоты rust/dp-air (RW-16a): ищет игровое в src/ и Cargo.toml.
# Критерии (решение 2026-10-30): нет Godot; нет путей и раскладки игры;
# нет имён конфигов игры; нет понятий игры; compat Godot — отдельно.
# Использование: tools/dp_air_purity.sh [-v] [категория]   (-v — печатать файл:строка)
# Код не правит. Печатает «нарушений: N». Код выхода 0 всегда (число — в тексте).
# Комментарии `//` учитываются: ссылки на GDScript/Godot в доках — тоже нарушения
# (контракт не должен знать про игру), но считаются отдельно (суффикс _doc).
# RW-16b: ключи секций конфигов (`"atmosphere"`, W5 v11) — данные, не имена файлов: категория
# cfgnames ловит только имена файлов с `.json`. `\.gd\b` не срабатывает на поле `g.gd[...]`
# (градиент). Строка с `// purity: allow <причина>` не считается (только нейтральные слова).
set -u
cd "$(dirname "$0")/.." || exit 2
D=rust/dp-air
VERB=0; ONLY=""
for a in "$@"; do case "$a" in -v) VERB=1;; *) ONLY="$a";; esac; done

# категория|регэксп (ERE, grep -E)
CATS=(
 "godot|Godot|GDScript|gdext|godot::|FastNoiseLite|\\.gd\\b([^[]|$)|\\bPacked(Float|Int|Byte|Vector)[0-9]*Array|\\bgd_num"
 "paths|res://|user://|data/locations|BAKED_ROOT|configs/|\\.json\\b|\\.tres\\b|\\.png\\b|\\.import\\b"
 "cfgnames|\\b(atmosphere|weather_model|surface_heat|air_model|world|air_phase)\\.json"
 "game|меню|достижени|achievement|камер|camera|\\bботы?\\b|\\bHUD\\b|\\bUI\\b|игров|в игре|игры|игроку|пилот|\\bpilot|trike|дельтаплан|glider|\\bplayer|запечён|запекан|\\bbaked\\b|\\bBaked|AirRuntime|flight_settings"
 "compat|\\bcompat::|mod compat"
)
total=0
for entry in "${CATS[@]}"; do
  name=${entry%%|*}; re=${entry#*|}
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  # код и доккомментарии раздельно: строка, начинающаяся с // (после пробелов) — _doc
  hits=$(grep -rnE "$re" "$D/src" "$D/Cargo.toml" 2>/dev/null | grep -v 'purity: allow')
  doc=$(printf '%s\n' "$hits" | grep -E '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  code=$(printf '%s\n' "$hits" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v '^$' || true)
  nd=$(printf '%s' "$doc" | grep -c .); nc=$(printf '%s' "$code" | grep -c .)
  echo "$name: код $nc, комментарии $nd"
  total=$((total+nc+nd))
  if [ $VERB = 1 ]; then
    printf '%s\n' "$code" | grep . | sed "s#^$D/#  [$name код] #"
    printf '%s\n' "$doc"  | grep . | sed "s#^$D/#  [$name doc] #"
  fi
done
echo "нарушений: $total"
