//! Кеш решённых полей воздуха на диске (RW-6p): перенос `AirFieldCache` (FL-К1) в каталоге реализации (`set_cache_dir`).
//!
//! Запись — один файл `<имя>.dpac`: `DPAC1\0\0\0`, длина заголовка (u64 LE), заголовок TI-К3 v3 (json,
//! `cache: 2`, `key`, `model_hash`), тело `zstd` без потерь (`f32`). `<имя>` — первые 16 hex sha256
//! канонического json ключа (ключи словарей по алфавиту). Файл появляется целиком (запись во
//! временный файл с уникальным именем и переименование): читатель видит старую или новую запись,
//! две записи одного ключа не портят друг друга. Формат файлов прежнего кеша не читается и не
//! пишется — совместимость не нужна.
//!
//! Размер: `max_bytes` на сумму записей; после записи самые давние по времени изменения (`get`
//! обновляет его) удаляются, пока сумма больше предела. Индекса нет — папка и есть индекс.
//! Повреждённая или чужая запись (формат, `model_hash`, `key`) — промах, файл удаляется.
use super::solved::{SolvedField, encode_solved, key_diff, parse_solved};
use crate::error::Error;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

/// Номер формата записи (`cache` в заголовке).
pub const CACHE_FORMAT: i64 = 4;
/// Предел суммы записей по умолчанию (секция `atmosphere → air_cache.max_mb`), байт.
pub const DEFAULT_MAX_BYTES: u64 = 200 << 20;
const MAGIC: &[u8; 8] = b"DPAC1\0\0\0";
const EXT: &str = "dpac";
/// Временные файлы старше этого срока считаются брошенными.
const STALE_TMP: Duration = Duration::from_secs(3600);

/// Почему записи нет.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Miss {
    /// Записи нет (или кеш выключен: пустой каталог).
    Absent,
    /// Запись была и удалена: причина (испорчена, другая модель, другой ключ).
    Rejected(String),
}

#[derive(Clone, Debug)]
pub struct FieldCache {
    /// Каталог кеша; пустой путь — кеш выключен.
    pub dir: PathBuf,
    pub max_bytes: u64,
}

fn io_err(what: &str, e: std::io::Error) -> Error {
    Error::bad_input(format!("FieldCache: {what}: {e}"))
}

/// Имя записи: 16 hex sha256 канонического json ключа.
pub fn name_of(key: &Value) -> String {
    let text = serde_json::to_string(key).unwrap_or_default();
    let digest = Sha256::digest(text.as_bytes());
    digest.iter().take(8).map(|b| format!("{b:02x}")).collect()
}

impl FieldCache {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        FieldCache {
            dir: dir.into(),
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }

    pub fn enabled(&self) -> bool {
        !self.dir.as_os_str().is_empty() && self.max_bytes > 0
    }

    /// Путь записи по ключу.
    pub fn path_of(&self, key: &Value) -> PathBuf {
        self.dir.join(format!("{}.{EXT}", name_of(key)))
    }

    /// Поле по ключу. `model_hash` — текущий хеш модели: запись другой модели не берётся.
    /// Промах — нет записи либо она испорчена/чужая (тогда файл удалён).
    pub fn get(&self, key: &Value, model_hash: &str) -> Result<SolvedField, Miss> {
        if !self.enabled() {
            return Err(Miss::Absent);
        }
        let path = self.path_of(key);
        let raw = match fs::read(&path) {
            Ok(r) => r,
            Err(_) => return Err(Miss::Absent),
        };
        match decode(&raw, key, model_hash) {
            Ok(f) => {
                touch(&path);
                Ok(f)
            }
            Err(why) => {
                let _ = fs::remove_file(&path);
                Err(Miss::Rejected(why))
            }
        }
    }

