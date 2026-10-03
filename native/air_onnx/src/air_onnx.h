// AirOnnx — ONNX Runtime (CPU) для GDScript: контракт O2 v1 (docs/contracts/air-onnx.md).
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace Ort {
struct Session;
}

class AirOnnx : public godot::RefCounted {
	GDCLASS(AirOnnx, godot::RefCounted)

public:
	AirOnnx();
	~AirOnnx() override;

	// intra-op потоки ORT; действует на следующий load(). По умолчанию 4; <= 0 — выбор ORT.
	void set_intra_op_threads(int n) { threads_ = n; }
	int get_intra_op_threads() const { return threads_; }

	// 0 — успех; 1 — файл не читается; 2 — ORT не создал сессию; 3 — у модели нет входов/выходов;
	// 4 — не загрузилась библиотека ORT.
	int load(const godot::String &path);

	godot::PackedStringArray input_names() const;
	godot::PackedStringArray output_names() const;
	// Формы из модели (-1 — динамическое измерение); неизвестное имя — пусто.
	godot::PackedInt64Array input_shape(const godot::String &name) const;
	godot::PackedInt64Array output_shape(const godot::String &name) const;
	// custom metadata_map модели (строка → строка).
	godot::Dictionary metadata() const { return metadata_; }

	// {имя входа: PackedFloat32Array} → {имя выхода: PackedFloat32Array}, порядок C.
	// Ошибка (нет/лишний вход, размер ≠ форме, ошибка ORT) — {} и last_error().
	godot::Dictionary run(const godot::Dictionary &inputs);

	godot::String last_error() const { return error_; }

protected:
	static void _bind_methods();

private:
	struct Port {
		std::string name; // UTF-8, как в модели
		godot::String gname;
		std::vector<int64_t> shape;
		int elem_type = 0; // ONNXTensorElementDataType
	};

	void clear();
	static godot::PackedInt64Array shape_of(const std::vector<Port> &ports, const godot::String &name);

	std::unique_ptr<Ort::Session> session_;
	std::vector<Port> inputs_, outputs_;
	godot::Dictionary metadata_;
	godot::String error_;
	int threads_ = 4;
};
