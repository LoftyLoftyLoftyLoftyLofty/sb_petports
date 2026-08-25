@echo off
REM ---------------------------------------------------------------------------
REM  petports_tagdump -- double-click me from inside your unpacked assets folder.
REM
REM  Put this and petports_tagdump.py in the same folder, somewhere inside the
REM  unpacked assets tree, and run it. It scans downward from wherever it sits
REM  and writes petports_tagdump.txt beside itself.
REM
REM  To scan somewhere else, drag a folder onto this file.
REM ---------------------------------------------------------------------------
setlocal

set SCRIPT=%~dp0petports_tagdump.py

if not exist "%SCRIPT%" (
	echo.
	echo Could not find petports_tagdump.py next to this file.
	echo Both files need to be in the same folder.
	echo.
	pause
	exit /b 1
)

REM  py.exe is the Windows launcher and is what a normal python.org install
REM  provides; plain python.exe is the fallback for a PATH install or a venv.
set RUNNER=
where py.exe >nul 2>&1 && set RUNNER=py
if "%RUNNER%"=="" (
	where python.exe >nul 2>&1 && set RUNNER=python
)

if "%RUNNER%"=="" (
	echo.
	echo No Python found. Install it from python.org and tick
	echo "Add Python to PATH" during setup, then run this again.
	echo.
	pause
	exit /b 1
)

REM  %1 is a folder dragged onto this file, if any. --csv also writes a
REM  per-item table, which is the one to open in a spreadsheet when you want to
REM  see which objects carry a given tag.
%RUNNER% "%SCRIPT%" %1 --csv "%~dp0petports_tagdump.csv"

echo.
pause
