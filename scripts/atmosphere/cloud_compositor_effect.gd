class_name CloudCompositorEffect
extends CompositorEffect
## Облака в буфере пониженного разрешения (Forward+/Mobile): compute-raymarch всех облаков
## за один проход — за кадр луч в одном пикселе из блока 2×2 (обход за 4 кадра, PF-7), сборка
## буфера из истории с перепроекцией и свежих соседей и билатеральный апскейл поверх кадра
## до прозрачных объектов.
## Код формы и света — общий с боксовым шейдером (cloud_common.gdshaderinc).
## Данные (облака, параметры) выставляет CloudLayer с главного потока.

const COMMON := "res://scripts/atmosphere/cloud_common.gdshaderinc"
const MARCH := "res://scripts/atmosphere/cloud_raymarch_cs.gdshaderinc"
const COMPOSITE := "res://scripts/atmosphere/cloud_composite_cs.gdshaderinc"
const TEMPORAL := "res://scripts/atmosphere/cloud_temporal_cs.gdshaderinc"
const FLOATS_PER_CLOUD := 24
## Порядок полей UBO (std140) — как в заголовке compute-шейдера ниже.
const VEC_PARAMS := [
	["sun_dir", "sun_energy"],
	["sun_color", "ambient_energy"],
	["ambient_top", "boil"],
	["ambient_bottom", "extinction"],
	["wind_offset", "light_absorb"],
	["fog_color", "fog_density"],
]
const FLOAT_PARAMS := [
	"shape_period_m", "detail_period_m", "hf_period_m", "top_period_m",
	"shape_tex_size", "detail_tex_size", "curl_strength_m", "powder_strength",
	"phase_forward", "phase_back", "phase_mix", "silver",
	"ms_strength", "fine_step_per_m", "fine_step_min_m", "light_step_m",
	"lod_distance_m", "fog_sun_scatter", "base_darkness", "base_relief_m",
	"sky_occlusion_m", "surface_sharpness",
	"light_step_growth", "anvil_spread", "anvil_shift", "virga_depth_m",
	"virga_density", "virga_period_m",
]
const INT_PARAMS := ["coarse_steps", "max_iterations", "light_steps", "detail_enabled"]

## Замер (--perf): сколько заняла последняя сборка шейдеров облаков, мс.
static var build_ms: float = -1.0

## Облака: по FLOATS_PER_CLOUD чисел (см. CloudLayer._gpu_record).
var clouds_data: PackedFloat32Array = PackedFloat32Array()
var cloud_count: int = 0
## Параметры шейдера по именам (как uniform в cloud_volume.gdshader).
var params: Dictionary = {}
var noise_shape: Texture3D
var noise_detail: Texture3D
## Доля разрешения буфера облаков (0,5 — половина по каждой оси).
var resolution_scale: float = 0.5
## Предел площади буфера облаков, пикселей (0 — без предела; PF-К2).
var max_buffer_px: int = 0
## Вес свежего луча во временном накоплении (1 — без истории; меньше — глаже, но дольше
## догоняет). Свежий луч в пикселе — раз в 4 кадра, поэтому вес больше прежних 0,12 за кадр.
var temporal_weight: float = 0.35
## Вес оценки по свежим соседям в пикселях без луча в этом кадре (подтягивает их к соседям,
## пока своего луча нет; 0 — только история).
var fill_weight: float = 0.06
## Скачок камеры за кадр, после которого история не берётся: поворот, град, и сдвиг, м.
const CUT_DEG := 25.0
const CUT_M := 300.0
## Смещение свежего пикселя в блоке 2×2 по кадрам: сначала диагональ — за 2 кадра покрыт
## весь блок «шахматкой».
const QUARTER_ORDER: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 1), Vector2i(1, 0), Vector2i(0, 1)]

