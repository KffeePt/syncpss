@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "NO_PAUSE=%SYNCPS_NO_PAUSE%"
set "PS_EXTRA_ARGS="
set "FORWARD_ARGS="
set "BUILD_TUI=1"
set "BUILD_LINUX_INSTALLER=1"
set "BUILD_WINDOWS_INSTALLER=1"
set "SKIP_LINUX_INSTALLER=0"
set "EXIT_CODE=1"
set "RUN_INSTALLER_PROMPT=0"
for %%I in ("%~f0") do set "SCRIPT_DIR=%%~dpI"

:parse_args
if "%~1"=="" goto :args_done
if /I "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
    set "PS_EXTRA_ARGS=%PS_EXTRA_ARGS% -NonInteractive"
    shift
    goto :parse_args
) else if /I "%~1"=="--tui-only" (
    set "BUILD_TUI=1"
    set "BUILD_LINUX_INSTALLER=0"
    set "BUILD_WINDOWS_INSTALLER=0"
) else if /I "%~1"=="--installer-only" (
    set "BUILD_TUI=0"
    set "BUILD_LINUX_INSTALLER=1"
    set "BUILD_WINDOWS_INSTALLER=1"
) else if /I "%~1"=="--skip-linux-installer" (
    set "SKIP_LINUX_INSTALLER=1"
) else (
    set "FORWARD_ARGS=%FORWARD_ARGS% "%~1""
)
shift
goto :parse_args

:args_done

for %%I in ("%SCRIPT_DIR%..") do set "REPO_ROOT=%%~fI"
set "WIN_INSTALLER_DIR=%REPO_ROOT%\src\installer\win"
set "BIN_DIR=%REPO_ROOT%\bin"
set "OUT_EXE=%BIN_DIR%\syncpss-wsl-installer.exe"
set "OUT_SHA=%BIN_DIR%\syncpss-wsl-installer.exe.sha256"
set "OUT_HELPER=%BIN_DIR%\installer.sh"
set "OUT_HELPER_SHA=%BIN_DIR%\installer.sh.sha256"
set "OUT_MANAGED_HELPER=%BIN_DIR%\managed_paths.sh"
set "OUT_MANAGED_HELPER_SHA=%BIN_DIR%\managed_paths.sh.sha256"
set "OUT_MAINTAINER_HELPER=%BIN_DIR%\maintainer_id.sh"
set "OUT_UNINSTALL=%BIN_DIR%\uninstall_syncpss.sh"
set "OUT_UNINSTALL_SHA=%BIN_DIR%\uninstall_syncpss.sh.sha256"
set "ICON_HELPER=%SCRIPT_DIR%ps1\generate_windows_icon.ps1"
set "FINGERPRINT_HELPER=%SCRIPT_DIR%ps1\update_master_fingerprint.ps1"
set "TEMP_EXE=%TEMP%\syncpss-wsl-installer-%RANDOM%%RANDOM%.exe"
set "SLEEP_CMD=powershell -NoLogo -NoProfile -Command Start-Sleep -Seconds"

cd /d "%REPO_ROOT%"
if errorlevel 1 (
    echo [FAIL] Could not switch to repo root.
    goto :fail
)

if not exist "%BIN_DIR%" mkdir "%BIN_DIR%"

if "%BUILD_TUI%"=="1" (
    echo [1/2] Building Linux syncpss TUI artifact...
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ps1\build.ps1" -BuildHost wsl -Target tui %PS_EXTRA_ARGS% %FORWARD_ARGS%
    set "EXIT_CODE=!ERRORLEVEL!"
    if not "!EXIT_CODE!"=="0" goto :fail
    echo.
    echo [OK] Linux syncpss TUI artifact finished.
)

if "%BUILD_LINUX_INSTALLER%"=="1" if not "%SKIP_LINUX_INSTALLER%"=="1" (
    if "%BUILD_TUI%"=="1" echo.
    echo [2/2] Building Linux installer artifacts...
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ps1\build.ps1" -BuildHost wsl -Target installer %PS_EXTRA_ARGS% %FORWARD_ARGS%
    set "EXIT_CODE=!ERRORLEVEL!"
    if not "!EXIT_CODE!"=="0" goto :fail
)

