# Пробник AirNnProbe (NN-7а): GDExtension на godot-cpp + ONNX Runtime (готовые бинарники, C/C++ API).
# Собирать через build.sh (качает зависимости и задаёт ORT_DIR, PROBE_BIN_DIR, GODOTCPP_CUSTOM_API_FILE).
cmake_minimum_required(VERSION 3.17)
project(air_nn_probe LANGUAGES CXX)

set(DEPS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party" CACHE PATH "каталог зависимостей")
set(ORT_DIR "" CACHE PATH "распакованный onnxruntime-<os>-x64-<ver>")
set(PROBE_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/bin" CACHE PATH "куда класть библиотеку")
set(GODOTCPP_TARGET template_release CACHE STRING "")

add_subdirectory("${DEPS_DIR}/godot-cpp" godot-cpp EXCLUDE_FROM_ALL)

add_library(air_nn_probe SHARED src/air_nn_probe.cpp src/register_types.cpp)
target_include_directories(air_nn_probe PRIVATE "${ORT_DIR}/include")
target_link_libraries(air_nn_probe PRIVATE godot::cpp)

# С ORT не компонуемся: библиотека грузится в рантайме (dlopen/LoadLibrary) из каталога расширения,
# из неё берётся только C-символ OrtGetApiBase; C++-обёртка onnxruntime_cxx_api.h — заголовочная.
# Поэтому годится и MSVC-сборка ORT под mingw (C ABI), и не мешает RTLD_DEEPBIND Godot (см. air_nn_probe.cpp).
if(WIN32)
    target_link_options(air_nn_probe PRIVATE -static)
    set_target_properties(air_nn_probe PROPERTIES PREFIX "")
else()
    target_link_libraries(air_nn_probe PRIVATE ${CMAKE_DL_LIBS})
    target_link_options(air_nn_probe PRIVATE -static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL)
endif()

set_target_properties(air_nn_probe PROPERTIES
    CXX_STANDARD 17
    CXX_EXTENSIONS OFF
    CXX_VISIBILITY_PRESET hidden
    POSITION_INDEPENDENT_CODE ON
    LIBRARY_OUTPUT_DIRECTORY "$<1:${PROBE_BIN_DIR}>"
    RUNTIME_OUTPUT_DIRECTORY "$<1:${PROBE_BIN_DIR}>"
)
