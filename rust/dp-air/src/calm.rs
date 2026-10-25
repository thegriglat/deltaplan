use crate::{
    AirModel, Cloud, Conditions, Configs, Core, Crest, Decomposition, Error, Focus, Place, Raster,
    SampleMode, State, Status,
};
use std::sync::Arc;

/// Заглушка: всё по W1, ветер 0, σ 0, описаний нет; Ready сразу после `load_place`.
#[derive(Debug, Default)]
pub struct Calm {
    placed: bool,
    time_s: f64,
}

impl Calm {
    pub fn new() -> Self {
        Self::default()
    }

    fn need_place(&self) -> Result<(), Error> {
        if self.placed {
            Ok(())
        } else {
            Err(Error::no_place("place is not loaded"))
        }
    }

    fn check_time(t: f64) -> Result<(), Error> {
        if t.is_finite() && t >= 0.0 {
            Ok(())
        } else {
            Err(Error::bad_input(format!(
                "time {t} must be finite and >= 0"
            )))
        }
    }
}

impl AirModel for Calm {
    fn configure(&mut self, cfg: &Configs, _seed: u64) -> Result<(), Error> {
        cfg.parse().map(|_| ())
    }

    fn load_place(&mut self, _place: Place) -> Result<(), Error> {
        self.placed = true;
        self.time_s = 0.0;
        Ok(())
    }

    fn unload_place(&mut self) {
        self.placed = false;
        self.time_s = 0.0;
    }

    fn set_conditions(&mut self, _c: &Conditions) -> Result<(), Error> {
        Ok(())
    }

    fn set_sun_direction(&mut self, _to_sun: Option<[f32; 3]>) {}

    fn set_static_thermals(&mut self, list: &[[f32; 4]], _mode: u8) -> Result<(), Error> {
        if list.iter().flatten().any(|v| !v.is_finite()) {
            return Err(Error::bad_input("thermals: NaN/inf"));
        }
        Ok(())
    }

    fn set_focuses(&mut self, f: &[Focus]) -> Result<(), Error> {
        if f.iter().any(|x| {
            !(x.pos.iter().all(|v| v.is_finite()) && x.weight.is_finite() && x.weight >= 0.0)
        }) {
            return Err(Error::bad_input("focuses: NaN/inf or negative weight"));
        }
        Ok(())
    }

    fn advance_to(&mut self, t: f64) -> Result<(), Error> {
        Self::check_time(t)?;
        self.need_place()?;
        if t < self.time_s {
            return Err(Error::bad_input(format!(
                "advance_to {t} is before current time {}",
                self.time_s
            )));
        }
        self.time_s = t;
        Ok(())
    }

    fn start_at(&mut self, t: f64) -> Result<(), Error> {
        Self::check_time(t)?;
        self.need_place()?;
        self.time_s = t;
        Ok(())
    }

    fn status(&self) -> Status {
        Status {
            state: if self.placed {
                State::Ready
            } else {
                State::Empty
            },
            progress: if self.placed { 1.0 } else { 0.0 },
            time_s: self.time_s,
            reason: String::new(),
        }
    }

    fn sample_many(&self, pts: &[[f32; 3]], _mode: SampleMode, out: &mut [[f32; 4]]) {
        out.iter_mut().zip(pts).for_each(|(o, _)| *o = [0.0; 4]);
    }

    fn cloud_density_many(&self, pts: &[[f32; 3]], out: &mut [f32]) {
        out.iter_mut().zip(pts).for_each(|(o, _)| *o = 0.0);
    }

    fn cloudbase_msl(&self) -> f32 {
        0.0
    }

    fn background_wind(&self, heights: &[f32], out: &mut [[f32; 2]]) {
        out.iter_mut().zip(heights).for_each(|(o, _)| *o = [0.0; 2]);
    }

    fn weather_json(&self) -> String {
        "{}".into()
    }

    fn weather_version(&self) -> (u64, u64) {
        (0, 0)
    }

    fn sun_state(&self) -> [f32; 4] {
        [0.0; 4]
    }

    fn cores(&self, _center: [f32; 3], _radius: f32, out: &mut Vec<Core>) {
        out.clear();
    }

    fn clouds(&self, _center: [f32; 3], _radius: f32, out: &mut Vec<Cloud>) {
        out.clear();
    }

    fn cloud_raster(&self) -> Option<Arc<Raster>> {
        None
    }

    fn wave_crests(&self, _c: [f32; 2], _r: f32, _min_eta: f32, _sp: f32, out: &mut Vec<Crest>) {
        out.clear();
    }

    fn decompose(&self, _p: [f32; 3]) -> Decomposition {
        Decomposition::default()
    }

    fn debug_raster(&self, _name: &str) -> Option<Arc<Raster>> {
        None
    }

    fn debug_raster_names(&self) -> Vec<String> {
        Vec::new()
    }
}
