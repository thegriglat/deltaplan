"""Формат корпуса air-synth (контракты S1 рельеф, S2 условия — docs/contracts/air-synth.md): квантование высот,
шарды (varint32-длина + сообщение), индекс, чтение по id через seek. Схема — proto/air_synth/v1/corpus.proto."""
import os
import re
import sys
import numpy as np
from google.protobuf import text_format

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen"))
from air_synth.v1 import corpus_pb2 as pb  # noqa: E402

CONTRACT = {"relief": "S1 v1", "conditions": "S2 v1"}
SHARD_PATTERN = {"relief": "reliefs-{shard:05d}.pb", "conditions": "conditions-{shard:05d}.pb"}
RECORD = {"relief": pb.Relief, "conditions": pb.Conditions}
NG100, DX100, X0 = 384, 100.0, -19200.0
NG400, DX400 = 96, 400.0


def data_root():
    return os.environ.get("AIR_SYNTH_DATA", os.path.expanduser("~/air_synth_data"))


# ------------------------------------------------------------------ высоты
def quantize(h, dx_m, x0_m=X0, y0_m=X0):
    """float (ny, nx) [j — север, i — восток] -> HeightGrid (int16, offset = (min+max)/2, scale = max(0,05; (max−min)/65000))."""
    h = np.ascontiguousarray(h, dtype=np.float64)
    if not np.all(np.isfinite(h)):
        raise ValueError("высоты не конечны")
    ny, nx = h.shape
    lo, hi = float(h.min()), float(h.max())
    offset = (lo + hi) / 2.0
    scale = max(0.05, (hi - lo) / 65000.0)
    q = np.rint((h - offset) / scale).astype("<i2")
    return pb.HeightGrid(nx=nx, ny=ny, dx_m=dx_m, x0_m=x0_m, y0_m=y0_m, offset_m=offset, scale_m=scale, h_i16=q.tobytes())


def to_float(grid, dtype=np.float32):
    """HeightGrid -> (ny, nx), по умолчанию float32; dtype=np.float64 — без потери при деквантовании."""
    if len(grid.h_i16) != 2 * grid.nx * grid.ny:
        raise ValueError("len(h_i16) != 2·nx·ny")
    q = np.frombuffer(grid.h_i16, dtype="<i2").reshape(grid.ny, grid.nx)
    return (grid.offset_m + grid.scale_m * q.astype(np.float64)).astype(dtype)


