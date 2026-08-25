@echo off
title RAM Cleaner
setlocal

:: Self-elevate: relaunch this bat as Administrator via UAC
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    if "%*"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

:: Run the cleaner (admin context)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Clean-RAM.ps1" %*

echo.
pause
