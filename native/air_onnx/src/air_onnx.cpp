#include "air_onnx.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>

// ORT грузим сами (dlmopen/LoadLibrary) из каталога расширения, а не через DT_NEEDED.
// Linux: другие GDExtension в процессе (addons/debug_draw_3d) содержат статическую libstdc++ и экспортируют
// её символы как STB_GNU_UNIQUE (std::collate<char>::id и т. п.) — они глобальны на процесс, и обычный
// dlopen (даже с RTLD_DEEPBIND) связывает libonnxruntime.so с их копиями locale::id: SIGSEGV в первом
// Ort::Session (Godot 4.7.2 + ORT 1.30). dlmopen(LM_ID_NEWLM) даёт ORT своё пространство имён (своя
// libstdc++/libc). Через границу передаём только указатели на float и C-API ORT.
#define ORT_API_MANUAL_INIT
#include <onnxruntime_cxx_api.h>

#include <cstring>
#include <exception>
#include <mutex>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

using namespace godot;

namespace {
#if defined(_WIN32)
const wchar_t *ORT_LIB = L"onnxruntime.dll";
#elif defined(__APPLE__)
const char *ORT_LIB = "libonnxruntime.dylib";
#else
const char *ORT_LIB = "libonnxruntime.so.1";
#endif

// Глобальные godot::String нельзя: их конструктор зовёт API Godot до инициализации godot-cpp (SIGSEGV
// при загрузке библиотеки). Поэтому состояние создаётся при первом вызове и не удаляется (деструктор
// String при выгрузке библиотеки после деинициализации godot-cpp — тот же риск).
struct OrtState {
	std::mutex mutex;
	bool ok = false;
	String err;
};
OrtState &ort_state() {
	static OrtState *st = new OrtState;
	return *st;
}
Ort::Env *g_env = nullptr;

// Грузит ORT из каталога, где лежит эта библиотека (в экспорте — рядом с исполняемым файлом), и создаёт
// окружение ORT. Один раз на процесс; "" — успех, иначе текст ошибки (повторно не пытаемся).
String ensure_ort() {
	OrtState &st = ort_state();
	std::lock_guard<std::mutex> lock(st.mutex);
	String &g_ort_err = st.err;
	if (st.ok || !g_ort_err.is_empty()) {
		return g_ort_err;
	}
	using GetApiBase = const OrtApiBase *(ORT_API_CALL *)();
	GetApiBase get_api_base = nullptr;
#ifdef _WIN32
	HMODULE self = nullptr;
	GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
			reinterpret_cast<LPCWSTR>(&ensure_ort), &self);
	wchar_t buf[4096];
	DWORD n = GetModuleFileNameW(self, buf, 4096);
	std::wstring dir(buf, n);
	dir = dir.substr(0, dir.find_last_of(L"\\/") + 1);
	// LOAD_WITH_ALTERED_SEARCH_PATH: зависимости onnxruntime.dll (VC++ runtime) ищутся сначала в её каталоге.
	HMODULE h = LoadLibraryExW((dir + ORT_LIB).c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
	if (!h) {
		const DWORD code = GetLastError();
		g_ort_err = vformat("не загрузилась %s (код %d%s)", String(dir.c_str()) + "onnxruntime.dll", (int64_t)code,
				code == 126 ? ": нет файла или его зависимости — msvcp140/vcruntime140 рядом или VC++ Redistributable" : "");
		return g_ort_err;
	}
	get_api_base = reinterpret_cast<GetApiBase>(reinterpret_cast<void *>(GetProcAddress(h, "OrtGetApiBase")));
#else
	Dl_info info{};
	dladdr(reinterpret_cast<void *>(&ensure_ort), &info);
	std::string dir = info.dli_fname ? info.dli_fname : "";
	dir = dir.substr(0, dir.find_last_of('/') + 1);
#ifdef __linux__
	void *h = dlmopen(LM_ID_NEWLM, (dir + ORT_LIB).c_str(), RTLD_NOW | RTLD_LOCAL);
#else
	void *h = dlopen((dir + ORT_LIB).c_str(), RTLD_NOW | RTLD_LOCAL);
#endif
	if (!h) {
		const char *e = dlerror();
		g_ort_err = String("не загрузилась ") + String::utf8((dir + ORT_LIB).c_str()) + ": " + String::utf8(e ? e : "?");
		return g_ort_err;
	}
	get_api_base = reinterpret_cast<GetApiBase>(dlsym(h, "OrtGetApiBase"));
#endif
	if (!get_api_base) {
		g_ort_err = "в библиотеке ORT нет OrtGetApiBase";
		return g_ort_err;
	}
	const OrtApi *api = get_api_base()->GetApi(ORT_API_VERSION);
	if (!api) {
		g_ort_err = vformat("ORT не поддерживает API версии %d (библиотека: %s)", ORT_API_VERSION,
				String(get_api_base()->GetVersionString()));
		return g_ort_err;
	}
	Ort::InitApi(api);
	try {
		// Окружение не удаляем: разрушение при выходе процесса после выгрузки модулей опаснее утечки.
		g_env = new Ort::Env(ORT_LOGGING_LEVEL_WARNING, "air_onnx");
	} catch (const std::exception &e) {
		g_ort_err = String("ORT: окружение не создано: ") + String::utf8(e.what());
		return g_ort_err;
	}
	st.ok = true;
	return g_ort_err;
}

// Произведение измерений; -1 — есть неизвестное (динамическое) измерение.
int64_t numel(const std::vector<int64_t> &dims) {
	int64_t n = 1;
	for (int64_t d : dims) {
		if (d < 0) {
			return -1;
		}
		n *= d;
	}
	return n;
}

PackedInt64Array to_packed(const std::vector<int64_t> &v) {
	PackedInt64Array a;
	a.resize((int64_t)v.size());
	for (size_t i = 0; i < v.size(); i++) {
		a.set((int64_t)i, v[i]);
	}
	return a;
}
} // namespace

