# Incremental iOS production-runtime compile check.
# This is deliberately not the game app: Win32 host, D3D12 renderer and XBE boot
# are still platform-specific and must not be represented as ported here.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "ios-game-runtime is an iOS-only target")
endif()

enable_language(OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_EXTENSIONS OFF)

# Include upstream SDL3 as a static dependency for the existing input subsystem.
include(FetchContent)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_RENDER OFF CACHE BOOL "" FORCE)
set(SDL_GPU OFF CACHE BOOL "" FORCE)
set(SDL_CAMERA OFF CACHE BOOL "" FORCE)
FetchContent_Declare(SDL3
    GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
    GIT_TAG release-3.4.16
    GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(SDL3)

add_library(MC3IOSRuntimeCompileCheck OBJECT
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/core/input.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/core/log.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/app/ios_touch_controls.mm")

target_include_directories(MC3IOSRuntimeCompileCheck PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime")
target_compile_options(MC3IOSRuntimeCompileCheck PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_link_libraries(MC3IOSRuntimeCompileCheck PRIVATE SDL3::SDL3-static
    "-framework UIKit" "-framework QuartzCore" "-framework Foundation")

set_target_properties(MC3IOSRuntimeCompileCheck PROPERTIES
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "13.0")
