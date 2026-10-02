#include "air_nn_probe.h"

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

#include <cstdint>
#include <cstring>
#include <exception>
#include <vector>

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

// Грузит ORT из каталога, где лежит эта библиотека. "" — успех, иначе текст ошибки.
String ensure_ort() {
	static bool ok = false;
	static String err;
	if (ok || !err.is_empty()) {
		return err;
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
	HMODULE h = LoadLibraryExW((dir + ORT_LIB).c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
	if (!h) {
		err = vformat("не загрузилась onnxruntime.dll (код %d)", (int64_t)GetLastError());
		return err;
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
		err = String("не загрузилась ") + ORT_LIB + ": " + dlerror();
		return err;
	}
	get_api_base = reinterpret_cast<GetApiBase>(dlsym(h, "OrtGetApiBase"));
#endif
	if (!get_api_base) {
		err = "в библиотеке ORT нет OrtGetApiBase";
		return err;
	}
	const OrtApi *api = get_api_base()->GetApi(ORT_API_VERSION);
	if (!api) {
		err = vformat("ORT не поддерживает API версии %d (библиотека: %s)", ORT_API_VERSION,
				String(get_api_base()->GetVersionString()));
		return err;
	}
	Ort::InitApi(api);
	ok = true;
	return err;
}

// Одно окружение ORT на процесс (создаётся при первом load).
Ort::Env &ort_env() {
	static Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "air_nn_probe");
	return env;
}
} // namespace

AirNnProbe::AirNnProbe() {}
AirNnProbe::~AirNnProbe() {}

void AirNnProbe::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load", "path"), &AirNnProbe::load);
	ClassDB::bind_method(D_METHOD("run", "input", "shape"), &AirNnProbe::run);
	ClassDB::bind_method(D_METHOD("output_shape"), &AirNnProbe::output_shape);
	ClassDB::bind_method(D_METHOD("last_error"), &AirNnProbe::last_error);
	ClassDB::bind_method(D_METHOD("set_intra_op_threads", "n"), &AirNnProbe::set_intra_op_threads);
	ClassDB::bind_method(D_METHOD("get_intra_op_threads"), &AirNnProbe::get_intra_op_threads);
}

int AirNnProbe::load(const String &path) {
	session_.reset();
	out_shape_.clear();
	error_ = "";
	// Модель читаем через FileAccess: работают res:// и user://, путь не зависит от ОС (на Windows ORT
	// хочет wchar_t-путь — обходим загрузкой из памяти).
	const String ort_err = ensure_ort();
	if (!ort_err.is_empty()) {
		error_ = ort_err;
		return 4;
	}
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
		session_ = std::make_unique<Ort::Session>(ort_env(), bytes.ptr(), (size_t)bytes.size(), so);
	} catch (const std::exception &e) {
		error_ = String("ORT: ") + e.what();
		return 2;
	}
	if (session_->GetInputCount() < 1 || session_->GetOutputCount() < 1) {
		error_ = "у модели нет входа или выхода";
		session_.reset();
		return 3;
	}
	Ort::AllocatorWithDefaultOptions alloc;
	in_name_ = session_->GetInputNameAllocated(0, alloc).get();
	out_name_ = session_->GetOutputNameAllocated(0, alloc).get();
	return 0;
}

PackedFloat32Array AirNnProbe::run(const PackedFloat32Array &input, const PackedInt64Array &shape) {
	PackedFloat32Array out;
	error_ = "";
	if (!session_) {
		error_ = "модель не загружена";
		return out;
	}
	std::vector<int64_t> dims(shape.size());
	int64_t n = 1;
	for (int64_t i = 0; i < shape.size(); i++) {
		dims[i] = shape[i];
		n *= shape[i];
	}
	if (dims.empty() || n != input.size()) {
		error_ = vformat("форма %s не совпадает с длиной входа %d", shape, input.size());
		return out;
	}
	try {
		Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
		// ORT читает вход без копии (const_cast: CreateTensor не пишет во вход).
		Ort::Value x = Ort::Value::CreateTensor<float>(mem, const_cast<float *>(input.ptr()), (size_t)n,
				dims.data(), dims.size());
		const char *in_names[] = { in_name_.c_str() };
		const char *out_names[] = { out_name_.c_str() };
		std::vector<Ort::Value> ys = session_->Run(Ort::RunOptions{ nullptr }, in_names, &x, 1, out_names, 1);
		Ort::TensorTypeAndShapeInfo info = ys[0].GetTensorTypeAndShapeInfo();
		if (info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
			error_ = "выход не float32";
			return out;
		}
		std::vector<int64_t> od = info.GetShape();
		out_shape_.resize((int64_t)od.size());
		for (size_t i = 0; i < od.size(); i++) {
			out_shape_.set((int64_t)i, od[i]);
		}
		const size_t m = info.GetElementCount();
		out.resize((int64_t)m);
		const float *src = ys[0].GetTensorData<float>();
		memcpy(out.ptrw(), src, m * sizeof(float));
	} catch (const std::exception &e) {
		error_ = String("ORT: ") + e.what();
		out.clear();
	}
	return out;
}
