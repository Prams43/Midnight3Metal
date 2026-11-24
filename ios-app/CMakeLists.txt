cmake_minimum_required(VERSION 3.25)

# This target must be configured with CMAKE_SYSTEM_NAME=iOS
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "ios-app/ target requires CMAKE_SYSTEM_NAME=iOS")
endif()

# Enable Objective-C++
enable_language(OBJCXX)

# Set language standards
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# iOS app executable
add_executable(MC3iOSApp MACOSX_BUNDLE
    "${CMAKE_CURRENT_LIST_DIR}/main.mm"
    "${CMAKE_CURRENT_LIST_DIR}/AppDelegate.mm"
    "${CMAKE_CURRENT_LIST_DIR}/ViewController.mm"
    "${CMAKE_CURRENT_LIST_DIR}/MetalRenderer.mm"
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/core/input.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/core/log.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/app/ios_touch_controls.mm"
)

# Include directories for runtime headers
target_include_directories(MC3iOSApp PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime"
)

# Enable ARC for Objective-C++ sources
set_target_properties(MC3iOSApp PROPERTIES
    OBJCXX_ARC_ENABLED YES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/Info.plist"
    MACOSX_BUNDLE_BUNDLE_NAME "MC3 Remix"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.mc3remix.ios"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.mc3remix.ios"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "13.0"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "iPhone Developer"
)

# Fetch SDL3 static library (matches version from ios-game-runtime)
include(FetchContent)
FetchContent_Declare(
    SDL3
    GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
    GIT_TAG release-3.4.16
    GIT_SHALLOW TRUE
)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(SDL3)

# Link SDL3 and iOS frameworks
target_link_libraries(MC3iOSApp PRIVATE
    SDL3::SDL3-static
    "-framework UIKit"
    "-framework Foundation"
    "-framework QuartzCore"
    "-framework Metal"
)