AirOnnx::AirOnnx() {}
AirOnnx::~AirOnnx() {}

void AirOnnx::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_intra_op_threads", "n"), &AirOnnx::set_intra_op_threads);
	ClassDB::bind_method(D_METHOD("get_intra_op_threads"), &AirOnnx::get_intra_op_threads);
	ClassDB::bind_method(D_METHOD("load", "path"), &AirOnnx::load);
	ClassDB::bind_method(D_METHOD("input_names"), &AirOnnx::input_names);
	ClassDB::bind_method(D_METHOD("output_names"), &AirOnnx::output_names);
	ClassDB::bind_method(D_METHOD("input_shape", "name"), &AirOnnx::input_shape);
	ClassDB::bind_method(D_METHOD("output_shape", "name"), &AirOnnx::output_shape);
	ClassDB::bind_method(D_METHOD("metadata"), &AirOnnx::metadata);
	ClassDB::bind_method(D_METHOD("run", "inputs"), &AirOnnx::run);
	ClassDB::bind_method(D_METHOD("last_error"), &AirOnnx::last_error);
}

void AirOnnx::clear() {
	session_.reset();
	inputs_.clear();
	outputs_.clear();
	metadata_ = Dictionary();
}

int AirOnnx::load(const String &path) {
	clear();
	error_ = "";
	const String ort_err = ensure_ort();
	if (!ort_err.is_empty()) {
		error_ = ort_err;
		return 4;
	}
	// Модель читаем через FileAccess: работают res://, user:// и абсолютные пути, путь не зависит от ОС
	// (на Windows ORT хочет wchar_t-путь — обходим загрузкой из памяти).
	PackedByteArray bytes = FileAccess::get_file_as_bytes(path);
	if (bytes.is_empty()) {
		error_ = "не читается файл модели: " + path;
		return 1;
	}
	try {
		Ort::SessionOptions so;
		if (threads_ > 0) {
			so.SetIntraOpNumThreads(threads_);
		}
		so.SetInterOpNumThreads(1);
		so.SetExecutionMode(ORT_SEQUENTIAL);
		so.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
		session_ = std::make_unique<Ort::Session>(*g_env, bytes.ptr(), (size_t)bytes.size(), so);

		Ort::AllocatorWithDefaultOptions alloc;
		auto read_ports = [&](bool is_input, std::vector<Port> &ports) {
			const size_t count = is_input ? session_->GetInputCount() : session_->GetOutputCount();
			for (size_t i = 0; i < count; i++) {
				Port p;
				p.name = is_input ? session_->GetInputNameAllocated(i, alloc).get()
								  : session_->GetOutputNameAllocated(i, alloc).get();
				p.gname = String::utf8(p.name.c_str());
				Ort::TypeInfo ti = is_input ? session_->GetInputTypeInfo(i) : session_->GetOutputTypeInfo(i);
				if (ti.GetONNXType() == ONNX_TYPE_TENSOR) {
					auto tsi = ti.GetTensorTypeAndShapeInfo();
					p.shape = tsi.GetShape();
					p.elem_type = (int)tsi.GetElementType();
				}
				ports.push_back(std::move(p));
			}
		};
		read_ports(true, inputs_);
		read_ports(false, outputs_);

		Ort::ModelMetadata md = session_->GetModelMetadata();
		std::vector<Ort::AllocatedStringPtr> keys = md.GetCustomMetadataMapKeysAllocated(alloc);
		for (const auto &k : keys) {
			Ort::AllocatedStringPtr v = md.LookupCustomMetadataMapAllocated(k.get(), alloc);
			metadata_[String::utf8(k.get())] = String::utf8(v ? v.get() : "");
		}
	} catch (const std::exception &e) {
		error_ = String("ORT: ") + String::utf8(e.what());
		clear();
		return 2;
	}
	if (inputs_.empty() || outputs_.empty()) {
		error_ = "у модели нет входов или выходов";
		clear();
		return 3;
	}
	return 0;
}