def block_mean(z, f=4):
    ny, nx = z.shape
    return z.reshape(ny // f, f, nx // f, f).mean(axis=(1, 3))


def slopes_deg(z, dx):
    gy, gx = np.gradient(z, dx)
    return np.degrees(np.arctan(np.hypot(gx, gy)))[1:-1, 1:-1]


def make_relief(corpus_seed, rid, generator_version, params, z100, compute_seconds=0.0):
    """z100 float64 (384, 384) -> Relief (g100 квантованный, g400 — блочное среднее до квантования, сводки)."""
    z100 = np.asarray(z100, dtype=np.float64)
    if z100.shape != (NG100, NG100):
        raise ValueError(f"z100 должен быть {NG100}x{NG100}, а не {z100.shape}")
    z400 = block_mean(z100, 4)
    g100 = quantize(z100, DX100)
    g400 = quantize(z400, DX400)
    s = pb.ReliefSummary(h_min_m=float(z400.min()), h_max_m=float(z400.max()), relief_m=float(z400.max() - z400.min()),
                         slope_mean_deg_400=float(slopes_deg(z400, DX400).mean()),
                         slope_p95_deg_100=float(np.percentile(slopes_deg(z100, DX100), 95)),
                         compute_seconds=float(compute_seconds))
    return pb.Relief(id=rid, corpus_seed=corpus_seed, generator_version=generator_version, params=params, g100=g100, g400=g400, summary=s)


# ------------------------------------------------------------------ шарды
def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def read_varint(buf, pos=0):
    n = shift = 0
    while True:
        b = buf[pos]
        pos += 1
        n |= (b & 0x7F) << shift
        if not b & 0x80:
            return n, pos
        shift += 7


def encode_record(msg):
    """Сообщение -> (префикс длины + байты), детерминированно (map упорядочены)."""
    body = msg.SerializeToString(deterministic=True)
    return varint(len(body)) + body


def shard_path(corpus_dir, kind, shard):
    return os.path.join(corpus_dir, SHARD_PATTERN[kind].format(shard=shard))


def write_atomic(path, data, tmp_dir):
    """Файл появляется целиком: запись в tmp/ -> fsync -> переименование."""
    os.makedirs(tmp_dir, exist_ok=True)
    tmp = os.path.join(tmp_dir, f"{os.path.basename(path)}.{os.getpid()}.part")
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def write_shard(corpus_dir, kind, shard, records_bytes):
    """records_bytes — список encode_record(...). Возвращает число байт."""
    data = b"".join(records_bytes)
    write_atomic(shard_path(corpus_dir, kind, shard), data, os.path.join(corpus_dir, "tmp"))
    return len(data)


def iter_shard_bytes(data):
    """Данные шарда -> (offset, length, сообщение-байты)."""
    pos = 0
    while pos < len(data):
        start = pos
        n, pos = read_varint(data, pos)
        yield start, n, data[pos:pos + n]
        pos += n


def list_shards(corpus_dir, kind):
    rx = re.compile("^" + re.escape(SHARD_PATTERN[kind]).replace(re.escape("{shard:05d}"), r"(\d{5})") + "$")
    out = []
    for name in os.listdir(corpus_dir):
        m = rx.match(name)
        if m:
            out.append(int(m.group(1)))
    return sorted(out)


def _index_entry(kind, shard, off, n, msg):
    if kind == "relief":
        return pb.IndexEntry(id=msg.id, shard=shard, offset=off, length=n, cond_id=0, mix=msg.params.mix, relief_m=msg.summary.relief_m)
    return pb.IndexEntry(id=msg.relief_id, shard=shard, offset=off, length=n, cond_id=msg.cond_id)


def build_index(corpus_dir, kind=None):
    """Пересборка index.pb из готовых шардов (детерминированно). Возвращает ShardIndex."""
    kind = kind or read_manifest(corpus_dir).kind
    idx = pb.ShardIndex(kind=kind)
    ents = []
    for sh in list_shards(corpus_dir, kind):
        with open(shard_path(corpus_dir, kind, sh), "rb") as f:
            data = f.read()
        for off, n, body in iter_shard_bytes(data):
            msg = RECORD[kind].FromString(body)
            ents.append(_index_entry(kind, sh, off, n, msg))
    ents.sort(key=lambda e: (e.id, e.cond_id))
    idx.entries.extend(ents)
    write_atomic(os.path.join(corpus_dir, "index.pb"), idx.SerializeToString(deterministic=True), os.path.join(corpus_dir, "tmp"))
    return idx


# ------------------------------------------------------------------ манифест
def write_manifest(corpus_dir, m):
    tmp = os.path.join(corpus_dir, "tmp")
    write_atomic(os.path.join(corpus_dir, "manifest.pb"), m.SerializeToString(deterministic=True), tmp)
    write_atomic(os.path.join(corpus_dir, "manifest.txt"), text_format.MessageToString(m).encode(), tmp)


def read_manifest(corpus_dir):
    p = os.path.join(corpus_dir, "manifest.pb")
    if not os.path.exists(p):
        raise FileNotFoundError(f"нет manifest.pb в {corpus_dir}")
    m = pb.CorpusManifest.FromString(open(p, "rb").read())
    exp = CONTRACT.get(m.kind)
    if exp is None:
        raise ValueError(f"неизвестный kind манифеста: {m.kind!r}")
    if m.contract != exp:
        raise ValueError(f"контракт корпуса {m.contract!r}, ожидается {exp!r}")
    return m


# ------------------------------------------------------------------ чтение
class Corpus:
    """Корпус рельефов (S1) или набор условий (S2). Читает index.pb (если его нет — сканирует готовые шарды в памяти)."""

    def __init__(self, path):
        self.path = path
        self.manifest = read_manifest(path)
        self.kind = self.manifest.kind
        ip = os.path.join(path, "index.pb")
        if os.path.exists(ip):
            self.index = pb.ShardIndex.FromString(open(ip, "rb").read())
            if self.index.kind != self.kind:
                raise ValueError(f"index.kind {self.index.kind!r} != {self.kind!r}")
        else:
            self.index = self._scan()
        self._by_key = {(e.id, e.cond_id): e for e in self.index.entries}

    def _scan(self):
        idx = pb.ShardIndex(kind=self.kind)
        ents = []
        for sh in list_shards(self.path, self.kind):
            data = open(shard_path(self.path, self.kind, sh), "rb").read()
            for off, n, body in iter_shard_bytes(data):
                ents.append(_index_entry(self.kind, sh, off, n, RECORD[self.kind].FromString(body)))
        ents.sort(key=lambda e: (e.id, e.cond_id))
        idx.entries.extend(ents)
        return idx

    def __len__(self):
        return len(self.index.entries)

    def ids(self):
        return sorted({e.id for e in self.index.entries})

    def _read(self, e):
        with open(shard_path(self.path, self.kind, e.shard), "rb") as f:
            f.seek(e.offset)
            pre = len(varint(e.length))
            buf = f.read(pre + e.length)
        n, pos = read_varint(buf)
        if n != e.length or pos != pre or len(buf) != pre + n:
            raise ValueError(f"индекс не совпадает с шардом {e.shard} по смещению {e.offset}")
        return RECORD[self.kind].FromString(buf[pos:])

    def get(self, rid, cond_id=0):
        """Запись по id (у условий — (relief_id, cond_id)): seek + чтение одной записи."""
        e = self._by_key.get((rid, cond_id))
        if e is None:
            raise KeyError((rid, cond_id))
        return self._read(e)

    def conditions_for(self, relief_id):
        return [self._read(e) for e in self.index.entries if e.id == relief_id]

    def iter_shards(self):
        """Итерация по шардам: (номер шарда, список записей), шарды по возрастанию."""
        for sh in list_shards(self.path, self.kind):
            data = open(shard_path(self.path, self.kind, sh), "rb").read()
            yield sh, [RECORD[self.kind].FromString(b) for _, _, b in iter_shard_bytes(data)]

    def __iter__(self):
        for _, recs in self.iter_shards():
            yield from recs

    def validate_refs(self):
        """Только для условий: каждый relief_id существует в manifest.relief_corpus."""
        if self.kind != "conditions":
            raise ValueError("validate_refs — только для условий")
        rc = self.manifest.relief_corpus
        if not rc:
            raise ValueError("manifest.relief_corpus пуст")
        rel = Corpus(rc)
        have = set(rel.ids())
        missing = sorted({e.id for e in self.index.entries} - have)
        if missing:
            raise ValueError(f"relief_id нет в корпусе {rc}: {missing[:10]}")
        return True


def open_corpus(path):
    return Corpus(path)