var _rd: RenderingDevice
var _march: RID
var _march_pipe: RID
var _comp: RID
var _comp_pipe: RID
var _temp: RID
var _temp_pipe: RID
var _temp_ubo: RID
## История (ping-pong) и что было в прошлом кадре — для перепроекции; глубины (r — до сцены,
## g — до облака) — тоже ping-pong: прошлые нужны для проверки разрыва по рельефу.
var _hist: Array[RID] = [RID(), RID()]
var _hdep: Array[RID] = [RID(), RID()]
var _hist_i: int = 0
var _hist_valid: bool = false
var _prev_proj: Projection = Projection.IDENTITY
var _prev_cam: Transform3D = Transform3D.IDENTITY
var _s_linear_clamp: RID
var _ubo: RID
var _ssbo: RID
var _ssbo_bytes: int = 0
var _low_color: RID
var _low_depth: RID
var _low_size: Vector2i = Vector2i.ZERO
var _s_linear_rep: RID
var _s_nearest: RID
var _frame: int = 0
var _failed: bool = false


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	_rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		var rids := [_march, _comp, _temp, _ubo, _temp_ubo, _ssbo, _low_color, _low_depth]
		rids.append_array([_hist[0], _hist[1], _hdep[0], _hdep[1]])
		rids.append_array([_s_linear_rep, _s_linear_clamp, _s_nearest])
		for rid in rids:
			if rid.is_valid():
				_rd.free_rid(rid)


## Размер буфера облаков по внутреннему размеру кадра (PF-К2): lowres_scale, но площадь не больше max_buffer_px.
static func buffer_size(full: Vector2i, scale: float = 0.5, max_px: int = 0) -> Vector2i:
	var s := scale
	var area := float(full.x) * float(full.y)
	if max_px > 0 and area * s * s > float(max_px):
		s = sqrt(float(max_px) / area)
	return Vector2i(maxi(1, ceili(full.x * s)), maxi(1, ceili(full.y * s)))


func _render_callback(_type: int, render_data: RenderData) -> void:
	if _rd == null or _failed or noise_shape == null or noise_detail == null:
		return
	if not _march.is_valid() and not _build():
		_failed = true
		return
	var sb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var sd := render_data.get_render_scene_data() as RenderSceneDataRD
	if sb == null or sd == null:
		return
	var full := sb.get_internal_size()
	if full.x <= 0 or full.y <= 0:
		return
	var low := buffer_size(full, resolution_scale, max_buffer_px)
	_ensure_targets(low)
	var proj := sd.get_view_projection(0)
	var inv_proj := proj.inverse()
	var cam_t := sd.get_cam_transform()
	_frame += 1
	var ofs: Vector2i = QUARTER_ORDER[_frame % 4]
	_update_ubo(inv_proj, cam_t, low, full, ofs)
	_update_ssbo()
	var depth := sb.get_depth_layer(0)
	var color := sb.get_color_layer(0)
	var shape_rd := RenderingServer.texture_get_rd_texture(noise_shape.get_rid())
	var detail_rd := RenderingServer.texture_get_rd_texture(noise_detail.get_rid())
	if not shape_rd.is_valid() or not detail_rd.is_valid():
		return
	var set0 := UniformSetCacheRD.get_cache(_march, 0, [
		_sampler_u(0, _s_linear_rep, shape_rd),
		_sampler_u(1, _s_linear_rep, detail_rd),
		_sampler_u(2, _s_nearest, depth),
		_image_u(3, _low_color),
		_buffer_u(4, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, _ubo),
		_buffer_u(5, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, _ssbo),
		_image_u(6, _low_depth),
	])
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _march_pipe)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	var qn := (low + Vector2i.ONE) / 2
	_rd.compute_list_dispatch(cl, ceili(qn.x / 8.0), ceili(qn.y / 4.0), 1)
	_rd.compute_list_end()
	var resolved := _temporal(low, full, proj, inv_proj, cam_t, depth, ofs)
	var set1 := UniformSetCacheRD.get_cache(_comp, 0, [
		_image_u(0, color),
		_sampler_u(1, _s_nearest, resolved),
		_sampler_u(2, _s_nearest, _hdep[_hist_i]),
		_sampler_u(3, _s_nearest, depth),
	])
	var pc := PackedFloat32Array()
	for c in 4:
		var v: Vector4 = inv_proj[c]
		pc.append_array([v.x, v.y, v.z, v.w])
	pc.append_array([low.x, low.y, full.x, full.y])
	var pcb := pc.to_byte_array()
	cl = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _comp_pipe)
	_rd.compute_list_bind_uniform_set(cl, set1, 0)
	_rd.compute_list_set_push_constant(cl, pcb, pcb.size())
	_rd.compute_list_dispatch(cl, ceili(full.x / 8.0), ceili(full.y / 8.0), 1)
	_rd.compute_list_end()


