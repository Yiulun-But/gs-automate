@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ==============================================================
rem  make_splat.bat  —  MP4 -> frames -> COLMAP -> train -> export
rem  Pipelines: lichtfeld (default) or nerfstudio (optional)
rem  Usage: make_splat.bat config.env [--dry-run] [--force]
rem ==============================================================

REM ---------- Parse args ----------
if "%~1"=="" goto :usage
set "CFG=%~1"
set "DRYRUN=0"
set "FORCE=0"
shift
:argloop
if "%~1"=="" goto :afterargs
if /i "%~1"=="--dry-run" set "DRYRUN=1"& shift& goto :argloop
if /i "%~1"=="-n"       set "DRYRUN=1"& shift& goto :argloop
if /i "%~1"=="--force"  set "FORCE=1" & shift& goto :argloop
echo [WARN] Unknown arg: %~1
shift
goto :argloop
:afterargs

if not exist "%CFG%" (
  echo [ERR] Config not found: %CFG%
  exit /b 2
)

REM ---------- Load KEY=VALUE config (ignore empty lines & # comments) ----------
for /f "usebackq eol=# tokens=1* delims==" %%A in ("%CFG%") do (
  set "k=%%~A"
  set "v=%%~B"
  if not "!k!"=="" set "!k!=!v!"
)

REM ---------- Defaults ----------
if not defined PIPELINE        set "PIPELINE=lichtfeld"
if not defined FPS             set "FPS=2"
if not defined LONG_EDGE       set "LONG_EDGE=1080"
if not defined IMAGE_EXT       set "IMAGE_EXT=png"
if not defined SINGLE_CAMERA   set "SINGLE_CAMERA=1"
if not defined DENSE           set "DENSE=0"
if not defined SIFT_THREADS    set "SIFT_THREADS=8"
if not defined MAPPER_THREADS  set "MAPPER_THREADS=8"
if not defined SEED            set "SEED=42"
if not defined LF_WORK_DIRNAME set "LF_WORK_DIRNAME=lf_train"

REM ---------- Validate required ----------
for %%V in (PROJECT WORK_DIR VIDEO COLMAP_BAT) do (
  if not defined %%V (
    echo [ERR] Missing required variable: %%V
    goto :usage
  )
)
if not defined FFMPEG set "FFMPEG=ffmpeg"
if /i "%PIPELINE%"=="lichtfeld" (
  if not defined LICHTFELD_EXE (
    echo [ERR] PIPELINE is 'lichtfeld' but LICHTFELD_EXE not set.
    goto :usage
  )
)

REM ---------- Optional CUDA path augment ----------
if defined CUDA_HOME (
  set "PATH=%CUDA_HOME%\bin;%CUDA_HOME%\libnvvp;%PATH%"
)

REM ---------- Make directories ----------
for %%D in ("%WORK_DIR%" "%WORK_DIR%\logs" "%WORK_DIR%\frames" "%WORK_DIR%\colmap" "%WORK_DIR%\colmap\sparse" "%WORK_DIR%\colmap\undistorted" "%WORK_DIR%\%LF_WORK_DIRNAME%" "%WORK_DIR%\%LF_WORK_DIRNAME%\model" "%WORK_DIR%\output" "%WORK_DIR%\ns_data" "%WORK_DIR%\ns_train") do (
  if not exist "%%~D" mkdir "%%~D" >nul 2>nul
)
set "LOG_DIR=%WORK_DIR%\logs"
set "FRAMES_DIR=%WORK_DIR%\frames"
set "COLMAP_DIR=%WORK_DIR%\colmap"
set "SPARSE_DIR=%COLMAP_DIR%\sparse"
set "UNDIST_DIR=%COLMAP_DIR%\undistorted"
set "LF_TRAIN_DIR=%WORK_DIR%\%LF_WORK_DIRNAME%"
set "MODEL_DIR=%LF_TRAIN_DIR%\model"
set "OUT_DIR=%WORK_DIR%\output"
set "NS_DATA_DIR=%WORK_DIR%\ns_data"
set "NS_OUT_DIR=%WORK_DIR%\ns_train"
set "SPLAT_PATH=%OUT_DIR%\%PROJECT%_gaussians.ply"

REM ---------- Timestamp for log filename ----------
for /f %%I in ('powershell -NoProfile -Command "(Get-Date).ToString('yyyyMMdd_HHmmss')"') do set "TS=%%I"
if not defined TS set "TS=run"
set "LOG=%LOG_DIR%\run-%TS%.log"

echo. & echo === Config summary ===
echo Project   : %PROJECT%
echo WorkDir   : %WORK_DIR%
echo Video     : %VIDEO%
echo FramesDir : %FRAMES_DIR%
echo ColmapDir : %COLMAP_DIR%
echo ModelDir  : %MODEL_DIR%
echo Output    : %SPLAT_PATH%
echo Pipeline  : %PIPELINE%

REM Helper to run a command (shows & logs). Use: call :RUN cmd args...
:noop
goto :after_run
:RUN
set "_CMD=%*"
echo [*] %_CMD%
echo >>> %_CMD%>>"%LOG%"
if "%DRYRUN%"=="1" exit /b 0
call %*
set "_RC=%ERRORLEVEL%"
if not "!_RC!"=="0" (
  echo [ERR] ExitCode=!_RC!
  exit /b !_RC!
)
exit /b 0
:after_run

REM ---------- Step 1/4: Extract frames ----------
echo. & echo === Step 1/4: Extract frames with ffmpeg ===
if exist "%FRAMES_DIR%\*.%IMAGE_EXT%" if "%FORCE%"=="0" (
  echo [OK] Skipping extraction (frames already exist).
) else (
  set "VF=fps=%FPS%"
  if %LONG_EDGE% GTR 0 (
    set "VF=%VF%,scale=%LONG_EDGE%:%LONG_EDGE%:force_original_aspect_ratio=decrease"
  )
  if defined TRANSPOSE (
    set "VF=%VF%,transpose=%TRANSPOSE%"
  )
  rem IMPORTANT: use %%05d inside batch
  call :RUN "%FFMPEG%" -y -i "%VIDEO%" -vf "%VF%" "%FRAMES_DIR%\frame_%%05d.%IMAGE_EXT%"
  echo [OK] Extracted frames -> %FRAMES_DIR%
)

REM ---------- Step 2/4: COLMAP ----------
echo. & echo === Step 2/4: COLMAP (%PIPELINE%) ===
if /i "%COLMAP_MODE%"=="manual" (
  call :RUN "%COLMAP_BAT%" feature_extractor --database_path "%COLMAP_DIR%\database.db" --image_path "%FRAMES_DIR%" --ImageReader.single_camera %SINGLE_CAMERA% --SiftExtraction.num_threads %SIFT_THREADS%
  call :RUN "%COLMAP_BAT%" exhaustive_matcher --database_path "%COLMAP_DIR%\database.db"
  call :RUN "%COLMAP_BAT%" mapper --database_path "%COLMAP_DIR%\database.db" --image_path "%FRAMES_DIR%" --output_path "%SPARSE_DIR%" --Mapper.num_threads %MAPPER_THREADS%
) else (
  rem default: automatic
  call :RUN "%COLMAP_BAT%" automatic_reconstructor --workspace_path "%COLMAP_DIR%" --image_path "%FRAMES_DIR%" --dense %DENSE% --single_camera %SINGLE_CAMERA%
  echo [OK] COLMAP automatic reconstruction complete.
)

rem Always undistort for LichtFeld
call :RUN "%COLMAP_BAT%" image_undistorter --image_path "%FRAMES_DIR%" --input_path "%SPARSE_DIR%\0" --output_path "%UNDIST_DIR%" --output_type COLMAP
echo [OK] COLMAP undistortion complete -> %UNDIST_DIR%

REM ---------- Step 3/4: Train ----------
echo. & echo === Step 3/4: Train ===
if /i "%PIPELINE%"=="lichtfeld" (
  if not defined LF_TRAIN_ARGS set "LF_TRAIN_ARGS="
  call :RUN "%LICHTFELD_EXE%" train --data "%UNDIST_DIR%" --output "%MODEL_DIR%" %LF_TRAIN_ARGS%
  echo [OK] Training completed (LichtFeld). Model -> %MODEL_DIR%
) else if /i "%PIPELINE%"=="nerfstudio" (
  if not defined NS_PREP_ARGS set "NS_PREP_ARGS="
  if not defined NS_TRAIN_ARGS set "NS_TRAIN_ARGS="
  call :RUN ns-process-data video --data "%VIDEO%" --output-dir "%NS_DATA_DIR%" --fps %FPS% --max-frame-processes 8 --keep-extracted-frames --auto-orient %NS_PREP_ARGS%
  call :RUN ns-train gsplat --data "%NS_DATA_DIR%" --output-dir "%NS_OUT_DIR%" %NS_TRAIN_ARGS%
  echo [OK] Training completed (Nerfstudio).
) else (
  echo [ERR] Unknown PIPELINE: %PIPELINE%
  exit /b 3
)

REM ---------- Step 4/4: Export splat ----------
echo. & echo === Step 4/4: Export Gaussian Splat ===
if /i "%PIPELINE%"=="lichtfeld" (
  if not defined LF_EXPORT_ARGS set "LF_EXPORT_ARGS="
  call :RUN "%LICHTFELD_EXE%" export --model "%MODEL_DIR%" --output "%SPLAT_PATH%" %LF_EXPORT_ARGS%
  echo [OK] Exported Gaussian splat -> %SPLAT_PATH%
) else (
  if not defined NS_EXPORT_ARGS set "NS_EXPORT_ARGS="
  call :RUN ns-export gaussian-splat --load-config "%NS_OUT_DIR%\outputs\latest\config.yml" --output "%SPLAT_PATH%" %NS_EXPORT_ARGS%
  echo [OK] Exported Gaussian splat -> %SPLAT_PATH%
)

REM ---------- Result manifest (simple JSON with forward slashes) ----------
set "WORK_DIR_JSON=%WORK_DIR:\=/%"
set "FRAMES_DIR_JSON=%FRAMES_DIR:\=/%"
set "COLMAP_DIR_JSON=%COLMAP_DIR:\=/%"
set "MODEL_DIR_JSON=%MODEL_DIR:\=/%"
set "SPLAT_PATH_JSON=%SPLAT_PATH:\=/%"
set "VIDEO_JSON=%VIDEO:\=/%"

> "%OUT_DIR%\result.json" (
  echo { 
  echo   "project": "%PROJECT%",
  echo   "work_dir": "%WORK_DIR_JSON%",
  echo   "video": "%VIDEO_JSON%",
  echo   "frames": "%FRAMES_DIR_JSON%",
  echo   "colmap": "%COLMAP_DIR_JSON%",
  echo   "model_dir": "%MODEL_DIR_JSON%",
  echo   "output": "%SPLAT_PATH_JSON%",
  echo   "pipeline": "%PIPELINE%"
  echo }
)
echo [OK] Result manifest: %OUT_DIR%\result.json
exit /b 0


:usage
echo.
echo Usage: %~nx0 config.env [--dry-run] [--force]
echo.
echo Config file is KEY=VALUE lines. Minimal template:
echo --------------------------------------------------
echo PROJECT=demo_splat
echo WORK_DIR=D:/GS/work/demo_splat
echo VIDEO=D:/GS/data/input.mp4
echo FFMPEG=ffmpeg
echo COLMAP_BAT=C:/Program Files/COLMAP/colmap.bat
echo PIPELINE=lichtfeld
echo LICHTFELD_EXE=C:/Program Files/LichtFeld Studio/LichtFeld.exe
echo.
echo ^# Optional tuning:
echo FPS=2
echo LONG_EDGE=1080
echo IMAGE_EXT=png
echo SINGLE_CAMERA=1
echo DENSE=0
echo SIFT_THREADS=8
echo MAPPER_THREADS=8
echo TRANSPOSE=
echo SEED=42
echo LF_WORK_DIRNAME=lf_train
echo LF_TRAIN_ARGS=--max_iters 30000 --batch_size 1 --fp16 --random_seed 42
echo LF_EXPORT_ARGS=--num_points 1000000 --format ply
echo.
echo ^# Optional CUDA:
echo CUDA_HOME=C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8
echo.
echo ^# Nerfstudio (if PIPELINE=nerfstudio):
echo NS_PREP_ARGS=
echo NS_TRAIN_ARGS=--max-num-iterations 30000
echo NS_EXPORT_ARGS=--num-points 1000000
echo --------------------------------------------------
exit /b 1
