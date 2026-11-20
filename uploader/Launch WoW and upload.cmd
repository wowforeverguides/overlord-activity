@echo off
rem NOTE: automatic uploads are approved. The recommended setup is install-task.ps1 (Watch mode); use this launcher only instead of it, not as well.
rem Starts the game, waits until it closes, then uploads your Overlord Activity data.
rem Point your desktop shortcut at this file instead of the game.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0overlord-upload.ps1" -Launch
