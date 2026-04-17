@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "ENV_NAME="
set "VERSION="
set "ARCH="
set "INSTALL_DIR="
set "FORCE=0"
set "NO_PROFILE="
set "NO_PROFILE_SPECIFIED=0"
set "INTERACTIVE=0"
set "CONFIG_PATH=%SCRIPT_DIR%\install_env_sources.json"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--env" (
  if "%~2"=="" goto arg_value_error
  set "ENV_NAME=%~2"
  shift
  shift
  goto parse_args
)
if /i "%~1"=="--version" (
  if "%~2"=="" goto arg_value_error
  set "VERSION=%~2"
  shift
  shift
  goto parse_args
)
if /i "%~1"=="--install-dir" (
  if "%~2"=="" goto arg_value_error
  set "INSTALL_DIR=%~2"
  shift
  shift
  goto parse_args
)
if /i "%~1"=="--arch" (
  if "%~2"=="" goto arg_value_error
  set "ARCH=%~2"
  shift
  shift
  goto parse_args
)
if /i "%~1"=="--config" (
  if "%~2"=="" goto arg_value_error
  set "CONFIG_PATH=%~2"
  shift
  shift
  goto parse_args
)
if /i "%~1"=="--force" (
  set "FORCE=1"
  shift
  goto parse_args
)
if /i "%~1"=="--no-profile" (
  set "NO_PROFILE=1"
  set "NO_PROFILE_SPECIFIED=1"
  shift
  goto parse_args
)
if /i "%~1"=="--help" goto usage

echo [ERROR] unknown argument: %~1
exit /b 1

:arg_value_error
echo [ERROR] %~1 requires a value
exit /b 1

:args_done
for %%I in ("%CONFIG_PATH%") do set "CONFIG_PATH=%%~fI"
if not exist "%CONFIG_PATH%" (
  echo [ERROR] config file not found: %CONFIG_PATH%
  exit /b 1
)

call :detect_arch
if errorlevel 1 exit /b 1

if not defined ENV_NAME (
  set "INTERACTIVE=1"
  call :prompt_env
)
call :validate_env_name "%ENV_NAME%"
if errorlevel 1 exit /b 1

if not defined ARCH set "ARCH=%DETECTED_ARCH%"
call :validate_arch "%ARCH%"
if errorlevel 1 exit /b 1

set "INSTALLER_CONFIG=%CONFIG_PATH%"
set "INSTALLER_ENV_NAME=%ENV_NAME%"
set "INSTALLER_ARCH=%ARCH%"

if not defined VERSION (
  set "INTERACTIVE=1"
  call :prompt_version
)
if not defined VERSION (
  echo [ERROR] version is required
  exit /b 1
)

if not defined INSTALL_DIR (
  set "INTERACTIVE=1"
  call :prompt_install_dir
)
if not defined INSTALL_DIR (
  echo [ERROR] install dir is required
  exit /b 1
)
if "%INTERACTIVE%"=="1" if "%NO_PROFILE_SPECIFIED%"=="0" call :prompt_no_profile
for %%I in ("%INSTALL_DIR%") do set "INSTALL_DIR=%%~fI"

set "INSTALLER_VERSION=%VERSION%"
set "INSTALLER_INSTALL_DIR=%INSTALL_DIR%"
set "INSTALLER_FORCE=%FORCE%"

call :lookup_package
if errorlevel 1 exit /b 1
call :install_package
if errorlevel 1 exit /b 1
if not "%NO_PROFILE%"=="1" (
  call :write_user_env
  if errorlevel 1 exit /b 1
)
call :print_env_hints
exit /b 0

:usage
echo Usage: install_env.bat [--env NAME] [--version VERSION] [--install-dir PATH] [--arch ARCH] [--config PATH] [--force] [--no-profile]
echo.
echo Required inputs:
echo   --env          node ^| maven ^| java ^| python ^| golang
echo   --version      package version from config json
echo   --install-dir  install target directory
echo.
echo Optional inputs:
echo   --arch         x64 ^| arm64, override detected machine arch
echo   --config       custom config json path, defaults to script\install_env_sources.json
echo   --force        overwrite target directory if it already exists
echo   --no-profile   skip writing user environment variables
echo   --help         show this message
echo.
echo If any required input is missing, the script switches to interactive mode.
exit /b 0

:detect_arch
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "DETECTED_ARCH=x64"
if /i "%PROCESSOR_ARCHITEW6432%"=="AMD64" set "DETECTED_ARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "DETECTED_ARCH=arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "DETECTED_ARCH=arm64"
if not defined DETECTED_ARCH (
  echo [ERROR] unsupported architecture: %PROCESSOR_ARCHITECTURE%
  exit /b 1
)
exit /b 0

:validate_env_name
set "VALUE=%~1"
if /i "%VALUE%"=="node" exit /b 0
if /i "%VALUE%"=="maven" exit /b 0
if /i "%VALUE%"=="java" exit /b 0
if /i "%VALUE%"=="python" exit /b 0
if /i "%VALUE%"=="golang" exit /b 0
echo [ERROR] unsupported env: %VALUE%
exit /b 1

