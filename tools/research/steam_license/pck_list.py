#!/usr/bin/env python3
"""Список файлов .pck Godot 4 (формат версии 2/3/4, Godot 4.7): путь, размер, смещение.

Заголовок: 'GDPC', u32 version, u32 major/minor/patch, u32 pack_flags, u64 file_base, u64 dir_offset (v>=3),
16 x u32 reserved; каталог по dir_offset: u32 count, затем записи: u32 len, path (дополнен нулями до 4),
u64 offset, u64 size, md5[16], u32 flags. Пути — 'res://...' (Godot хранит их так же).
Использование: pck_list.py file.pck [out.json]
"""
import json, struct, sys


def list_pck(path):
    with open(path, "rb") as f:
        if f.read(4) != b"GDPC":
            raise SystemExit("не PCK: " + path)
        ver, maj, mnr, pat, flags = struct.unpack("<5I", f.read(20))
        if ver >= 3:
            file_base, dir_off = struct.unpack("<QQ", f.read(16))
        else:
            file_base, dir_off = 0, None
        f.read(64)
        if dir_off is None:
            dir_off = f.tell()
        f.seek(dir_off)
        (n,) = struct.unpack("<I", f.read(4))
        items = []
        for _ in range(n):
            (ln,) = struct.unpack("<I", f.read(4))
            p = f.read(ln).rstrip(b"\0").decode("utf-8")
            off, size = struct.unpack("<QQ", f.read(16))
            f.read(16)
            (fl,) = struct.unpack("<I", f.read(4))
            items.append({"path": p, "bytes": size, "offset": off, "flags": fl})
    return {"version": ver, "godot": f"{maj}.{mnr}.{pat}", "files": items}


if __name__ == "__main__":
    d = list_pck(sys.argv[1])
    if len(sys.argv) > 2:
        json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=0)
    print(d["godot"], "files:", len(d["files"]), "bytes:", sum(i["bytes"] for i in d["files"]))
