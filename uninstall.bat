@echo off
setlocal EnableDelayedExpansion

:: InterfaceX Uninstaller
:: Removes files and PATH entry

echo.
echo  ============================================
echo   InterfaceX - Uninstaller
echo  ============================================
echo.

set "INSTALL_DIR=%LOCALAPPDATA%\InterfaceX"

:: Check if installed
if not exist "%INSTALL_DIR%\interfacex.bat" (
    echo  InterfaceX is not installed.
    echo  Nothing to do.
    pause
    exit /b 0
)

:: Confirm
set /p CONFIRM="  Remove InterfaceX? This will delete all presets. [Y/n]: "
if /i "!CONFIRM!" == "n" (
    echo  Uninstall cancelled.
    pause
    exit /b 0
)

:: Remove directory
echo  Removing files...
rmdir /s /q "%INSTALL_DIR%" 2>nul
if exist "%INSTALL_DIR%" (
    echo  [WARN] Could not fully remove %INSTALL_DIR%
    echo  Some files may be in use. Try closing all terminals first.
) else (
    echo  [OK] Files removed.
)

:: Remove from PATH
echo  Cleaning PATH...
powershell -NoProfile -Command ^
    "$userPath = [Environment]::GetEnvironmentVariable('Path', 'User');" ^
    "$installDir = '%INSTALL_DIR%';" ^
    "$paths = $userPath -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ne $installDir.TrimEnd('\') };" ^
    "$newPath = $paths -join ';';" ^
    "[Environment]::SetEnvironmentVariable('Path', $newPath, 'User');" ^
    "Write-Host '  [OK] PATH cleaned.'"

echo.
echo  ============================================
echo   InterfaceX has been uninstalled.
echo  ============================================
echo.
echo   Open a new terminal for PATH changes to take effect.
echo.
pause