## Собирает буфер облаков из марша по четвертям и истории (cloud_temporal_cs); возвращает
## текстуру для апскейла (глубины для него — _hdep[_hist_i]).
func _temporal(
	low: Vector2i, full: Vector2i, proj: Projection, inv_proj: Projection, cam: Transform3D,
	depth: RID, ofs: Vector2i
) -> RID:
	var src := _hist[_hist_i]
	var src_d := _hdep[_hist_i]
	_hist_i = 1 - _hist_i
	var dst := _hist[_hist_i]
	var dst_d := _hdep[_hist_i]
	# Скачок камеры (смена вида, телепорт, рывок больше CUT_DEG за кадр) — истории нет.
	var fwd_dot := (-_prev_cam.basis.z).normalized().dot((-cam.basis.z).normalized())
	if fwd_dot < cos(deg_to_rad(CUT_DEG)) or _prev_cam.origin.distance_to(cam.origin) > CUT_M:
		_hist_valid = false
	# Вид текущего кадра → вид и клип прошлого (в double на CPU: мировые координаты велики).
	var to_prev := Projection(_prev_cam.affine_inverse() * cam)
	var reproj := _prev_proj * to_prev
	var f := PackedFloat32Array()
	for m in [inv_proj, reproj, to_prev]:
		for c in 4:
			var v: Vector4 = m[c]
			f.append_array([v.x, v.y, v.z, v.w])
	f.append_array([low.x, low.y, full.x, full.y])
	f.append_array([temporal_weight, fill_weight, 1.0 if _hist_valid else 0.0, 0.0])
	var b := f.to_byte_array()
	b.append_array(PackedInt32Array([ofs.x, ofs.y, 0, 0]).to_byte_array())
	_rd.buffer_update(_temp_ubo, 0, b.size(), b)
	var set2 := UniformSetCacheRD.get_cache(_temp, 0, [
		_sampler_u(0, _s_nearest, _low_color),
		_sampler_u(1, _s_nearest, _low_depth),
		_sampler_u(2, _s_linear_clamp, src),
		_image_u(3, dst),
		_buffer_u(4, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, _temp_ubo),
		_sampler_u(5, _s_nearest, depth),
		_sampler_u(6, _s_nearest, src_d),
		_image_u(7, dst_d),
	])
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _temp_pipe)
	_rd.compute_list_bind_uniform_set(cl, set2, 0)
	_rd.compute_list_dispatch(cl, ceili(low.x / 8.0), ceili(low.y / 8.0), 1)
	_rd.compute_list_end()
	_hist_valid = true
	_prev_proj = proj
	_prev_cam = cam
	return dst


# ---------------------------------------------------------------- сборка

func _header() -> String:
	var h := "#version 450\n"
	h += "layout(set = 0, binding = 0) uniform sampler3D noise_shape;\n"
	h += "layout(set = 0, binding = 1) uniform sampler3D noise_detail;\n"
	h += "layout(set = 0, binding = 2) uniform sampler2D depth_tex;\n"
	h += "layout(rgba16f, set = 0, binding = 3) uniform writeonly image2D out_cloud;\n"
	h += "layout(set = 0, binding = 4, std140) uniform Params {\n"
	h += "\tmat4 inv_proj;\n\tmat4 cam_to_world;\n\tvec4 sizes;\n"
	for pair in VEC_PARAMS:
		h += "\tvec3 %s;\n\tfloat %s;\n" % pair
	for n in FLOAT_PARAMS:
		h += "\tfloat %s;\n" % n
	for n in INT_PARAMS:
		h += "\tint %s;\n" % n
	h += "\tint cloud_count;\n\tint frame;\n\tint ofs_x;\n\tint ofs_y;\n};\n"
	h += "layout(set = 0, binding = 5, std430) readonly buffer Clouds { vec4 d[]; } clouds;\n"
	h += "layout(rg32f, set = 0, binding = 6) uniform writeonly image2D out_depth;\n"
	return h


func _compile(code: String) -> RID:
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = code
	var spirv := _rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("CloudCompositorEffect: " + spirv.compile_error_compute)
		return RID()
	return _rd.shader_create_from_spirv(spirv)


static func _text(path: String) -> String:
	var inc := load(path) as ShaderInclude
	return inc.code if inc != null else ""


