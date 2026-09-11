@echo off
rem Restart the SpongeBob desktop pet: stop leftovers (hidden), then launch through the
rem no-console launcher so no cmd window flashes.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "stop-pet.ps1"
timeout /t 1 /nobreak >nul
start "" "%~dp0SpongeBobPet.exe"
