if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "ios-memory-probe is an iOS-only target")
endif()

enable_language(OBJCXX)

set_source_files_properties(
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/kernel/ios_memory_probe.mm"
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/kernel/ios_memory_probe_app.mm"
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_EXTENSIONS OFF)

add_executable(MC3MemoryProbe MACOSX_BUNDLE
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/kernel/ios_memory_probe.mm"
    "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/kernel/ios_memory_probe_app.mm")

set_target_properties(MC3MemoryProbe PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER "org.mc3remix.memoryprobe"
    MACOSX_BUNDLE_BUNDLE_NAME "MC3 Memory Probe"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/../sdk/runtime/kernel/ios_memory_probe-Info.plist"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "13.0")

target_link_libraries(MC3MemoryProbe PRIVATE "-framework UIKit" "-framework Foundation")
