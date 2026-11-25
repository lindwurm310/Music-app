@echo off
rem MusicSync サーバー起動用（Windows）
rem 使い方: このファイルをダブルクリック（既定は「ミュージック」フォルダ）
rem        または  start-musicsync.bat "D:\音楽"
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "MUSIC_DIR=%~1"
if "%MUSIC_DIR%"=="" set "MUSIC_DIR=%USERPROFILE%\Music"

if exist ".venv\Scripts\python.exe" goto :run

echo 初回セットアップ中です（数十秒かかります）...
set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY (where python >nul 2>nul && set "PY=python")
if not defined PY goto :nopython
%PY% -m venv .venv || goto :nopython
".venv\Scripts\python.exe" -m pip install --upgrade pip >nul
".venv\Scripts\python.exe" -m pip install -e ".[art]" || goto :error

:run
".venv\Scripts\python.exe" -m musicsync serve "%MUSIC_DIR%" %2 %3 %4 %5
echo.
pause
exit /b 0

:nopython
echo Python が見つかりません。
echo https://www.python.org/downloads/ から Python 3.10 以上をインストールしてください。
echo インストール時に「Add python.exe to PATH」にチェックを入れてください。
pause
exit /b 1

:error
echo セットアップに失敗しました。インターネット接続を確認して、もう一度実行してください。
rmdir /s /q .venv 2>nul
pause
exit /b 1
