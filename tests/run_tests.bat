@echo off
REM ============================================================
REM MOTE P0 - run all headless tests (ASCII only, no CJK)
REM Project root is derived from THIS file's location, so the file
REM can be double-clicked in Explorer or run from any directory.
REM
REM Usage:
REM   tests\run_tests.bat              run all suites + probes
REM   tests\run_tests.bat test_save    run one suite
REM   set GODOT=C:\path\Godot.exe      override engine path
REM ============================================================
setlocal

if "%GODOT%"=="" set GODOT=C:\Users\lynn_\Godot\Godot.exe
rem strip eventual quotes coming from the env var
set GODOT=%GODOT:"=%

rem project root = parent directory of this .bat, fully qualified
for %%I in ("%~dp0..") do set PROJECT_DIR=%%~fI

if not exist "%PROJECT_DIR%\project.godot" (
    echo [ERROR] project.godot not found. PROJECT_DIR="%PROJECT_DIR%"
    exit /b 2
)
if not exist "%GODOT%" (
    echo [ERROR] Godot executable not found: "%GODOT%"
    echo         Set GODOT first, e.g.:
    echo         set GODOT=C:\Users\you\Godot\Godot.exe
    exit /b 3
)

echo Godot   : "%GODOT%"
echo Project : "%PROJECT_DIR%"
echo.

set FAILED=0

if not "%~1"=="" goto :single

set TESTS=test_simulation test_animation test_save test_app_smoke
for %%t in (%TESTS%) do (
    echo === %%t ===
    "%GODOT%" --headless --path "%PROJECT_DIR%" --script res://tests/unit/%%t.gd
    if errorlevel 1 (
        echo [FAILED] %%t
        set FAILED=1
    )
    echo.
)

echo === probes: environment evidence, not pass/fail ===
for %%p in (probe_anim probe_window probe_tray probe_skeleton) do (
    "%GODOT%" --headless --path "%PROJECT_DIR%" --script res://tests/probe/%%p.gd
    echo.
)
goto :result

:single
echo === %~1 ===
"%GODOT%" --headless --path "%PROJECT_DIR%" --script res://tests/unit/%~1.gd
if errorlevel 1 (
    echo [FAILED] %~1
    set FAILED=1
)

:result
if "%FAILED%"=="1" (
    echo RESULT: SOME TESTS FAILED
    exit /b 1
)
echo RESULT: ALL TESTS PASSED
exit /b 0
