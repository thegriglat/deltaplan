#!/bin/sh
# Включить loop=true в .import для всех *_loop.ogg (Godot создаёт .import при первом импорте).
# После запуска: godot --headless --path . --import
cd "$(dirname "$0")/../.." || exit 1
for f in assets/sounds/*/*_loop.ogg.import; do
  sed -i 's/^loop=false/loop=true/' "$f"
done
grep -l '^loop=true' assets/sounds/*/*.ogg.import
