class_name CloudCompositorEffect
extends CompositorEffect
## Облака в буфере пониженного разрешения (Forward+/Mobile): compute-raymarch всех облаков
## за один проход и билатеральный апскейл поверх кадра до прозрачных объектов.
## Код формы и света — общий с боксовым шейдером (cloud_common.gdshaderinc).
## Данные (облака, параметры) выставляет CloudLayer с главного потока.

const COMMON := "res://scripts/atmosphere/cloud_common.gdshaderinc"
const MARCH := "res://scripts/atmosphere/cloud_raymarch_cs.gdshaderinc"
const COMPOSITE := "res://scripts/atmosphere/cloud_composite_cs.gdshaderinc"
const FLOATS_PER_CLOUD := 20
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
	"light_step_growth",
]
const INT_PARAMS := ["coarse_steps", "max_iterations", "light_steps", "detail_enabled"]

## Облака: по FLOATS_PER_CLOUD чисел (см. CloudLayer._gpu_record).
var clouds_data: PackedFloat32Array = PackedFloat32Array()
var cloud_count: int = 0
## Параметры шейдера по именам (как uniform в cloud_volume.gdshader).
var params: Dictionary = {}
var noise_shape: Texture3D
var noise_detail: Texture3D
## Доля разрешения буфера облаков (0,5 — половина по каждой оси).
var resolution_scale: float = 0.5

var _rd: RenderingDevice
var _march: RID
var _march_pipe: RID
var _comp: RID
var _comp_pipe: RID
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
		for rid in [_march, _comp, _ubo, _ssbo, _low_color, _low_depth, _s_linear_rep, _s_nearest]:
			if rid.is_valid():
				_rd.free_rid(rid)


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
	var low := Vector2i(
		maxi(1, ceili(full.x * resolution_scale)), maxi(1, ceili(full.y * resolution_scale))
	)
	_ensure_targets(low)
	var inv_proj := sd.get_view_projection(0).inverse()
	_update_ubo(inv_proj, sd.get_cam_transform(), low, full)
	_update_ssbo()
	_frame += 1
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
	_rd.compute_list_dispatch(cl, ceili(low.x / 8.0), ceili(low.y / 8.0), 1)
	_rd.compute_list_end()
	var set1 := UniformSetCacheRD.get_cache(_comp, 0, [
		_image_u(0, color),
		_sampler_u(1, _s_nearest, _low_color),
		_sampler_u(2, _s_nearest, _low_depth),
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
	h += "\tint cloud_count;\n\tint frame;\n\tint pad_a;\n\tint pad_b;\n};\n"
	h += "layout(set = 0, binding = 5, std430) readonly buffer Clouds { vec4 d[]; } clouds;\n"
	h += "layout(r32f, set = 0, binding = 6) uniform writeonly image2D out_depth;\n"
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
	_march = _compile(_header() + _text(COMMON) + _text(MARCH))
	_comp = _compile("#version 450\n" + _text(COMPOSITE))
	if not _march.is_valid() or not _comp.is_valid():
		return false
	_march_pipe = _rd.compute_pipeline_create(_march)
	_comp_pipe = _rd.compute_pipeline_create(_comp)
	var s := RDSamplerState.new()
	s.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	s.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	s.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_s_linear_rep = _rd.sampler_create(s)
	var n := RDSamplerState.new()
	_s_nearest = _rd.sampler_create(n)
	_ubo = _rd.uniform_buffer_create(_ubo_bytes().size(), _ubo_bytes())
	return true


func _ensure_targets(low: Vector2i) -> void:
	if low == _low_size and _low_color.is_valid():
		return
	for rid in [_low_color, _low_depth]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_low_size = low
	var f := RDTextureFormat.new()
	f.width = low.x
	f.height = low.y
	f.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	f.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	)
	_low_color = _rd.texture_create(f, RDTextureView.new())
	f.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	_low_depth = _rd.texture_create(f, RDTextureView.new())


# ---------------------------------------------------------------- данные

func _ubo_bytes(
	inv_proj: Projection = Projection.IDENTITY,
	cam: Transform3D = Transform3D.IDENTITY,
	low: Vector2i = Vector2i.ONE,
	full: Vector2i = Vector2i.ONE
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
	ints.append_array([cloud_count, _frame, 0, 0])
	b.append_array(ints.to_byte_array())
	# Блок std140 округляется до 16 байт.
	b.resize(ceili(b.size() / 16.0) * 16)
	return b


func _update_ubo(inv_proj: Projection, cam: Transform3D, low: Vector2i, full: Vector2i) -> void:
	var b := _ubo_bytes(inv_proj, cam, low, full)
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
