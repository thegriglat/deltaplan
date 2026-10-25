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

/// Конфиги: пары (имя, текст json как есть), W5.
#[derive(Clone, Debug, Default)]
pub struct Configs {
    pub files: Vec<(String, String)>,
}

impl Configs {
    pub fn new(files: Vec<(String, String)>) -> Self {
        Configs { files }
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
}

/// Ядро подъёма (W6, `CORE_STRIDE = 15`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
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