    /// Положить поле под ключ (без потерь). `extra` — поля заголовка сверх обязательных
    /// (`status`, …). Затем вытеснение сверх `max_bytes`.
    pub fn put(
        &self,
        key: &Value,
        model_hash: &str,
        field: &SolvedField,
        extra: &Map<String, Value>,
    ) -> Result<(), Error> {
        if !self.enabled() {
            return Ok(());
        }
        let mut hx = extra.clone();
        hx.insert("cache".into(), json!(CACHE_FORMAT));
        hx.insert("model_hash".into(), json!(model_hash));
        let (head, data) = encode_solved(field, key, &hx)?;
        let mut bytes = Vec::with_capacity(16 + head.len() + data.len());
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&(head.len() as u64).to_le_bytes());
        bytes.extend_from_slice(head.as_bytes());
        bytes.extend_from_slice(&data);
        fs::create_dir_all(&self.dir).map_err(|e| io_err("каталог", e))?;
        let path = self.path_of(key);
        write_atomic(&path, &bytes)?;
        self.prune(&path);
        Ok(())
    }

    /// Записи: `(путь, размер, время изменения)`.
    fn entries(&self) -> Vec<(PathBuf, u64, SystemTime)> {
        let Ok(rd) = fs::read_dir(&self.dir) else {
            return Vec::new();
        };
        let now = SystemTime::now();
        let mut out = Vec::new();
        for e in rd.flatten() {
            let p = e.path();
            let Ok(md) = e.metadata() else { continue };
            let mt = md.modified().unwrap_or(now);
            match p.extension().and_then(|s| s.to_str()) {
                Some(EXT) => out.push((p, md.len(), mt)),
                Some("tmp") if now.duration_since(mt).is_ok_and(|d| d > STALE_TMP) => {
                    let _ = fs::remove_file(&p);
                }
                _ => {}
            }
        }
        out
    }

    /// Сумма размеров записей, байт.
    pub fn total_bytes(&self) -> u64 {
        self.entries().iter().map(|e| e.1).sum()
    }

    /// Вытеснить самые давние записи (кроме `keep`), пока сумма больше предела.
    fn prune(&self, keep: &Path) {
        let mut ents = self.entries();
        let mut total: u64 = ents.iter().map(|e| e.1).sum();
        if total <= self.max_bytes {
            return;
        }
        ents.sort_by_key(|e| e.2);
        for (p, sz, _) in ents {
            if total <= self.max_bytes {
                break;
            }
            if p == keep {
                continue;
            }
            if fs::remove_file(&p).is_ok() {
                total -= sz;
            }
        }
    }
}

fn decode(raw: &[u8], key: &Value, model_hash: &str) -> Result<SolvedField, String> {
    if raw.len() < 16 || &raw[..8] != MAGIC {
        return Err("не запись кеша".into());
    }
    let hl = u64::from_le_bytes(raw[8..16].try_into().unwrap()) as usize;
    let end = 16usize
        .checked_add(hl)
        .filter(|&e| e <= raw.len())
        .ok_or("заголовок за пределами файла")?;
    let head = std::str::from_utf8(&raw[16..end]).map_err(|_| "заголовок не utf-8")?;
    let h: Value = serde_json::from_str(head).map_err(|e| format!("заголовок не читается: {e}"))?;
    if h.get("cache").and_then(Value::as_i64) != Some(CACHE_FORMAT) {
        return Err("не запись кеша".into());
    }
    let mh = h.get("model_hash").and_then(Value::as_str).unwrap_or("");
    if model_hash.is_empty() || mh != model_hash {
        return Err(format!(
            "модель воздуха другой версии (хеш {} ≠ {model_hash})",
            if mh.is_empty() { "?" } else { mh }
        ));
    }
    let d = key_diff(h.get("key").unwrap_or(&Value::Null), key);
    if !d.is_empty() {
        return Err(format!("key не совпал ({d})"));
    }
    parse_solved(head, &raw[end..]).map_err(|e| format!("не читается: {}", e.msg))
}

static SEQ: AtomicU64 = AtomicU64::new(0);

/// Временный файл с уникальным именем и переименование. Если целевой файл занят читателем
/// (Windows) и переименование не удалось — запись другого потока того же ключа остаётся.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), Error> {
    let tmp = path.with_extension(format!(
        "{}.{}.tmp",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let res = (|| {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        drop(f);
        let mut last = Ok(());
        for _ in 0..5 {
            match fs::rename(&tmp, path) {
                Ok(()) => return Ok(()),
                Err(e) => {
                    last = Err(e);
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
        }
        if path.exists() { Ok(()) } else { last }
    })();
    if tmp.exists() {
        let _ = fs::remove_file(&tmp);
    }
    res.map_err(|e| io_err("запись", e))
}

/// Обновить время изменения записи (для вытеснения по давности); ошибки не важны.
fn touch(path: &Path) {
    if let Ok(f) = fs::OpenOptions::new().write(true).open(path) {
        let _ = f.set_modified(SystemTime::now());
    }
}
