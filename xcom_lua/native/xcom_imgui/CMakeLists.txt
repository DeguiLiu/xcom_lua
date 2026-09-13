cmake_minimum_required(VERSION 3.21)
project(xcom_imgui LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(IMGUI_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/xcom_imgui/imgui)
set(IMPLOT_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/xcom_imgui/implot)
set(XCOM_REFERENCE_FONTS_DIR "D:/workspace/SSCOM/xcom_client/resources/fonts" CACHE PATH
    "Directory containing SiemensSlabRoman.ttf and SiemensSlabBold.TTF")
set(XCOM_LUA_RUNTIME_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../.." CACHE PATH
    "Lua client runtime directory that receives bundled UI assets")
add_library(xcom_imgui SHARED
    ${IMGUI_ROOT}/imgui.cpp
    ${IMGUI_ROOT}/imgui_draw.cpp
    ${IMGUI_ROOT}/imgui_tables.cpp
    ${IMGUI_ROOT}/imgui_widgets.cpp
    ${IMGUI_ROOT}/imgui_impl_win32.cpp
    ${IMGUI_ROOT}/imgui_impl_dx11.cpp
    ${IMPLOT_ROOT}/implot.cpp
    ${IMPLOT_ROOT}/implot_items.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/xcom_imgui_bridge.cpp
)

target_include_directories(xcom_imgui PRIVATE
    ${IMGUI_ROOT}
    ${IMPLOT_ROOT}
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_definitions(xcom_imgui PRIVATE WIN32_LEAN_AND_MEAN)
if(MSVC)
    # /W4 added for the same reason as xcom_core: this target compiles code and
    # owns its own warning level. Deliberately no /WX (no Windows CI runs MSVC
    # here, so a fatal warning is an unverifiable build break) and no
    # /GR- /EHs-c- (the ABI this bridge links uses try/catch; /EHsc stays).
    # /utf-8: the bridge sources contain UTF-8 comments (em-dash, middle dot).
    # Without it MSVC decodes them as CP936 and emits C4819, which can
    # misparse a trailing byte as a line-continuation backslash.
    target_compile_options(xcom_imgui PRIVATE /W4 /EHsc /utf-8)
endif()
target_link_libraries(xcom_imgui PRIVATE d3d11 dxgi gdi32 user32 imm32)
set_target_properties(xcom_imgui PROPERTIES PREFIX "")

foreach(font_file IN ITEMS SiemensSlabRoman.ttf SiemensSlabBold.TTF)
    if(EXISTS "${XCOM_REFERENCE_FONTS_DIR}/${font_file}")
        add_custom_command(TARGET xcom_imgui POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E make_directory
                    "${XCOM_LUA_RUNTIME_DIR}/assets/fonts"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${XCOM_REFERENCE_FONTS_DIR}/${font_file}"
                    "${XCOM_LUA_RUNTIME_DIR}/assets/fonts/${font_file}"
            VERBATIM)
    else()
        message(WARNING "Siemens font not found: ${XCOM_REFERENCE_FONTS_DIR}/${font_file}. Falling back to Segoe UI.")
    endif()
endforeach()

add_custom_command(TARGET xcom_imgui POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
            "${XCOM_LUA_RUNTIME_DIR}/assets"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_SOURCE_DIR}/layout.toml"
            "${XCOM_LUA_RUNTIME_DIR}/assets/layout.toml"
    VERBATIM)
