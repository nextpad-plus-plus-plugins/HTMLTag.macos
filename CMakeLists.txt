cmake_minimum_required(VERSION 3.20)
project(HTMLTag VERSION 1.5.6 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Host plugin interface + Scintilla (read-only; NO host changes)
set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")
set(SCINTILLA_INCLUDE  "${NPP_MACOS_DIR}/scintilla/include")

add_library(HTMLTag SHARED src/HTMLTag.mm)
target_include_directories(HTMLTag PRIVATE ${NPP_PLUGIN_INCLUDE} ${SCINTILLA_INCLUDE})
target_link_libraries(HTMLTag PRIVATE "-framework Cocoa")
target_compile_options(HTMLTag PRIVATE
    -Wall -Wno-unused-parameter -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(HTMLTag PROPERTIES PREFIX "" SUFFIX ".dylib")
target_link_options(HTMLTag PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")

# Install (real plugins dir). Toolbar PNGs live at the plugin root (host looks
# there first); the entities INI ships in resources/.
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/HTMLTag")
install(TARGETS HTMLTag DESTINATION "${PLUGIN_INSTALL_DIR}")
install(FILES "${CMAKE_SOURCE_DIR}/toolbar.png" "${CMAKE_SOURCE_DIR}/toolbar_dark.png"
        DESTINATION "${PLUGIN_INSTALL_DIR}")
install(FILES "${CMAKE_SOURCE_DIR}/resources/HTMLTag-entities.ini"
        DESTINATION "${PLUGIN_INSTALL_DIR}/resources")
