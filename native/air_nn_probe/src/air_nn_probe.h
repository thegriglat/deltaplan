// AirNnProbe — пробный стык ONNX Runtime <-> Godot (NN-7а, контракт П5 v1). Не финальный API N5.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <memory>
#include <string>

namespace Ort {
struct Session;
}

class AirNnProbe : public godot::RefCounted {
	GDCLASS(AirNnProbe, godot::RefCounted)

public:
	AirNnProbe();
	~AirNnProbe() override;

	// 0 — успех; 1 — файл не читается; 2 — ORT не создал сессию; 3 — у модели нет входа/выхода;
	// 4 — не загрузилась библиотека ORT.
	int load(const godot::String &path);
	// Вход [1, C, H, W] float32, порядок C; выход — плоский первый выход. Пустой — ошибка (см. last_error).
	godot::PackedFloat32Array run(const godot::PackedFloat32Array &input, const godot::PackedInt64Array &shape);
	godot::PackedInt64Array output_shape() const { return out_shape_; }
	godot::String last_error() const { return error_; }
	// Сверх П5 v1 (для замеров): intra-op потоки ORT; действует на следующий load(). 0 — по умолчанию ORT.
	void set_intra_op_threads(int n) { threads_ = n; }
	int get_intra_op_threads() const { return threads_; }

protected:
	static void _bind_methods();

private:
	std::unique_ptr<Ort::Session> session_;
	godot::PackedInt64Array out_shape_;
	godot::String error_;
	std::string in_name_, out_name_;
	int threads_ = 1;
};
