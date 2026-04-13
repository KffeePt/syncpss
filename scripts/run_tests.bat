@echo off
setlocal EnableExtensions

set "NO_PAUSE=%SYNCPS_NO_PAUSE%"
set "FORWARD_ARGS="
set "EXIT_CODE=1"
set "PYTHON_EXE="
set "PYTHON_ARGS="

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

for %%I in ("%SCRIPT_DIR%..") do set "REPO_ROOT=%%~fI"

for /f "delims=" %%I in ('where py 2^>nul') do (
    set "PYTHON_EXE=%%~fI"
    set "PYTHON_ARGS=-3"
    goto :python_found
)

for /f "delims=" %%I in ('where python 2^>nul') do (
    set "PYTHON_EXE=%%~fI"
    goto :python_found
)

echo [FAIL] Could not find py or python on PATH.
goto :fail

:python_found

cd /d "%REPO_ROOT%"
if errorlevel 1 (
    echo [FAIL] Could not switch to repo root.
    goto :fail
)

"%PYTHON_EXE%" %PYTHON_ARGS% "%REPO_ROOT%\tests\run.py" %FORWARD_ARGS%
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" goto :fail

echo.
echo [OK] Test runner finished successfully.
if /I not "%NO_PAUSE%"=="1" pause
exit /b 0

:fail
echo.
echo [FAIL] Test runner exited with code %EXIT_CODE%.
if /I not "%NO_PAUSE%"=="1" pause
exit /b %EXIT_CODE%
