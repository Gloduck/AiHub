@echo off

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "ENV_FILE="
set "VERBOSE=0"
set "LOAD_COUNT=0"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--file" (
  if "%~2"=="" goto arg_value_error
  set "ENV_FILE=%~2"
  shift
  shift
  goto parse_args
)
if /i "%~1"=="--verbose" (
  set "VERBOSE=1"
  shift
  goto parse_args
)
if /i "%~1"=="--help" goto usage
if /i "%~1"=="-h" goto usage
echo [ERROR] unknown argument: %~1 1>&2
exit /b 1

:arg_value_error
echo [ERROR] --file requires a value 1>&2
exit /b 1

:args_done
if not defined ENV_FILE call :resolve_default_env_file
if not defined ENV_FILE (
  echo [ERROR] env.ini not found in script directory or current working directory 1>&2
  exit /b 1
)

for %%I in ("%ENV_FILE%") do set "ENV_FILE=%%~fI"
if not exist "%ENV_FILE%" (
  echo [ERROR] env file not found: %ENV_FILE% 1>&2
  exit /b 1
)

if "%VERBOSE%"=="1" echo [DEBUG] loading env file: %ENV_FILE% 1>&2
call :load_env_file
if errorlevel 1 exit /b 1
echo [INFO] loaded %LOAD_COUNT% variables from %ENV_FILE% 1>&2
exit /b 0

:usage
echo Usage: load_env.bat [--file PATH] [--verbose]
echo.
echo Purpose:
echo   Load KEY=VALUE entries from env.ini into the current cmd environment.
echo.
echo Optional inputs:
echo   --file     custom env.ini path
echo   --verbose  print debug logs
echo   --help     show this message
echo.
echo Default env.ini lookup order when --file is omitted:
echo   1. script directory\env.ini
echo   2. current working directory\env.ini
echo.
echo Supported file format:
echo   - one KEY=VALUE entry per line
echo   - each line must contain exactly one =
echo   - value is loaded as-is
echo.
echo Notes:
echo   Use this script in cmd.exe. If called from another batch file, use: call load_env.bat
exit /b 0

:resolve_default_env_file
if exist "%SCRIPT_DIR%\env.ini" set "ENV_FILE=%SCRIPT_DIR%\env.ini"
if not defined ENV_FILE if exist "%CD%\env.ini" set "ENV_FILE=%CD%\env.ini"
exit /b 0

:load_env_file
set "LOAD_COUNT=0"
for /f "usebackq delims=" %%L in ("%ENV_FILE%") do (
  call :process_line "%%L"
  if errorlevel 1 exit /b 1
)
exit /b 0

:process_line
set "LINE=%~1"
if not defined LINE exit /b 0

set "KEY="
set "VALUE="
for /f "tokens=1* delims==" %%A in ("%LINE%") do (
  set "KEY=%%A"
  set "VALUE=%%B"
)

if not defined KEY (
  echo [ERROR] invalid line in env file: %LINE% 1>&2
  exit /b 1
)

if "%LINE%"=="%KEY%" if not "%LINE:~-1%"=="=" (
  echo [ERROR] invalid line in env file: %LINE% 1>&2
  exit /b 1
)

echo(%VALUE%| findstr "=" >nul
if not errorlevel 1 (
  echo [ERROR] invalid line in env file: %LINE% 1>&2
  exit /b 1
)

echo(%KEY%| findstr /r "^[A-Za-z_][A-Za-z0-9_]*$" >nul
if errorlevel 1 (
  echo [ERROR] invalid env name: %KEY% 1>&2
  exit /b 1
)

set "%KEY%=%VALUE%"
set /a LOAD_COUNT+=1
if "%VERBOSE%"=="1" echo [DEBUG] loaded %KEY% 1>&2
set "KEY="
set "VALUE="
exit /b 0
