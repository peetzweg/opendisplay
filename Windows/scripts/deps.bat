@echo off
setlocal EnableExtensions EnableDelayedExpansion

where winget >nul 2>&1
if errorlevel 1 (
  echo error: winget is required but was not found. 1>&2
  echo Install or update "App Installer" from the Microsoft Store, then run this script again. 1>&2
  exit /b 1
)

echo Updating the WinGet package source...
winget source update --name winget
if errorlevel 1 (
  echo warning: WinGet source update failed; continuing with the current package index. 1>&2
)

set /a FAILED=0

call :install Microsoft.DotNet.SDK.8 ".NET 8 SDK"
call :install Microsoft.VCRedist.2015+.x64 "Microsoft Visual C++ Redistributable x64"
call :install Gyan.FFmpeg "FFmpeg"
call :install Google.PlatformTools "Android SDK Platform Tools"
call :install VirtualDrivers.Virtual-Display-Driver "Virtual Display Driver"

echo.
if not "!FAILED!"=="0" (
  echo error: !FAILED! dependency installation^(s^) failed. Review the WinGet output above. 1>&2
  exit /b 1
)

echo All OpenDisplay Windows dependencies are installed.
echo Close and reopen this terminal so PATH changes for dotnet, ffmpeg, and adb take effect.
echo Then run: scripts\build.bat Release
echo.
echo VDD may require a restart and receiver-native modes in:
echo   C:\VirtualDisplayDriver\vdd_settings.xml
exit /b 0

:install
set "PACKAGE_ID=%~1"
set "PACKAGE_NAME=%~2"
echo.
echo Installing %PACKAGE_NAME% [%PACKAGE_ID%]...
winget install --id "%PACKAGE_ID%" --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
if errorlevel 1 (
  echo error: failed to install %PACKAGE_NAME%. 1>&2
  set /a FAILED+=1
) else (
  echo %PACKAGE_NAME% is ready.
)
exit /b 0