if "%BUILD_WINDOWS_INSTALLER%"=="1" (
    echo.
    echo Checking for running syncpss-wsl-installer.exe instances...
    taskkill /F /IM syncpss-wsl-installer.exe >nul 2>nul
    powershell -NoLogo -NoProfile -Command ^
      "$ErrorActionPreference='SilentlyContinue'; Get-Process syncpss-wsl-installer -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { try { $_.Kill() } catch {} } }"
    %SLEEP_CMD% 1 >nul

    if exist "C:\ProgramData\mingw64\mingw64\bin\g++.exe" set "PATH=C:\ProgramData\mingw64\mingw64\bin;%PATH%"
    if exist "C:\msys64\mingw64\bin\g++.exe" set "PATH=C:\msys64\mingw64\bin;%PATH%"

    where g++ >nul 2>nul
    if errorlevel 1 (
        set "EXIT_CODE=1"
        echo [FAIL] g++ not found in PATH.
        echo Install MinGW-w64 or another g++ toolchain, then rerun this script.
        goto :fail
    )

    if not exist "%WIN_INSTALLER_DIR%\main.cpp" (
        set "EXIT_CODE=1"
        echo [FAIL] Installer source not found under: %WIN_INSTALLER_DIR%
        goto :fail
    )

    if not exist "%REPO_ROOT%\scripts\sh\installer.sh" (
        set "EXIT_CODE=1"
        echo [FAIL] Helper installer source not found: %REPO_ROOT%\scripts\sh\installer.sh
        goto :fail
    )

    if not exist "%REPO_ROOT%\scripts\sh\maintainer_id.sh" (
        set "EXIT_CODE=1"
        echo [FAIL] Helper maintainer source not found: %REPO_ROOT%\scripts\sh\maintainer_id.sh
        goto :fail
    )

    if not exist "%REPO_ROOT%\scripts\sh\managed_paths.sh" (
        set "EXIT_CODE=1"
        echo [FAIL] Helper managed-path source not found: %REPO_ROOT%\scripts\sh\managed_paths.sh
        goto :fail
    )

    if not exist "%REPO_ROOT%\scripts\sh\uninstall_syncpss.sh" (
        set "EXIT_CODE=1"
        echo [FAIL] Helper uninstall source not found: %REPO_ROOT%\scripts\sh\uninstall_syncpss.sh
        goto :fail
    )

    if "%SKIP_LINUX_INSTALLER%"=="1" (
        echo.
        echo Skipping Linux installer artifact build.
    ) else if "%BUILD_LINUX_INSTALLER%"=="0" (
        echo.
        echo [2/2] Building Linux installer artifacts...
        powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ps1\build.ps1" -BuildHost wsl -Target installer %PS_EXTRA_ARGS% %FORWARD_ARGS%
        set "EXIT_CODE=!ERRORLEVEL!"
        if not "!EXIT_CODE!"=="0" goto :fail
    )

    echo.
    echo Building Windows WSL installer...
    g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -municode ^
      -static -static-libgcc -static-libstdc++ ^
      "%WIN_INSTALLER_DIR%\main.cpp" ^
      "%WIN_INSTALLER_DIR%\console.cpp" ^
      "%WIN_INSTALLER_DIR%\process.cpp" ^
      "%WIN_INSTALLER_DIR%\system_paths.cpp" ^
      "%WIN_INSTALLER_DIR%\distro.cpp" ^
      "%WIN_INSTALLER_DIR%\assets.cpp" ^
      "%WIN_INSTALLER_DIR%\shortcuts.cpp" ^
      "%WIN_INSTALLER_DIR%\wsl_stage.cpp" ^
      -o "%TEMP_EXE%" ^
      -lbcrypt -lshell32 -lurlmon
    if errorlevel 1 (
        set "EXIT_CODE=!ERRORLEVEL!"
        echo [FAIL] Installer build failed.
        goto :fail
    )

    set "COPY_OK=0"
    for /L %%N in (1,1,8) do (
        if exist "%OUT_EXE%" del /f /q "%OUT_EXE%" >nul 2>nul
        copy /Y "%TEMP_EXE%" "%OUT_EXE%" >nul 2>nul
        if not errorlevel 1 (
            set "COPY_OK=1"
            goto :copy_done
        )
        echo Waiting for installer executable lock to clear... attempt %%N/8
        taskkill /F /IM syncpss-wsl-installer.exe >nul 2>nul
        powershell -NoLogo -NoProfile -Command ^
          "$ErrorActionPreference='SilentlyContinue'; Get-Process syncpss-wsl-installer -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { try { $_.Kill() } catch {} } }"
        %SLEEP_CMD% 1 >nul
    )
    :copy_done
    if not "%COPY_OK%"=="1" (
        set "EXIT_CODE=1"
        echo [FAIL] Could not replace %OUT_EXE% after polling for the file lock.
        echo Close any elevated syncpss-wsl-installer.exe windows and try again.
        goto :fail
    )

    del /f /q "%TEMP_EXE%" >nul 2>nul

    powershell -NoLogo -NoProfile -Command ^
      "$ErrorActionPreference='Stop'; $sha=[System.Security.Cryptography.SHA256]::Create(); try { $stream=[System.IO.File]::OpenRead('%OUT_EXE%'); try { $hashBytes=$sha.ComputeHash($stream) } finally { $stream.Dispose() } } finally { $sha.Dispose() }; $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant(); [System.IO.File]::WriteAllText('%OUT_SHA%', $hash + '  syncpss-wsl-installer.exe')"
    if errorlevel 1 (
        set "EXIT_CODE=!ERRORLEVEL!"
        echo [FAIL] Failed to write installer checksum.
        goto :fail
    )

    powershell -NoLogo -NoProfile -Command ^
      "$ErrorActionPreference='Stop'; $content=[System.IO.File]::ReadAllText('%REPO_ROOT%\scripts\sh\installer.sh').Replace(\"`r`n\", \"`n\").Replace(\"`r\", \"`n\"); [System.IO.File]::WriteAllText('%OUT_HELPER%', $content, [System.Text.UTF8Encoding]::new($false))"
    if errorlevel 1 (
        set "EXIT_CODE=!ERRORLEVEL!"
        echo [FAIL] Failed to copy installer.sh into bin.
        goto :fail
    )

    powershell -NoLogo -NoProfile -Command ^
      "$ErrorActionPreference='Stop'; $sha=[System.Security.Cryptography.SHA256]::Create(); try { $stream=[System.IO.File]::OpenRead('%OUT_HELPER%'); try { $hashBytes=$sha.ComputeHash($stream) } finally { $stream.Dispose() } } finally { $sha.Dispose() }; $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant(); [System.IO.File]::WriteAllText('%OUT_HELPER_SHA%', $hash + '  installer.sh')"
    if errorlevel 1 (
        set "EXIT_CODE=!ERRORLEVEL!"
        echo [FAIL] Failed to write installer.sh checksum.
        goto :fail
    )

    powershell -NoLogo -NoProfile -Command ^
      "$ErrorActionPreference='Stop'; $content=[System.IO.File]::ReadAllText('%REPO_ROOT%\scripts\sh\maintainer_id.sh').Replace(\"`r`n\", \"`n\").Replace(\"`r\", \"`n\"); [System.IO.File]::WriteAllText('%OUT_MAINTAINER_HELPER%', $content, [System.Text.UTF8Encoding]::new($false))"
    if errorlevel 1 (
        set "EXIT_CODE=!ERRORLEVEL!"
        echo [FAIL] Failed to copy maintainer_id.sh into bin.
        goto :fail
    )

    powershell -NoLogo -NoProfile -Command ^
      "$ErrorActionPreference='Stop'; $content=[System.IO.File]::ReadAllText('%REPO_ROOT%\scripts\sh\managed_paths.sh').Replace(\"`r`n\", \"`n\").Replace(\"`r\", \"`n\"); [System.IO.File]::WriteAllText('%OUT_MANAGED_HELPER%', $content, [System.Text.UTF8Encoding]::new($false))"
    if errorlevel 1 (
        set "EXIT_CODE=!ERRORLEVEL!"
        echo [FAIL] Failed to copy managed_paths.sh into bin.
        goto :fail
    )

    powershell -NoLogo -NoProfile -Command ^
      "$ErrorActionPreference='Stop'; $sha=[System.Security.Cryptography.SHA256]::Create(); try { $stream=[System.IO.File]::OpenRead('%OUT_MANAGED_HELPER%'); try { $hashBytes=$sha.ComputeHash($stream) } finally { $stream.Dispose() } } finally { $sha.Dispose() }; $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant(); [System.IO.File]::WriteAllText('%OUT_MANAGED_HELPER_SHA%', $hash + '  managed_paths.sh')"
    if errorlevel 1 (
        set "EXIT_CODE=!ERRORLEVEL!"
        echo [FAIL] Failed to write managed_paths.sh checksum.
        goto :fail
    )

    powershell -NoLogo -NoProfile -Command ^
      "$ErrorActionPreference='Stop'; $content=[System.IO.File]::ReadAllText('%REPO_ROOT%\scripts\sh\uninstall_syncpss.sh').Replace(\"`r`n\", \"`n\").Replace(\"`r\", \"`n\"); [System.IO.File]::WriteAllText('%OUT_UNINSTALL%', $content, [System.Text.UTF8Encoding]::new($false))"
    if errorlevel 1 (
        set "EXIT_CODE=!ERRORLEVEL!"
        echo [FAIL] Failed to copy uninstall_syncpss.sh into bin.
        goto :fail
    )

    powershell -NoLogo -NoProfile -Command ^
      "$ErrorActionPreference='Stop'; $sha=[System.Security.Cryptography.SHA256]::Create(); try { $stream=[System.IO.File]::OpenRead('%OUT_UNINSTALL%'); try { $hashBytes=$sha.ComputeHash($stream) } finally { $stream.Dispose() } } finally { $sha.Dispose() }; $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant(); [System.IO.File]::WriteAllText('%OUT_UNINSTALL_SHA%', $hash + '  uninstall_syncpss.sh')"
    if errorlevel 1 (
        set "EXIT_CODE=!ERRORLEVEL!"
        echo [FAIL] Failed to write uninstall_syncpss.sh checksum.
        goto :fail
    )

    echo [OK] Built:
    echo   %OUT_EXE%
    echo   %OUT_SHA%
    echo   %OUT_HELPER%
    echo   %OUT_HELPER_SHA%
    echo   %OUT_MANAGED_HELPER%
    echo   %OUT_MANAGED_HELPER_SHA%
    echo   %OUT_MAINTAINER_HELPER%
    echo   %OUT_UNINSTALL%
    echo   %OUT_UNINSTALL_SHA%
    set "RUN_INSTALLER_PROMPT=1"
)

