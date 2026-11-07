@echo off
setlocal enabledelayedexpansion
title LoRa Decoder Studio

set DIR=%~dp0
cd /d "%DIR%"
set PORT=8080
if not "%1"=="" (
    if not "%1"=="--web" (
        set PORT=%1
    ) else (
        if not "%2"=="" set PORT=%2
    )
)

echo ==============================================================
echo  LoRa Payload Decoder Studio - Universal Windows Launcher
echo ==============================================================

:: 1. Check Python via 'py' launcher (standard python.org install)
py --version >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [FOUND] Python via Windows Launcher 'py'
    echo [INFO]  Starting Web Server on port %PORT%...
    start "" "http://localhost:%PORT%"
    py web_server.py --port %PORT%
    goto :eof
)

:: 2. Check 'python' (verify it is not the broken MS Store alias)
python -c "import sys; sys.exit(0)" >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [FOUND] Python executable 'python'
    echo [INFO]  Starting Web Server on port %PORT%...
    start "" "http://localhost:%PORT%"
    python web_server.py --port %PORT%
    goto :eof
)

:: 3. Check 'python3' (verify it is not broken MS Store alias)
python3 -c "import sys; sys.exit(0)" >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [FOUND] Python 3 executable 'python3'
    echo [INFO]  Starting Web Server on port %PORT%...
    start "" "http://localhost:%PORT%"
    python3 web_server.py --port %PORT%
    goto :eof
)

:: 4. Check Node.js
node -v >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [FOUND] Node.js
    echo [INFO]  Starting Web Server on port %PORT%...
    start "" "http://localhost:%PORT%"
    node web_server.js %PORT%
    goto :eof
)

:: 5. Check Lua
lua -v >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [FOUND] Lua
    lua service.lua --test
    echo.
)

:: 6. No runtime installed: Zero-Install Direct Browser Mode
echo [NOTE]  No working Python, Node.js, or Lua found on this system.
echo [INFO]  Launching Decoder Studio directly in your web browser (Zero-Install Mode)...
echo.
start "" "%DIR%index.html"
echo Opened %DIR%index.html in your default web browser!
echo You can use the full Decoder Studio, test payloads, and edit schemes.
echo ==============================================================
pause
