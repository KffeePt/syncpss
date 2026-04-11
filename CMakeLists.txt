cmake_minimum_required(VERSION 3.16)

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/manifest.xml" SYNCPSS_MANIFEST_XML)
string(REGEX MATCH "<version>[ \t\r\n]*([0-9]+\\.[0-9]+\\.[0-9]+)[ \t\r\n]*</version>" _ "${SYNCPSS_MANIFEST_XML}")
if(NOT CMAKE_MATCH_1)
    message(FATAL_ERROR "Could not determine the syncpss version from manifest.xml")
endif()

project(syncpss VERSION "${CMAKE_MATCH_1}" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(SYNCPSS_ENABLE_CLANG_TIDY "Run clang-tidy during the build" OFF)

add_compile_options(
    -Wall
    -Wextra
    -Wpedantic
    -Wconversion
    -Wshadow
    -Wformat
    -Wformat-security
    -D_FORTIFY_SOURCE=2
    -fstack-protector-strong
    -fPIE
)

if(APPLE)
    add_link_options(-Wl,-bind_at_load)
elseif(UNIX)
    add_link_options(-pie -Wl,-z,relro,-z,now)
endif()

find_package(Curses REQUIRED)
find_package(nlohmann_json REQUIRED)

if(SYNCPSS_ENABLE_CLANG_TIDY)
    find_program(CLANG_TIDY_EXE NAMES clang-tidy)
    if(CLANG_TIDY_EXE)
        set(CMAKE_CXX_CLANG_TIDY ${CLANG_TIDY_EXE})
    endif()
endif()

add_executable(syncpss
    src/main.cpp
    src/tui/tui_core.cpp
    src/tui/tui_ui.cpp
    src/tui/tui_main_menu.cpp
    src/tui/password_helpers.cpp
    src/tui/password_browser.cpp
    src/tui/password_actions.cpp
    src/tui/tui_update.cpp
    src/tui/tui_setup_wizard.cpp
    src/tui/tui_configuration.cpp
    src/tui/tui_backup_container.cpp
    src/tui/tui_gpg_keys.cpp
    src/tui/tui_remote_keys.cpp
    src/tui/tui_sync.cpp
    src/tui/detail/common.cpp
    src/tui/detail/fingerprint.cpp
    src/tui/detail/gnupg.cpp
    src/tui/detail/backup_manifest.cpp
    src/tui/detail/release.cpp
    src/tui/detail/render.cpp
    src/tui/detail/browser.cpp
    src/store/store.cpp
    src/git/git.cpp
    src/ssh/ssh.cpp
    src/crypto/gpg.cpp
    src/crypto/veracrypt.cpp
    src/util/process.cpp
    src/util/paths.cpp
    src/util/clipboard_core.cpp
    src/util/clipboard_wsl_windows.cpp
    src/util/clipboard_lease.cpp
    src/util/config.cpp
    src/util/entry_metadata.cpp
    src/util/runtime_config.cpp
)

target_include_directories(syncpss PRIVATE src ${CURSES_INCLUDE_DIR})
target_link_libraries(syncpss PRIVATE ${CURSES_LIBRARIES} nlohmann_json::nlohmann_json)
target_compile_definitions(syncpss PRIVATE SYNCPSS_VERSION="${PROJECT_VERSION}")

add_executable(syncpss_install
    src/installer/linux/main_installer.cpp
    src/util/process.cpp
    src/util/paths.cpp
    src/util/config.cpp
    src/util/runtime_config.cpp
)

target_include_directories(syncpss_install PRIVATE src)
target_link_libraries(syncpss_install PRIVATE nlohmann_json::nlohmann_json)
target_compile_definitions(syncpss_install PRIVATE SYNCPSS_VERSION="${PROJECT_VERSION}")
set_target_properties(syncpss_install PROPERTIES OUTPUT_NAME install)

install(TARGETS syncpss syncpss_install DESTINATION /usr/local/bin)