PackedStringArray AirOnnx::input_names() const {
	PackedStringArray a;
	for (const Port &p : inputs_) {
		a.push_back(p.gname);
	}
	return a;
}

PackedStringArray AirOnnx::output_names() const {
	PackedStringArray a;
	for (const Port &p : outputs_) {
		a.push_back(p.gname);
	}
	return a;
}

PackedInt64Array AirOnnx::shape_of(const std::vector<Port> &ports, const String &name) {
	for (const Port &p : ports) {
		if (p.gname == name) {
			return to_packed(p.shape);
		}
	}
	return PackedInt64Array();
}

PackedInt64Array AirOnnx::input_shape(const String &name) const {
	return shape_of(inputs_, name);
}

PackedInt64Array AirOnnx::output_shape(const String &name) const {
	return shape_of(outputs_, name);
}

Dictionary AirOnnx::run(const Dictionary &inputs) {
	Dictionary result;
	error_ = "";
	if (!session_) {
		error_ = "модель не загружена";
		return result;
	}
	// Лишние ключи — ошибка (скорее всего опечатка в имени входа).
	const Array keys = inputs.keys();
	for (int64_t i = 0; i < keys.size(); i++) {
		const Variant &k = keys[i];
		bool known = false;
		if (k.get_type() == Variant::STRING || k.get_type() == Variant::STRING_NAME) {
			const String ks = k;
			for (const Port &p : inputs_) {
				known = known || p.gname == ks;
			}
		}
		if (!known) {
			error_ = vformat("лишний вход %s (у модели: %s)", k, input_names());
			return result;
		}
	}
	// Массивы держим в векторе: тензоры ORT смотрят в их память без копии.
	std::vector<PackedFloat32Array> data;
	std::vector<std::vector<int64_t>> dims;
	data.reserve(inputs_.size());
	dims.reserve(inputs_.size());
	for (const Port &p : inputs_) {
		if (!inputs.has(p.gname)) {
			error_ = "нет входа " + p.gname;
			return result;
		}
		const Variant v = inputs[p.gname];
		if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
			error_ = vformat("вход %s: нужен PackedFloat32Array, а не %s", p.gname, Variant::get_type_name(v.get_type()));
			return result;
		}
		if (p.elem_type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
			error_ = vformat("вход %s в модели не float32 (тип ORT %d)", p.gname, p.elem_type);
			return result;
		}
		PackedFloat32Array a = v;
		std::vector<int64_t> d = p.shape;
		// Одно динамическое измерение выводим из длины; больше одного — не умеем (O1: формы статические).
		int unknown = -1;
		int64_t known_n = 1;
		bool ok = !d.empty();
		for (size_t j = 0; j < d.size(); j++) {
			if (d[j] < 0) {
				ok = ok && unknown < 0;
				unknown = (int)j;
			} else {
				known_n *= d[j];
			}
		}
		if (ok && unknown >= 0) {
			ok = known_n > 0 && a.size() % known_n == 0 && a.size() > 0;
			if (ok) {
				d[unknown] = a.size() / known_n;
			}
		}
		if (!ok || numel(d) != a.size()) {
			error_ = vformat("вход %s: длина %d не совпадает с формой %s", p.gname, a.size(), to_packed(p.shape));
			return result;
		}
		data.push_back(a);
		dims.push_back(std::move(d));
	}
	try {
		Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
		std::vector<Ort::Value> xs;
		std::vector<const char *> in_names, out_names;
		for (size_t i = 0; i < inputs_.size(); i++) {
			// ORT читает вход без копии (const_cast: CreateTensor не пишет во вход).
			xs.push_back(Ort::Value::CreateTensor<float>(mem, const_cast<float *>(data[i].ptr()), (size_t)data[i].size(),
					dims[i].data(), dims[i].size()));
			in_names.push_back(inputs_[i].name.c_str());
		}
		for (const Port &p : outputs_) {
			out_names.push_back(p.name.c_str());
		}
		std::vector<Ort::Value> ys = session_->Run(Ort::RunOptions{ nullptr }, in_names.data(), xs.data(), xs.size(),
				out_names.data(), out_names.size());
		for (size_t i = 0; i < ys.size(); i++) {
			Ort::TensorTypeAndShapeInfo info = ys[i].GetTensorTypeAndShapeInfo();
			if (info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
				error_ = "выход " + outputs_[i].gname + " не float32";
				return Dictionary();
			}
			const size_t m = info.GetElementCount();
			PackedFloat32Array out;
			out.resize((int64_t)m);
			if (m > 0) {
				memcpy(out.ptrw(), ys[i].GetTensorData<float>(), m * sizeof(float));
			}
			result[outputs_[i].gname] = out;
		}
	} catch (const std::exception &e) {
		error_ = String("ORT: ") + String::utf8(e.what());
		return Dictionary();
	}
	return result;
}
