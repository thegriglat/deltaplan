// SL-К5 v1: «дерево в клетке» — общий хеш мира для CPU-моделей (TreeCell, tree_cell.gd) и LOD2-крестов
// (tree_cross.gdshader). Дерево определяется индексом клетки c = floor(p_xz / cell_m) и плотностью леса d8
// (0…255) в центре клетки — сдвиг камеры не меняет набор деревьев. Правится только вместе с tree_cell.gd
// (GPU-тест test_tree_cross_gpu сверяет побитово). Без зависимостей от terrain_common.
// Плюс стык форм (SL-К4 v2): доли дизеринга модели и креста по одной горизонтальной дистанции
// и одному шуму экрана — маски дополняют друг друга (модель: шум ≥ t_near; крест: t_far ≤ шум < t_near;
// дальше — шум < t_far).

// PCG2D (Jarzynski, Olano 2020), 32 бита без знака; uvec2(c) — побитовое приведение.
uvec2 tc_hash(ivec2 c) {
	uvec2 v = uvec2(c);
	v = v * 1664525u + 1013904223u;
	v.x += v.y * 1664525u;
	v.y += v.x * 1664525u;
	v = v ^ (v >> 16u);
	v.x += v.y * 1664525u;
	v.y += v.x * 1664525u;
	v = v ^ (v >> 16u);
	return v;
}

// Второй хеш (высота, цвет): PCG2D от переставленных бит h (TreeCell: hash(Vector2i(h.y, h.x))).
uvec2 tc_hash2(uvec2 h) {
	return tc_hash(ivec2(h.yx));
}

// Есть ли дерево: младший байт h.x меньше плотности d8 (0…255) в центре клетки.
bool tc_present(uvec2 h, int d8) {
	return int(h.x & 255u) < d8;
}

// Плотность d8 по байтам текселя маски леса (R — доля леса, G — доля воды), как TreeCell на CPU:
// лес (R ≥ 128) и не вода (G < water8) → dens8, иначе 0.
int tc_d8(int r8, int g8, int water8, int dens8) {
	return (r8 >= 128 && g8 < water8) ? dens8 : 0;
}

// Сдвиг внутри клетки, доли клетки (−0,4…0,4): биты 8…19 обоих компонент.
vec2 tc_offset(uvec2 h) {
	vec2 o = vec2(float((h.x >> 8u) & 0xFFFu), float((h.y >> 8u) & 0xFFFu));
	return (o / 4096.0 - 0.5) * 0.8;
}

// Позиция дерева клетки в мире (XZ), м.
vec2 tc_pos(ivec2 c, uvec2 h, float cell_m) {
	return (vec2(c) + 0.5 + tc_offset(h)) * cell_m;
}

// Случайное 0…1 для породы (h.y & 255).
float tc_species_u(uvec2 h) {
	return float(h.y & 255u) / 256.0;
}

// Вариант модели (биты 20…31 h.y).
int tc_variant(uvec2 h, int variants) {
	return int(((h.y >> 20u) & 0xFFFu) % uint(max(variants, 1)));
}

// Угол поворота вокруг вертикали, рад (биты 20…31 h.x).
float tc_angle(uvec2 h) {
	return float((h.x >> 20u) & 0xFFFu) / 4096.0 * 6.28318530718;
}

// Доля высоты в диапазоне породы 0…1 (16 младших бит h2.x).
float tc_height_t(uvec2 h2) {
	return float(h2.x & 0xFFFFu) / 65536.0;
}

// Разброс цвета 0…1 (16 младших бит h2.y).
float tc_color_t(uvec2 h2) {
	return float(h2.y & 0xFFFFu) / 65536.0;
}

// Доля дальней формы на расстоянии d при границе db и ширине дизеринга dither (как sl_lod_swap_t).
float tc_swap_t(float d, float db, float dither) {
	return clamp((d - db) / dither + 0.5, 0.0, 1.0);
}

// Стык модель → крест (SL-К4 v2): модель видна при шуме ≥ этого порога (r_near ≤ 0 — стыка нет: 0).
float tc_model_t(float d, float k, float r_near, float dither) {
	return r_near > 0.0 ? tc_swap_t(d, r_near * k, dither) : 0.0;
}

// Окно шума креста [x, y): ближе — модель (y = порог модели), дальше — импостер/полог (x).
vec2 tc_cross_window(float d, float k, float r_near, float r_far, float dither) {
	return vec2(tc_swap_t(d, r_far * k, dither), r_near > 0.0 ? tc_swap_t(d, r_near * k, dither) : 1.0);
}
