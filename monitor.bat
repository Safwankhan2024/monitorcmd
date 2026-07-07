@echo off
title Lightweight Hardware Monitor
mode con cols=80 lines=26
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1" %*