func _build() -> bool:
	var t0 := Time.get_ticks_usec()
	_march = _compile(_header() + _text(COMMON) + _text(MARCH))
	_comp = _compile("#version 450\n" + _text(COMPOSITE))
	_temp = _compile("#version 450\n" + _text(TEMPORAL))
	if not _march.is_valid() or not _comp.is_valid() or not _temp.is_valid():
		return false
	_march_pipe = _rd.compute_pipeline_create(_march)
	_comp_pipe = _rd.compute_pipeline_create(_comp)
	_temp_pipe = _rd.compute_pipeline_create(_temp)
	build_ms = (Time.get_ticks_usec() - t0) / 1000.0
	var s := RDSamplerState.new()
	s.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	s.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	s.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_s_linear_rep = _rd.sampler_create(s)
	var lc := RDSamplerState.new()
	lc.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	lc.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	lc.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	lc.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_s_linear_clamp = _rd.sampler_create(lc)
	var n := RDSamplerState.new()
	_s_nearest = _rd.sampler_create(n)
	_ubo = _rd.uniform_buffer_create(_ubo_bytes().size(), _ubo_bytes())
	_temp_ubo = _rd.uniform_buffer_create(240)
	return true


## Цели: марш — буфер четвертей (_low_color, _low_depth: по пикселю на блок 2×2 буфера
## облаков), история и её глубины — полный буфер облаков.
func _ensure_targets(low: Vector2i) -> void:
	if low == _low_size and _low_color.is_valid():
		return
	for rid in [_low_color, _low_depth, _hist[0], _hist[1], _hdep[0], _hdep[1]]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_low_size = low
	_hist_valid = false
	var qn := (low + Vector2i.ONE) / 2
	var f := RDTextureFormat.new()
	f.width = qn.x
	f.height = qn.y
	f.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	f.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	)
	_low_color = _rd.texture_create(f, RDTextureView.new())
	f.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	_low_depth = _rd.texture_create(f, RDTextureView.new())
	f.width = low.x
	f.height = low.y
	_hdep[0] = _rd.texture_create(f, RDTextureView.new())
	_hdep[1] = _rd.texture_create(f, RDTextureView.new())
	f.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	_hist[0] = _rd.texture_create(f, RDTextureView.new())
	_hist[1] = _rd.texture_create(f, RDTextureView.new())


# ---------------------------------------------------------------- данные

func _ubo_bytes(
	inv_proj: Projection = Projection.IDENTITY,
	cam: Transform3D = Transform3D.IDENTITY,
	low: Vector2i = Vector2i.ONE,
	full: Vector2i = Vector2i.ONE,
	ofs: Vector2i = Vector2i.ZERO
) -> PackedByteArray:
	var f := PackedFloat32Array()
	for c in 4:
		var v: Vector4 = inv_proj[c]
		f.append_array([v.x, v.y, v.z, v.w])
	for v3 in [cam.basis.x, cam.basis.y, cam.basis.z]:
		f.append_array([v3.x, v3.y, v3.z, 0.0])
	f.append_array([cam.origin.x, cam.origin.y, cam.origin.z, 1.0])
	f.append_array([low.x, low.y, full.x, full.y])
	for pair in VEC_PARAMS:
		var v: Vector3 = params.get(pair[0], Vector3.ZERO)
		f.append_array([v.x, v.y, v.z, float(params.get(pair[1], 0.0))])
	for n in FLOAT_PARAMS:
		f.append(float(params.get(n, 0.0)))
	var b := f.to_byte_array()
	var ints := PackedInt32Array()
	for n in INT_PARAMS:
		ints.append(int(params.get(n, 0)))
	ints.append_array([cloud_count, _frame, ofs.x, ofs.y])
	b.append_array(ints.to_byte_array())
	# Блок std140 округляется до 16 байт.
	b.resize(ceili(b.size() / 16.0) * 16)
	return b


func _update_ubo(
	inv_proj: Projection, cam: Transform3D, low: Vector2i, full: Vector2i, ofs: Vector2i
) -> void:
	var b := _ubo_bytes(inv_proj, cam, low, full, ofs)
	_rd.buffer_update(_ubo, 0, b.size(), b)


func _update_ssbo() -> void:
	var b := clouds_data.to_byte_array()
	if b.is_empty():
		b.resize(FLOATS_PER_CLOUD * 4)
	if b.size() > _ssbo_bytes:
		if _ssbo.is_valid():
			_rd.free_rid(_ssbo)
		_ssbo_bytes = maxi(b.size() * 2, 16 * FLOATS_PER_CLOUD * 4)
		_ssbo = _rd.storage_buffer_create(_ssbo_bytes)
	_rd.buffer_update(_ssbo, 0, b.size(), b)


static func _sampler_u(binding: int, sampler: RID, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler)
	u.add_id(tex)
	return u


static func _image_u(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u


static func _buffer_u(binding: int, type: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	u.add_id(buf)
	return u
