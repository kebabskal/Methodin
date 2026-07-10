@echo off
rem Build medit with the Methodin compiler at the repo root.
cd /d "%~dp0.."

if not exist odin.exe (
	echo error: build the Methodin compiler first: build.bat release
	exit /b 1
)

odin build editor -out:editor\medit.exe -o:speed
if %errorlevel% neq 0 exit /b %errorlevel%
echo built editor\medit.exe ^(needs vendor\sdl3\SDL3.dll next to it or on PATH^)
