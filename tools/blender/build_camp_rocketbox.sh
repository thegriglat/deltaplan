#!/usr/bin/env bash
# Люди лагеря из Microsoft Rocketbox (MIT, Copyright (c) 2020 Microsoft): исходники → glb + текстуры 512 →
# анимации (ретаргет с camp_pilot.glb). Запуск из корня копии:
#   tools/blender/build_camp_rocketbox.sh [каталог исходников]   (по умолчанию ~/.cache/deltaplan/rocketbox)
#
# Исходники (FBX + TGA, ~90 МБ на человека) в git не кладём. Репозиторий https://github.com/microsoft/Microsoft-Rocketbox
# (ветка master, ~4 ГБ целиком); скрипт берёт только 4 аватара — git sparse-checkout без истории:
#   Assets/Avatars/Adults/<имя>/Export/<имя>.fbx и Assets/Avatars/Adults/<имя>/Textures/*.tga
# Лицензия — LICENSE.md репозитория (MIT), копия — assets/models/world/rocketbox/LICENSE-rocketbox.md.
#
# Шаги: 1) sparse-checkout; 2) Blender: build_camp_rocketbox.py (LOD 0/5000/2500, 20 костей, текстуры 512);
# 3) .import текстур: VRAM-сжатие (BC1/BC3, normal → BC5), мипмапы; 4) Godot: импорт и ретаргет анимаций
# idle/wave/wave_both/walk → <имя>_anims.res (camp_rocketbox_retarget.gd).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${1:-$HOME/.cache/deltaplan/rocketbox}
NAMES="Male_Adult_06 Male_Adult_10 Female_Adult_12 Female_Adult_17"
DST=$ROOT/assets/models/world/rocketbox
export XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.cache/dp-xdg/$(basename "$ROOT")}

if [ ! -d "$SRC/Assets" ]; then
	git clone --depth 1 --filter=blob:none --sparse https://github.com/microsoft/Microsoft-Rocketbox.git "$SRC"
	paths=""
	for n in $NAMES; do paths="$paths Assets/Avatars/Adults/$n/Export Assets/Avatars/Adults/$n/Textures"; done
	# shellcheck disable=SC2086
	git -C "$SRC" sparse-checkout set --no-cone $paths LICENSE.md
fi

for n in $NAMES; do
	blender -b -P "$ROOT/tools/blender/build_camp_rocketbox.py" -- "$SRC/Assets/Avatars/Adults/$n" "$DST" |
		grep -E '^ROCKETBOX|Error|Traceback' || true
	for f in "$DST/$n"/*.jpg "$DST/$n"/*.png; do
		nm=0
		case "$f" in *_normal.png) nm=1 ;; esac
		rel=${f#"$ROOT"/}
		cat > "$f.import" <<EOF
[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://$rel"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=$nm
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
EOF
	done
done
cd "$ROOT"
godot --headless --path . --import >/dev/null 2>&1 || true
godot --headless --path . --script tools/blender/camp_rocketbox_retarget.gd
du -sh "$DST"/*/