:validate_arch
set "VALUE=%~1"
if /i "%VALUE%"=="x64" exit /b 0
if /i "%VALUE%"=="arm64" exit /b 0
echo [ERROR] unsupported arch: %VALUE%
exit /b 1

:prompt_env
echo 1. node
echo 2. maven
echo 3. java
echo 4. python
echo 5. golang
set /p "CHOICE=Please select env: "
if "%CHOICE%"=="1" set "ENV_NAME=node"
if "%CHOICE%"=="2" set "ENV_NAME=maven"
if "%CHOICE%"=="3" set "ENV_NAME=java"
if "%CHOICE%"=="4" set "ENV_NAME=python"
if "%CHOICE%"=="5" set "ENV_NAME=golang"
if not defined ENV_NAME (
  echo [ERROR] invalid selection: %CHOICE%
  exit /b 1
)
exit /b 0

:prompt_version
echo Available versions for %ENV_NAME% (%ARCH%):
powershell -NoProfile -ExecutionPolicy Bypass -Command "$cfg = Get-Content -Raw $env:INSTALLER_CONFIG | ConvertFrom-Json; $envBlock = $cfg.PSObject.Properties[$env:INSTALLER_ENV_NAME].Value; if (-not $envBlock) { exit 2 }; $key = 'windows-' + $env:INSTALLER_ARCH; $fallback = 'windows-any'; $versions = @($envBlock.version.PSObject.Properties | Where-Object { $_.Value.PSObject.Properties.Name -contains $key -or $_.Value.PSObject.Properties.Name -contains $fallback } | Select-Object -ExpandProperty Name | Sort-Object); if (-not $versions) { exit 2 }; for ($i = 0; $i -lt $versions.Count; $i++) { '{0}. {1}' -f ($i + 1), $versions[$i] }"
if errorlevel 1 exit /b 1
set /p "VERSION_CHOICE=Please select version: "
set "VERSION_FILE=%TEMP%\install-env-version-%RANDOM%%RANDOM%.txt"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$cfg = Get-Content -Raw $env:INSTALLER_CONFIG | ConvertFrom-Json; $envBlock = $cfg.PSObject.Properties[$env:INSTALLER_ENV_NAME].Value; if (-not $envBlock) { exit 2 }; $key = 'windows-' + $env:INSTALLER_ARCH; $fallback = 'windows-any'; $versions = @($envBlock.version.PSObject.Properties | Where-Object { $_.Value.PSObject.Properties.Name -contains $key -or $_.Value.PSObject.Properties.Name -contains $fallback } | Select-Object -ExpandProperty Name | Sort-Object); $index = 0; if ([int]::TryParse($env:VERSION_CHOICE, [ref]$index) -and $index -ge 1 -and $index -le $versions.Count) { $versions[$index - 1] } else { exit 3 }" > "%VERSION_FILE%"
if errorlevel 1 (
  del "%VERSION_FILE%" >nul 2>nul
  echo [ERROR] invalid selection: %VERSION_CHOICE%
  exit /b 1
)
set /p "VERSION=" < "%VERSION_FILE%"
del "%VERSION_FILE%" >nul 2>nul
exit /b 0

:prompt_install_dir
set /p "INSTALL_DIR=Please input install dir: "
exit /b 0

:prompt_no_profile
echo 1. write-profile
echo 2. skip-profile
set /p "PROFILE_CHOICE=Please select profile mode: "
if "%PROFILE_CHOICE%"=="1" set "NO_PROFILE=0"
if "%PROFILE_CHOICE%"=="2" set "NO_PROFILE=1"
if not defined NO_PROFILE (
  echo [ERROR] invalid selection: %PROFILE_CHOICE%
  exit /b 1
)
exit /b 0

:detect_archive_type
set "VALUE=%~1"
if /i "%VALUE:~-7%"==".tar.gz" (
  set "ARCHIVE_TYPE=tar.gz"
  exit /b 0
)
if /i "%VALUE:~-4%"==".tgz" (
  set "ARCHIVE_TYPE=tgz"
  exit /b 0
)
if /i "%VALUE:~-7%"==".tar.xz" (
  set "ARCHIVE_TYPE=tar.xz"
  exit /b 0
)
if /i "%VALUE:~-4%"==".zip" (
  set "ARCHIVE_TYPE=zip"
  exit /b 0
)
echo [ERROR] unsupported archive type in url: %VALUE%
exit /b 1