if exist "%ICON_HELPER%" (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ICON_HELPER%" -RepoRoot "%REPO_ROOT%"
    set "EXIT_CODE=!ERRORLEVEL!"
    if not "!EXIT_CODE!"=="0" goto :fail
)

set "EXIT_CODE=0"
if exist "%FINGERPRINT_HELPER%" (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%FINGERPRINT_HELPER%" -RepoRoot "%REPO_ROOT%" -SkipIfUnavailable
    set "EXIT_CODE=!ERRORLEVEL!"
    if not "!EXIT_CODE!"=="0" goto :fail
)
echo.
echo [OK] Build completed successfully.
if /I not "%NO_PAUSE%"=="1" if "%RUN_INSTALLER_PROMPT%"=="1" (
    set /p "RUN_INSTALLER=Press Enter to run the WSL installer now, or type N to skip: "
    if /I not "!RUN_INSTALLER!"=="N" (
        start "" "%OUT_EXE%"
    )
)
if /I not "%NO_PAUSE%"=="1" pause
exit /b 0

:fail
if exist "%TEMP_EXE%" del /f /q "%TEMP_EXE%" >nul 2>nul
echo.
echo [FAIL] Build exited with code %EXIT_CODE%.
if /I not "%NO_PAUSE%"=="1" pause
exit /b %EXIT_CODE%
