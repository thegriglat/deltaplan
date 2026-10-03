# GDExtension AirOnnx (контракт O2): godot-cpp + ONNX Runtime (готовые бинарники, C/C++ API).
# Собирать через build.sh (качает зависимости и задаёт DEPS_DIR, ORT_DIR, AIR_ONNX_BIN_DIR).
cmake_minimum_required(VERSION 3.17)
project(air_onnx LANGUAGES CXX)

set(DEPS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party" CACHE PATH "каталог зависимостей")
set(ORT_DIR "" CACHE PATH "распакованный onnxruntime-<os>-x64-<ver>")
set(AIR_ONNX_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../addons/air_onnx/bin" CACHE PATH "куда класть библиотеку")
set(GODOTCPP_TARGET template_release CACHE STRING "")

add_subdirectory("${DEPS_DIR}/godot-cpp" godot-cpp EXCLUDE_FROM_ALL)

add_library(air_onnx SHARED src/air_onnx.cpp src/register_types.cpp)
target_include_directories(air_onnx PRIVATE "${ORT_DIR}/include")
target_link_libraries(air_onnx PRIVATE godot::cpp)

# С ORT не компонуемся: библиотека грузится в рантайме (dlmopen/LoadLibrary) из каталога расширения,
# из неё берётся только C-символ OrtGetApiBase; C++-обёртка onnxruntime_cxx_api.h — заголовочная.
# Поэтому годится MSVC-сборка ORT под mingw (C ABI), а без ORT само расширение грузится (load() → код 4).
if(WIN32)
    target_link_options(air_onnx PRIVATE -static)
    set_target_properties(air_onnx PROPERTIES PREFIX "")
else()
    target_link_libraries(air_onnx PRIVATE ${CMAKE_DL_LIBS})
    target_link_options(air_onnx PRIVATE -static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL
        "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map")
    set_target_properties(air_onnx PROPERTIES LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/exports.map")
endif()

set_target_properties(air_onnx PROPERTIES
    CXX_STANDARD 17
    CXX_EXTENSIONS OFF
    CXX_VISIBILITY_PRESET hidden
    POSITION_INDEPENDENT_CODE ON
    LIBRARY_OUTPUT_DIRECTORY "$<1:${AIR_ONNX_BIN_DIR}>"
    RUNTIME_OUTPUT_DIRECTORY "$<1:${AIR_ONNX_BIN_DIR}>"
)
