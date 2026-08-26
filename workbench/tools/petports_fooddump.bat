@echo off
REM ---------------------------------------------------------------------------
REM  petports_fooddump -- double-click me from inside your unpacked assets folder.
REM
REM  Put this and petports_fooddump.py in the same folder, somewhere inside the
REM  unpacked assets tree, and run it. It scans downward from wherever it sits
REM  and writes petports_fooddump.tsv and .txt beside itself.
REM
REM  To scan somewhere else, drag a folder onto this file.
REM ---------------------------------------------------------------------------
setlocal

set SCRIPT=%~dp0petports_fooddump.py

if not exist "%SCRIPT%" (
	echo.
	echo Could not find petports_fooddump.py next to this file.
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

REM  %1 is a folder dragged onto this file, if any.
REM
REM  --all REPORTS EVERY CATEGORY, not just food and crafting materials. The
REM  filtered run kept losing produce: mushroom, wheat, rice, sugarcane and
REM  cocoa all have a seed and a cooked form in scope and their produce
REM  somewhere out of it, so they read as items that do not exist.
REM
REM  Expect a much larger .tsv. To look inside ONE category the report's census
REM  named, run it by hand instead:
REM
REM      py petports_fooddump.py --categories cookingIngredient,fuel
REM
%RUNNER% "%SCRIPT%" %1 --all

echo.
pause
