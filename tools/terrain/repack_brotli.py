#!/usr/bin/env python3
"""Перепаковать слои рельефа data/terrain/*/*.f32.gz -> .f32.br (brotli q11, lgwin 22).

Без перегенерации DEM: gzip распаковывается, байты сжимаются brotli, проверяется
идентичность (sha256) распакованных данных, поле `file` в meta.json обновляется,
старый .gz удаляется. Нужен пакет brotli (pip install brotli).
"""
import gzip
import hashlib
import json
import sys
from pathlib import Path

import brotli

ROOT = Path(__file__).resolve().parents[2] / "data" / "terrain"


def main() -> int:
    for gz in sorted(ROOT.glob("*/*.f32.gz")):
        raw = gzip.decompress(gz.read_bytes())
        packed = brotli.compress(raw, quality=11, lgwin=22)
        assert hashlib.sha256(brotli.decompress(packed)).digest() == hashlib.sha256(raw).digest()
        br = gz.with_name(gz.name[:-3] + ".br")
        br.write_bytes(packed)
        meta_path = gz.parent / "meta.json"
        text = meta_path.read_text()
        meta_path.write_text(text.replace(gz.name, br.name))
        print(f"{gz.parent.name}/{gz.name}: {gz.stat().st_size} -> {br.stat().st_size}  sha256 {hashlib.sha256(raw).hexdigest()[:16]}")
        gz.unlink()
    return 0


if __name__ == "__main__":
    sys.exit(main())
