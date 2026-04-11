@echo off
setlocal EnableExtensions
set "NO_PAUSE=%SYNCPS_NO_PAUSE%"
set "PS_EXTRA_ARGS="
set "FORWARD_ARGS="
for %%I in ("%~f0") do set "SCRIPT_DIR=%%~dpI"

:parse_args
if "%~1"=="" goto :args_done
if /I "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
    set "PS_EXTRA_ARGS=%PS_EXTRA_ARGS% -NonInteractive"
) else if /I "%~1"=="--no-batch-pause" (
    set "NO_PAUSE=1"
) else if /I "%~1"=="--run-now" (
    set "PS_EXTRA_ARGS=%PS_EXTRA_ARGS% -RunNow"
 ) else if /I "%~1"=="--assume-yes" (
    set "PS_EXTRA_ARGS=%PS_EXTRA_ARGS% -AssumeYes"
) else if /I "%~1"=="--purge-windows-shortcut" (
    set "PS_EXTRA_ARGS=%PS_EXTRA_ARGS% -PurgeWindowsShortcut"
) else (
    set "FORWARD_ARGS=%FORWARD_ARGS% "%~1""
)
shift
goto :parse_args

:args_done

for %%I in ("%SCRIPT_DIR%..") do set "REPO_ROOT=%%~fI"

cd /d "%REPO_ROOT%"
if errorlevel 1 (
    echo [FAIL] Could not switch to repo root.
    goto :fail
)

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ps1\purge.ps1" %PS_EXTRA_ARGS% %FORWARD_ARGS%
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" goto :fail

echo.
echo [OK] Purge helper finished.
if /I not "%NO_PAUSE%"=="1" pause
exit /b 0

:fail
echo.
echo [FAIL] Purge helper exited with code %EXIT_CODE%.
if /I not "%NO_PAUSE%"=="1" pause
exit /b %EXIT_CODE%
