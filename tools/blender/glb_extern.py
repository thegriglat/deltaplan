"""Постобработка glb без Blender: встроенную картинку по имени заменить ссылкой (uri) на внешний файл,
а её байты убрать из бинарного куска. Godot тогда грузит один res://-ресурс на все модели.
Запуск: python3 tools/blender/glb_extern.py <файл.glb> <имя_картинки>=<путь_к_png> ..."""
import json
import os
import struct
import sys


def externalize(glb_path: str, mapping: dict) -> int:
    """mapping: имя картинки → абсолютный путь внешнего файла. Возвращает число заменённых картинок."""
    d = open(glb_path, "rb").read()
    jl = struct.unpack("<I", d[12:16])[0]
    j = json.loads(d[20:20 + jl])
    bl = struct.unpack("<I", d[20 + jl:24 + jl])[0]
    binc = d[28 + jl:28 + jl + bl]
    drop = []
    for im in j.get("images", []):
        if im.get("name") in mapping and "bufferView" in im:
            drop.append(im.pop("bufferView"))
            im.pop("mimeType", None)
            im["uri"] = os.path.relpath(mapping[im["name"]], os.path.dirname(glb_path)).replace(os.sep, "/")
    if not drop:
        return 0
    bvs = j["bufferViews"]
    # новые байты: пропускаем убранные views, остальные выравниваем по 4
    new, newbin, remap = [], bytearray(), {}
    for i, bv in enumerate(bvs):
        if i in drop:
            continue
        while len(newbin) % 4:
            newbin.append(0)
        remap[i] = len(new)
        nb = dict(bv)
        nb["byteOffset"] = len(newbin)
        newbin += binc[bv.get("byteOffset", 0):bv.get("byteOffset", 0) + bv["byteLength"]]
        new.append(nb)
    j["bufferViews"] = new
    for key in ("accessors", "images"):
        for e in j.get(key, []):
            if "bufferView" in e:
                e["bufferView"] = remap[e["bufferView"]]
    while len(newbin) % 4:
        newbin.append(0)
    j["buffers"][0]["byteLength"] = len(newbin)
    js = json.dumps(j, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(newbin))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(newbin), 0x004E4942) + bytes(newbin)
    open(glb_path, "wb").write(out)
    return len(drop)


if __name__ == "__main__":
    mp = dict(a.split("=", 1) for a in sys.argv[2:])
    print(sys.argv[1], externalize(sys.argv[1], {k: os.path.abspath(v) for k, v in mp.items()}))
