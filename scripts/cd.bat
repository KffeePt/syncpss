@echo off
setlocal EnableExtensions
set "NO_PAUSE=%SYNCPS_NO_PAUSE%"
set "FORWARD_ARGS="
set "SIGNING_READINESS="
for %%I in ("%~f0") do set "SCRIPT_DIR=%%~dpI"

:parse_args
if "%~1"=="" goto :args_done
if /I "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
    set "FORWARD_ARGS=%FORWARD_ARGS% -NonInteractive"
) else if /I "%~1"=="--signing-readiness" (
    set "SIGNING_READINESS=1"
    set "FORWARD_ARGS=%FORWARD_ARGS% -SigningReadiness"
) else (
    set "FORWARD_ARGS=%FORWARD_ARGS% "%~1""
)
shift
goto :parse_args

:args_done

for %%I in ("%SCRIPT_DIR%..") do set "REPO_ROOT=%%~fI"

cd /d "%REPO_ROOT%"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
    echo [FAIL] Could not switch to repo root.
    goto :fail
)

set "MAINTAINER_ARGS="
if /I "%NO_PAUSE%"=="1" (
    set "MAINTAINER_ARGS=-NonInteractive"
)

if defined SIGNING_READINESS goto :run_release

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ps1\ensure_maintainer_id.ps1" -RepoRoot "%REPO_ROOT%" %MAINTAINER_ARGS%
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" goto :fail

:run_release
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%ps1\release.ps1" %FORWARD_ARGS%
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" goto :fail

echo.
echo [OK] Deployment script finished.
if /I not "%NO_PAUSE%"=="1" pause
exit /b 0

:fail
echo.
echo [FAIL] Deployment exited with code %EXIT_CODE%.
if /I not "%NO_PAUSE%"=="1" pause
exit /b %EXIT_CODE%
