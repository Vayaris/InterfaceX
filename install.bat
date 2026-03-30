@echo off
setlocal EnableDelayedExpansion

:: InterfaceX Installer
:: Copies files to %LOCALAPPDATA%\InterfaceX and adds to user PATH

echo.
echo  ============================================
echo   InterfaceX - Installer
echo  ============================================
echo.

set "INSTALL_DIR=%LOCALAPPDATA%\InterfaceX"
set "SOURCE_DIR=%~dp0"

:: Check if source files exist
if not exist "%SOURCE_DIR%interfacex.bat" (
    echo  [ERROR] interfacex.bat not found in %SOURCE_DIR%
    echo  Make sure you run install.bat from the project folder.
    pause
    exit /b 1
)
if not exist "%SOURCE_DIR%interfacex.ps1" (
    echo  [ERROR] interfacex.ps1 not found in %SOURCE_DIR%
    echo  Make sure you run install.bat from the project folder.
    pause
    exit /b 1
)

:: Check if already installed
if exist "%INSTALL_DIR%\interfacex.bat" (
    echo  InterfaceX is already installed at:
    echo  %INSTALL_DIR%
    echo.
    set /p OVERWRITE="  Overwrite? [Y/n]: "
    if /i "!OVERWRITE!" == "n" (
        echo  Installation cancelled.
        pause
        exit /b 0
    )
)

:: Create install directory
if not exist "%INSTALL_DIR%" (
    mkdir "%INSTALL_DIR%"
    if errorlevel 1 (
        echo  [ERROR] Failed to create directory %INSTALL_DIR%
        pause
        exit /b 1
    )
)

:: Copy files
echo  Copying files...
copy /y "%SOURCE_DIR%interfacex.bat" "%INSTALL_DIR%\" >nul
copy /y "%SOURCE_DIR%interfacex.ps1" "%INSTALL_DIR%\" >nul

:: Preserve existing presets
if exist "%SOURCE_DIR%presets.json" (
    if not exist "%INSTALL_DIR%\presets.json" (
        copy /y "%SOURCE_DIR%presets.json" "%INSTALL_DIR%\" >nul
    )
)

echo  [OK] Files copied to %INSTALL_DIR%

:: Check if already in PATH
echo  Checking PATH...
powershell -NoProfile -Command ^
    "$userPath = [Environment]::GetEnvironmentVariable('Path', 'User');" ^
    "$installDir = '%INSTALL_DIR%';" ^
    "$paths = $userPath -split ';' | Where-Object { $_ -ne '' };" ^
    "$found = $paths | Where-Object { $_.TrimEnd('\') -eq $installDir.TrimEnd('\') };" ^
    "if ($found) { exit 0 } else { exit 1 }"

if %errorlevel% equ 0 (
    echo  [OK] Already in PATH.
) else (
    echo  Adding to PATH...
    powershell -NoProfile -Command ^
        "$userPath = [Environment]::GetEnvironmentVariable('Path', 'User');" ^
        "$installDir = '%INSTALL_DIR%';" ^
        "if ($userPath -and -not $userPath.EndsWith(';')) { $userPath += ';' };" ^
        "$userPath += $installDir;" ^
        "[Environment]::SetEnvironmentVariable('Path', $userPath, 'User');" ^
        "Write-Host '  [OK] Added to user PATH.'"
)

echo.
echo  ============================================
echo   Installation complete!
echo  ============================================
echo.
echo   Open a NEW terminal and type:  interfacex
echo.
echo   To uninstall later, run:       uninstall.bat
echo.
pause
