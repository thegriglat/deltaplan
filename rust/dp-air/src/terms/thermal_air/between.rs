//! «Между» пузырями (`AirThermals.with_between`): к результату пузырей `(w, маска, болтанка)` —
//! `w_conv` поля без ожидаемого чистого потока пузырей, вне ядра; доля поля вместо фонового
//! опускания (маска растёт на долю поля).
use crate::field::field_set::FieldSet;

impl super::AirThermals {
    /// `r = [w, маска, σ края]` пузырей в точке `p` (мир) → с «между». Поля нет в точке — `r`.
    pub fn with_between(&self, fs: &FieldSet, p: [f32; 3], r: [f64; 3]) -> [f64; 3] {
        let (fw, share) = fs.sample_w_conv(p, f32::NAN);
        if share <= 0.0 {
            return r;
        }
        // избыток потока шаблона над w_conv (под крышкой, TB-12) не делает «между» отрицательным: вычитаем не больше
        // max(w_conv, 0); настоящее опускание поля (w_conv < 0) остаётся как есть
        let between = fw - (share * self.expected_net(p)).min(fw.max(0.0));
        let m = r[1];
        [r[0] + (1.0 - m) * between, m + (1.0 - m) * share, r[2]]
    }
}
