@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "WINDOWS_DIR=%%~fI"
set "PROJECT=%WINDOWS_DIR%\OpenDisplay.Windows.csproj"

if defined DOTNET (
  set "DOTNET_CMD=%DOTNET%"
) else (
  set "DOTNET_CMD=dotnet"
)

if "%~1"=="" (
  if defined CONFIGURATION (
    set "BUILD_CONFIGURATION=%CONFIGURATION%"
  ) else (
    set "BUILD_CONFIGURATION=Release"
  )
) else (
  set "BUILD_CONFIGURATION=%~1"
)

if /I not "%BUILD_CONFIGURATION%"=="Debug" if /I not "%BUILD_CONFIGURATION%"=="Release" (
  echo Usage: %~nx0 [Debug^|Release] 1>&2
  exit /b 2
)

"%DOTNET_CMD%" --version >nul 2>&1
if errorlevel 1 (
  echo error: .NET SDK 8 or newer was not found. 1>&2
  echo Install it from https://dotnet.microsoft.com/download/dotnet/8.0 1>&2
  echo Alternatively set DOTNET=C:\absolute\path\to\dotnet.exe. 1>&2
  exit /b 1
)

set "OUTPUT_DIR=%WINDOWS_DIR%\build\%BUILD_CONFIGURATION%"
pushd "%WINDOWS_DIR%" >nul
if errorlevel 1 (
  echo error: cannot enter %WINDOWS_DIR%. 1>&2
  exit /b 1
)

echo Building OpenDisplay.Windows ^(%BUILD_CONFIGURATION%^) with:
"%DOTNET_CMD%" --version
echo Restoring Windows desktop targeting packs...

"%DOTNET_CMD%" restore "%PROJECT%" -p:EnableWindowsTargeting=true
if errorlevel 1 goto :build_failed

"%DOTNET_CMD%" build "%PROJECT%" --no-restore --configuration "%BUILD_CONFIGURATION%" --output "%OUTPUT_DIR%" -p:EnableWindowsTargeting=true
if errorlevel 1 goto :build_failed

echo.
echo Build output: %OUTPUT_DIR%
popd
exit /b 0

:build_failed
set "BUILD_EXIT=%errorlevel%"
popd
exit /b %BUILD_EXIT%
