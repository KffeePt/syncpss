@echo off
setlocal EnableExtensions
set "NO_PAUSE=%SYNCPS_NO_PAUSE%"
set "EXIT_CODE=1"
for %%I in ("%~f0") do set "SCRIPT_DIR=%%~dpI"
for %%I in ("%SCRIPT_DIR%..") do set "REPO_ROOT=%%~fI"

:parse_args
if "%~1"=="" goto :args_done
if /I "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
)
shift
goto :parse_args

:args_done

cd /d "%REPO_ROOT%"
if errorlevel 1 (
    echo [FAIL] Could not switch to repo root.
    goto :fail
)

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ps1\generate_windows_icon.ps1" -RepoRoot "%REPO_ROOT%"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" goto :fail

echo.
echo [OK] Windows icon assets refreshed successfully.
if /I not "%NO_PAUSE%"=="1" pause
exit /b 0

:fail
echo.
echo [FAIL] Icon update exited with code %EXIT_CODE%.
if /I not "%NO_PAUSE%"=="1" pause
exit /b %EXIT_CODE%
