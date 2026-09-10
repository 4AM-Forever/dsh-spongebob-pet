@echo off
rem SpongeBob desktop pet launcher. The real program is SpongeBobPet.ps1 in this folder --
rem open it in a text editor to read every line before running.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy RemoteSigned -STA -WindowStyle Minimized -File "SpongeBobPet.ps1"
