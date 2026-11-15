@echo off
rem NOTE: not enabled yet, pending the owner's decision. Use a manual run of overlord-upload.ps1 for now.
rem Starts the game, waits until it closes, then uploads your Overlord Activity data.
rem Point your desktop shortcut at this file instead of the game.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0overlord-upload.ps1" -Launch
