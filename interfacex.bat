@echo off
setlocal

:: InterfaceX - Network Interface Configuration Tool
:: Launcher with automatic admin elevation

:: Check for admin privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\" %*\"' -Verb RunAs"
    exit /b
)

:: Launch the PowerShell core application
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0interfacex.ps1" %*
exit /b