:lookup_package
set "META_FILE=%TEMP%\install-env-meta-%RANDOM%%RANDOM%.txt"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$cfg = Get-Content -Raw $env:INSTALLER_CONFIG | ConvertFrom-Json; $envBlock = $cfg.PSObject.Properties[$env:INSTALLER_ENV_NAME].Value; if (-not $envBlock) { exit 2 }; $key = 'windows-' + $env:INSTALLER_ARCH; $fallback = 'windows-any'; $versionBlock = $envBlock.version.PSObject.Properties[$env:INSTALLER_VERSION].Value; if (-not $versionBlock) { exit 2 }; $url = if ($versionBlock.PSObject.Properties.Name -contains $key) { $versionBlock.$key } elseif ($versionBlock.PSObject.Properties.Name -contains $fallback) { $versionBlock.$fallback } else { exit 2 }; 'URL=' + $url" > "%META_FILE%"
if errorlevel 1 (
  del "%META_FILE%" >nul 2>nul
  echo [ERROR] no package found for env=%ENV_NAME% version=%VERSION% os=windows arch=%ARCH%
  exit /b 1
)
for /f "usebackq tokens=1,* delims==" %%A in ("%META_FILE%") do set "%%A=%%B"
del "%META_FILE%" >nul 2>nul
if not defined URL (
  echo [ERROR] failed to read package metadata from config
  exit /b 1
)
call :detect_archive_type "%URL%"
if errorlevel 1 exit /b 1
exit /b 0

:install_package
if /i not "%ARCHIVE_TYPE%"=="zip" (
  echo [ERROR] windows bat installer currently supports zip packages only, got %ARCHIVE_TYPE%
  exit /b 1
)

set "INSTALLER_URL=%URL%"
set "INSTALLER_ARCHIVE_TYPE=%ARCHIVE_TYPE%"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; $envName = $env:INSTALLER_ENV_NAME; $version = $env:INSTALLER_VERSION; $installDir = $env:INSTALLER_INSTALL_DIR; $url = $env:INSTALLER_URL; $archiveType = $env:INSTALLER_ARCHIVE_TYPE; $tmp = Join-Path $env:TEMP ('install-env-' + [guid]::NewGuid()); $archive = Join-Path $tmp ('package.' + $archiveType); $extract = Join-Path $tmp 'extract'; New-Item -ItemType Directory -Path $tmp | Out-Null; New-Item -ItemType Directory -Path $extract | Out-Null; try { Invoke-WebRequest -Uri $url -OutFile $archive; if ((Test-Path $installDir) -and ((Get-ChildItem -Force $installDir | Measure-Object).Count -gt 0)) { if ($env:INSTALLER_FORCE -eq '1') { Remove-Item -Recurse -Force $installDir } else { throw 'install dir already exists; use --force to overwrite.' } } New-Item -ItemType Directory -Force -Path $installDir | Out-Null; Expand-Archive -Path $archive -DestinationPath $extract -Force; $children = @(Get-ChildItem -Force $extract); if ($children.Count -eq 1 -and $children[0].PSIsContainer) { $source = $children[0].FullName } else { $source = $extract } Get-ChildItem -Force $source | Copy-Item -Destination $installDir -Recurse -Force; } finally { if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp } }"
if errorlevel 1 exit /b 1
exit /b 0

:write_user_env
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; $envName = $env:INSTALLER_ENV_NAME; $version = $env:INSTALLER_VERSION; $installDir = $env:INSTALLER_INSTALL_DIR; $userPath = [Environment]::GetEnvironmentVariable('Path', 'User'); $script:pathEntries = @(); if ($userPath) { $script:pathEntries = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' }) }; function Add-PathEntry([string]$entry) { if (-not $entry) { return }; $normalized = $entry.TrimEnd('\'); $exists = $false; foreach ($item in $script:pathEntries) { if ($item.TrimEnd('\') -ieq $normalized) { $exists = $true; break } }; if (-not $exists) { $script:pathEntries += $entry } }; if ($envName -eq 'node') { Add-PathEntry $installDir; Add-PathEntry (Join-Path $installDir 'bin') } elseif ($envName -eq 'maven') { [Environment]::SetEnvironmentVariable('M2_HOME', $installDir, 'User'); Add-PathEntry (Join-Path $installDir 'bin') } elseif ($envName -eq 'java') { [Environment]::SetEnvironmentVariable('JAVA_HOME', $installDir, 'User'); if ($version -like 'graalvm-*') { [Environment]::SetEnvironmentVariable('GRAALVM_HOME', $installDir, 'User') } else { [Environment]::SetEnvironmentVariable('GRAALVM_HOME', $null, 'User') }; Add-PathEntry (Join-Path $installDir 'bin') } elseif ($envName -eq 'python') { Add-PathEntry $installDir; Add-PathEntry (Join-Path $installDir 'Scripts') } elseif ($envName -eq 'golang') { [Environment]::SetEnvironmentVariable('GOROOT', $installDir, 'User'); Add-PathEntry (Join-Path $installDir 'bin') }; [Environment]::SetEnvironmentVariable('Path', (($script:pathEntries | Where-Object { $_ -and $_.Trim() -ne '' }) -join ';'), 'User')"
if errorlevel 1 exit /b 1
exit /b 0

:print_env_hints
echo.
echo Installed %ENV_NAME% %VERSION% to %INSTALL_DIR%
if "%NO_PROFILE%"=="1" (
  echo Profile update skipped
) else (
  echo Profile updated: user environment variables
)
echo Open a new terminal to use the updated environment.
exit /b 0
