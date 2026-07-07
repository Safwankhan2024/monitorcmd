@echo off
title Lightweight Hardware Monitor
mode con cols=72 lines=16
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1" %*
