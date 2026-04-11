@echo off
setlocal EnableExtensions
set "NO_PAUSE=%SYNCPS_NO_PAUSE%"
set "FORWARD_ARGS="
for %%I in ("%~f0") do set "SCRIPT_DIR=%%~dpI"

:parse_args
if "%~1"=="" goto :args_done
if /I "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
) else (
    set "FORWARD_ARGS=%FORWARD_ARGS% "%~1""
)
shift
goto :parse_args

:args_done

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ps1\set_fingerprint.ps1" %FORWARD_ARGS%
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if "%EXIT_CODE%"=="0" (
    echo [OK] Maintainer ID manager closed.
) else (
    echo [FAIL] Maintainer ID manager exited with code %EXIT_CODE%.
)
if /I not "%NO_PAUSE%"=="1" pause
exit /b %EXIT_CODE%
