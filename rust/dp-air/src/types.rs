use crate::error::Error;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Empty,
    Loading,
    Ready,
    Failed,
}

impl State {
    /// Числовой код W1: 0 EMPTY, 1 LOADING, 2 READY, 3 FAILED.
    pub fn as_int(self) -> i32 {
        match self {
            State::Empty => 0,
            State::Loading => 1,
            State::Ready => 2,
            State::Failed => 3,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SampleMode {
    Full,
    Mean,
}

/// Конфиги: пары (ключ секции, текст json как есть), W5 v11.
#[derive(Clone, Debug, Default)]
pub struct Configs {
    pub files: Vec<(String, String)>,
}

impl Configs {
    pub fn new(files: Vec<(String, String)>) -> Self {
        Configs { files }
    }

    /// Текст секции по ключу (`atmosphere`, `weather_model`, `surface_heat`, `world`,
    /// `weather/<пресет>`; W5 v11) — единственное место поиска секции.
    pub fn get(&self, section: &str) -> Option<&str> {
        self.files
            .iter()
            .find(|(n, _)| n == section)
            .map(|(_, t)| t.as_str())
    }

    /// Секция как json; нет секции или не json — `None`.
    pub fn value(&self, section: &str) -> Option<serde_json::Value> {
        self.get(section).and_then(|t| serde_json::from_str(t).ok())
    }

    /// Каждый текст должен быть json; неизвестные ключи не ошибка.
    pub fn parse(&self) -> Result<Vec<(&str, serde_json::Value)>, Error> {
        self.files
            .iter()
            .map(|(name, text)| {
                serde_json::from_str(text)
                    .map(|v| (name.as_str(), v))
                    .map_err(|e| Error::bad_input(format!("config '{name}': {e}")))
            })
            .collect()
    }
}

/// Точка интереса: где воздух считать подробнее.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Focus {
    pub pos: [f32; 3],
    pub weight: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Status {
    pub state: State,
    pub progress: f32,
    pub time_s: f64,
    pub reason: String,
    /// Идентификатор этапа задачи поля (латиница, snake_case; `""` — нет): `lookup`,
    /// `prepare`, `phases`, `coarse`, `solve_mech`, `solve_heat`, `windows`
    /// (`field::runtime::STAGES`). Подпись для экрана делает потребитель.
    pub stage: String,
    /// Итерации решателя в текущем этапе (с его начала; этап без итераций — 0).
    pub iters: u32,
    /// Номер прогона с 1: вход в этап с итерациями решателя (`coarse`, `solve_mech`,
    /// `solve_heat`; в каждом проходе); 0 — сейчас не такой этап. `iters` каждый прогон с нуля.
    pub run: u32,
    /// Прогонов по текущему плану задачи, `runs ≥ run` (растёт, когда нужен следующий
    /// проход); 0 — нет этапа с итерациями.
    pub runs: u32,
}

/// Ядро подъёма (W6, `CORE_STRIDE = 15`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct Core {
    pub id: f32,
    /// бит 0 — статическое, 1 — есть облако, 2 — грозовое Cb
    pub flags: f32,
    pub x: f32,
    pub z: f32,
    pub y_src: f32,
    pub top: f32,
    pub w: f32,
    pub radius: f32,
    pub lean_x: f32,
    pub lean_z: f32,
    pub age_s: f32,
    /// ожидаемая жизнь; живой воздух — NaN
    pub life_s: f32,
    pub stage: f32,
    pub vis_seed: f32,
    pub storm: f32,
}

/// Облако (W6, `CLOUD_STRIDE = 10`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct Cloud {
    pub id: f32,
    /// -1 — нет
    pub core_id: f32,
    pub x: f32,
    pub z: f32,
    pub base_msl: f32,
    pub top_msl: f32,
    pub radius: f32,
    pub growth: f32,
    pub decay: f32,
    /// бит 2 — Cb
    pub flags: f32,
}

/// Гребень волны (W6, `CREST_STRIDE = 4`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct Crest {
    pub x: f32,
    pub z: f32,
    pub eta: f32,
    pub crest: f32,
}

/// Растр на сетке W1 (узлы, строка растёт к +Z). Слои — `nx * ny` значений каждый.
/// Растр облаков: слои `cover, depth, stage, activity, bg_cover, bg_depth`; отладочные — свои.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Raster {
    pub version: u64,
    pub nx: u32,
    pub ny: u32,
    pub dx: f32,
    pub x0: f32,
    pub z0: f32,
    pub base_msl: f32,
    pub time_s: f64,
    pub layers: Vec<(String, Vec<f32>)>,
}

/// Разложение скорости по слагаемым (W7).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Decomposition {
    pub names: Vec<String>,
    pub vel: Vec<[f32; 3]>,
    pub sigma: Vec<f32>,
    pub total: [f32; 4],
}

impl Core {
    /// Плоский вид (порядок полей W6, `CORE_STRIDE = 15`).
    pub fn to_array(&self) -> [f32; 15] {
        [
            self.id,
            self.flags,
            self.x,
            self.z,
            self.y_src,
            self.top,
            self.w,
            self.radius,
            self.lean_x,
            self.lean_z,
            self.age_s,
            self.life_s,
            self.stage,
            self.vis_seed,
            self.storm,
        ]
    }
}

impl Cloud {
    /// Плоский вид (порядок полей W6, `CLOUD_STRIDE = 10`).
    pub fn to_array(&self) -> [f32; 10] {
        [
            self.id,
            self.core_id,
            self.x,
            self.z,
            self.base_msl,
            self.top_msl,
            self.radius,
            self.growth,
            self.decay,
            self.flags,
        ]
    }
}

impl Crest {
    /// Плоский вид (порядок полей W6, `CREST_STRIDE = 4`).
    pub fn to_array(&self) -> [f32; 4] {
        [self.x, self.z, self.eta, self.crest]
    }
}

/// Снимок последней подачи поля для фасада (W4 v5, переходное): заголовок и тело TI-К3 v3
/// (`field::solved::encode_solved`, каналы `f32` без потерь). `version = 0` и пустые строки — поля нет.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FieldExport {
    pub version: u64,
    /// За сколько подменить прежнее поле; `0` — сразу.
    pub blend_s: f64,
    /// Время атмосферы начала подмены.
    pub blend_t0: f64,
    pub header_json: String,
    pub data: Vec<u8>,
}
