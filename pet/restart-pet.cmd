@echo off
rem Restart the SpongeBob desktop pet: stop leftovers, then launch.
rem Both scripts sit in this folder -- open them in a text editor to read every line first.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "stop-pet.ps1"
timeout /t 1 /nobreak >nul
powershell -NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Minimized -File "SpongeBobPet.ps1"
