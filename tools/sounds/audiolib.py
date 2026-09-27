"""Общие функции обработки звука (numpy + ffmpeg). Используется process_assets.py и synth_*.py."""
import json, os, subprocess, tempfile
import numpy as np

SR = 44100


def load(path, sr=SR, mono=True):
    """Декодировать любой файл через ffmpeg в float32 [n, ch]."""
    ch = 1 if mono else 2
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", str(ch), "-ar", str(sr), "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, ch).copy()


def save_ogg(path, x, sr=SR, q=4):
    """Сохранить float [n, ch] в Ogg Vorbis (quality q: 4 ≈ 128 кбит/с стерео)."""
    x = np.atleast_2d(x.T).T if x.ndim == 1 else x
    if x.ndim == 1:
        x = x[:, None]
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ac", str(x.shape[1]), "-ar", str(sr), "-i", "-",
                    "-c:a", "libvorbis", "-q:a", str(q), path],
                   input=np.ascontiguousarray(x, dtype=np.float32).tobytes(), check=True)


def rms_db(x):
    return 20 * np.log10(np.sqrt(np.mean(x.astype(np.float64) ** 2)) + 1e-12)


def peak_db(x):
    return 20 * np.log10(np.max(np.abs(x)) + 1e-12)


def lufs(x, sr=SR):
    """Интегральная громкость (EBU R128) через ffmpeg ebur128."""
    with tempfile.NamedTemporaryFile(suffix=".f32") as f:
        f.write(np.ascontiguousarray(x, dtype=np.float32).tobytes()); f.flush()
        err = subprocess.run(["ffmpeg", "-nostats", "-f", "f32le", "-ac", str(x.shape[1]), "-ar", str(sr), "-i", f.name,
                              "-af", "ebur128=peak=true", "-f", "null", "-"], capture_output=True, text=True).stderr
    tail = err[err.rfind("Summary:"):]
    i = float(tail.split("I:")[1].split("LUFS")[0])
    lra = float(tail.split("LRA:")[1].split("LU")[0])
    tp = float(tail.split("Peak:")[1].split("dBFS")[0])
    return i, lra, tp


def norm_lufs(x, target, sr=SR, max_tp=-1.0):
    """Нормировать по громкости, но не выше true-peak max_tp (dBFS)."""
    i, _, tp = lufs(x, sr)
    g = target - i
    g = min(g, max_tp - tp)
    return x * 10 ** (g / 20)


def norm_peak(x, target_db=-1.0):
    return x * 10 ** ((target_db - peak_db(x)) / 20)


def fade(x, fin_s=0.005, fout_s=0.02, sr=SR):
    x = x.copy(); n = len(x)
    a = min(int(fin_s * sr), n // 2); b = min(int(fout_s * sr), n // 2)
    if a: x[:a] *= np.sin(np.linspace(0, np.pi / 2, a))[:, None] ** 2
    if b: x[-b:] *= np.cos(np.linspace(0, np.pi / 2, b))[:, None] ** 2
    return x


def highpass(x, hz, sr=SR, order=2):
    from scipy.signal import butter, sosfiltfilt
    return sosfiltfilt(butter(order, hz, "hp", fs=sr, output="sos"), x, axis=0).astype(np.float32)


def lowpass(x, hz, sr=SR, order=2):
    from scipy.signal import butter, sosfiltfilt
    return sosfiltfilt(butter(order, hz, "lp", fs=sr, output="sos"), x, axis=0).astype(np.float32)


def make_loop(x, xfade_s=2.0, sr=SR):
    """Бесшовный луп из x (длина L+n): y = x[:L], где начало y[:n] — равномощный кроссфейд
    x[:n] (fade-in) и x[L:L+n] (fade-out). Конец y[L-1]=x[L-1] переходит в y[0]≈x[L] — естественное продолжение."""
    n = int(xfade_s * sr)
    L = len(x) - n
    y = x[:L].copy()
    t = np.linspace(0, 1, n, endpoint=False)[:, None]
    y[:n] = x[:n] * np.sin(t * np.pi / 2) + x[L:L + n] * np.cos(t * np.pi / 2)
    return y


def loop_seam_report(x, sr=SR):
    """Оценка стыка лупа: скачок сэмпла на стыке относительно типичного |dx|, и разница RMS 50 мс у краёв."""
    d = np.abs(np.diff(x, axis=0))
    seam = np.abs(x[0] - x[-1])
    w = int(0.05 * sr)
    return {
        "seam_jump_vs_p99": float(np.max(seam) / (np.percentile(d, 99) + 1e-12)),
        "edge_rms_diff_db": float(abs(rms_db(x[:w]) - rms_db(x[-w:]))),
    }


def onsets(x, sr=SR, hop=256, thresh_db=12, min_gap_s=0.12):
    """Простое определение ударов: рост огибающей на thresh_db над медленным фоном."""
    m = np.abs(x).max(axis=1)
    nfr = len(m) // hop
    env = 20 * np.log10(np.sqrt(np.mean(m[: nfr * hop].reshape(nfr, hop) ** 2, axis=1)) + 1e-9)
    from scipy.ndimage import minimum_filter1d, uniform_filter1d
    bg = uniform_filter1d(minimum_filter1d(env, int(1.0 * sr / hop)), int(1.0 * sr / hop))
    res, last = [], -1e9
    for i in range(1, nfr):
        if env[i] - bg[i] > thresh_db and env[i] - env[i - 1] > 3 and (i - last) * hop / sr > min_gap_s:
            res.append((i * hop / sr, float(env[i]), float(env[i] - bg[i]))); last = i
    return res
