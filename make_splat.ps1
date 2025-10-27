<#
.SYNOPSIS
  Orchestrate MP4 -> frames -> COLMAP -> train -> export Gaussian splat
  Works with LichtFeld Studio (configurable CLI) or Nerfstudio (optional).

.PARAMETER Config
  Path to JSON config file (see template via -InitConfig).

.PARAMETER InitConfig
  Write a minimal+powerful config file template to this path and exit.

.PARAMETER DryRun
  Print what would run, but don't execute.

.PARAMETER Force
  Re-run steps even if outputs exist.

.NOTES
  Assumes:
    - CUDA 12.8 already installed and on PATH (or specify in config.cuda.home)
    - COLMAP .bat path provided in config.colmap.bat
    - ffmpeg available (or path provided in config.ffmpeg.path)
    - LichtFeld Studio installed + accessible via the command templates you provide
#>

[CmdletBinding()]
param(
  [string]$Config,
  [string]$InitConfig,
  [switch]$DryRun,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Step($t)    { Write-Host "[*] $t" -ForegroundColor Yellow }
function Write-Success($t) { Write-Host "[OK] $t" -ForegroundColor Green }
function Write-Error($t)   { Write-Host "[ERR] $t" -ForegroundColor Red }

function New-ConfigTemplate() {
@"
{
  "project": {
    "name": "demo_splat",
    "work_dir": "D:/GS/work/demo_splat",
    "video":   "D:/GS/data/input.mp4",
    "seed": 42
  },

  "tools": {
    "ffmpeg": { "path": "ffmpeg" },
    "colmap": { "bat":  "C:/Program Files/COLMAP/colmap.bat" },
    "lichtfeld": { "exe": "C:/Program Files/LichtFeld Studio/LichtFeld.exe" },
    "cuda":   { "home": null }
  },

  "pipeline": "lichtfeld",  // or "nerfstudio"

  "extract": {
    "fps": 2,
    "resize_long_edge": 1080,
    "image_ext": "png",
    "skip_if_exists": true
  },

  "colmap": {
    "mode": "automatic",  // "automatic" or "manual"
    "db_name": "database.db",
    "single_camera": true,
    "sift_threads": 8,
    "mapper_num_threads": 8,
    "dense": false,

    // OPTIONAL: Override with your own command templates
    "templates": {
      // Automatic reconstructor does everything (sparse only if dense=false)
      "automatic": "\"{colmap_bat}\" automatic_reconstructor --workspace_path \"{colmap_dir}\" --image_path \"{frames_dir}\" --dense {dense} --single_camera {single_camera}",

      // Manual steps (feature -> match -> mapper -> undistort)
      "feature_extractor": "\"{colmap_bat}\" feature_extractor --database_path \"{db}\" --image_path \"{frames_dir}\" --ImageReader.single_camera {single_camera} --SiftExtraction.num_threads {sift_threads}",
      "matcher": "\"{colmap_bat}\" exhaustive_matcher --database_path \"{db}\"",
      "mapper": "\"{colmap_bat}\" mapper --database_path \"{db}\" --image_path \"{frames_dir}\" --output_path \"{sparse_dir}\" --Mapper.num_threads {mapper_num_threads}",
      "undistort": "\"{colmap_bat}\" image_undistorter --image_path \"{frames_dir}\" --input_path \"{sparse_dir}/0\" --output_path \"{undist_dir}\" --output_type COLMAP"
    }
  },

  // ---- LICHTFELD STUDIO ----
  // Specify LichtFeld.exe path in tools.lichtfeld.exe
  "lichtfeld": {
    "train": {
      "work_dir_name": "lf_train",
      "command": "& \"{lichtfeld_exe}\" train --data \"{data_dir}\" --output \"{model_dir}\"",
      "args": {
        "max_iters": 30000,
        "batch_size": 1,
        "fp16": true,
        "random_seed": "{seed}"
      },
      "args_from_file": null
    },
    "export": {
      "command": "& \"{lichtfeld_exe}\" export --model \"{model_dir}\" --output \"{splat_path}\"",
      "args": {
        "num_points": 1000000,
        "format": "ply"
      },
      "args_from_file": null
    }
  },

  // ---- NERFSTUDIO (optional fallback) ----
  // Nerfstudio commands should be on PATH
  "nerfstudio": {
    "prepare": {
      "command": "ns-process-data video --data \"{video}\" --output-dir \"{ns_data_dir}\" --fps {fps} --max-frame-processes 8 --keep-extracted-frames --auto-orient",
      "args": { }
    },
    "train": {
      "command": "ns-train gsplat --data \"{ns_data_dir}\" --output-dir \"{ns_out_dir}\"",
      "args": { "max-num-iterations": 30000 }
    },
    "export": {
      "command": "ns-export gaussian-splat --load-config \"{ns_out_dir}/outputs/latest/config.yml\" --output \"{splat_path}\"",
      "args": { "num-points": 1000000 }
    }
  }
}
"@
}

if ($InitConfig) {
  if (Test-Path $InitConfig) { throw "File already exists: $InitConfig" }
  New-ConfigTemplate | Set-Content -Encoding UTF8 -NoNewline -LiteralPath $InitConfig
  Write-Success "Wrote template: $InitConfig"
  return
}

if (-not $Config) { throw "Provide -Config <path to json> or -InitConfig to generate one." }
if (-not (Test-Path $Config)) { throw "Config not found: $Config" }

# --- Helpers ---
function ConvertFrom-JsonFile($path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable }

function Initialize-Directory($p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  (Resolve-Path $p).Path
}

function Join-PathSafe([string]$a,[string]$b) {
  if ($a -and $b) { return (Join-Path $a $b) }
  elseif ($a) { return $a }
  else { return $b }
}

function ConvertTo-BinaryInt($b) { if ($b -is [bool]) { if ($b) {1} else {0} } else { $b } }

function ConvertTo-ArgString([hashtable]$kv) {
  if (-not $kv) { return "" }
  $parts = @()
  foreach ($k in $kv.Keys) {
    $v = $kv[$k]
    if ($v -is [bool]) {
      if ($v) { $parts += "--$k" }  # boolean flags appear if true
    } elseif ($null -eq $v -or $v -eq "") {
      # skip
    } else {
      $vstr = "$v"
      # quote if needed
      if ($vstr -match '\s' -or $vstr -match '[\\"]') { $vstr = '"' + $vstr.Replace('"','\"') + '"' }
      $parts += "--$k $vstr"
    }
  }
  return ($parts -join ' ')
}

function Merge-ArgumentsFromFile([hashtable]$base,[string]$file) {
  if (-not $file) { return $base }
  if (-not (Test-Path $file)) { throw "args_from_file not found: $file" }
  $extra = ConvertFrom-JsonFile $file
  foreach ($k in $extra.Keys) { $base[$k] = $extra[$k] }
  return $base
}

function Expand-TemplateString([string]$template,[hashtable]$ctx) {
  $expanded = $template
  foreach ($key in $ctx.Keys) {
    $v = "$($ctx[$key])"
    $expanded = $expanded -replace "\{$key\}", [Regex]::Escape($v) -replace '\\E','' -replace '\\Q',''
  }
  return $expanded
}

function Invoke-Command([string]$cmd, [string]$workdir, [hashtable]$env, [string]$logFile) {
  Write-Step $cmd
  if ($DryRun) { return 0 }
  if ($logFile) {
    ">>> $cmd`n" | Add-Content -Encoding UTF8 -LiteralPath $logFile
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = "powershell.exe"
  $psi.Arguments = "-NoProfile -NonInteractive -Command $cmd"
  $psi.WorkingDirectory = $workdir
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  foreach ($k in $env.Keys) { $psi.Environment[$k] = "$($env[$k])" }

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  $null = $p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($logFile) {
    $stdout | Add-Content -Encoding UTF8 -LiteralPath $logFile
    if ($stderr) {
      "`n[stderr]`n$stderr`n" | Add-Content -Encoding UTF8 -LiteralPath $logFile
    }
  }

  if ($p.ExitCode -ne 0) {
    Write-Error "ExitCode=$($p.ExitCode)"
    throw "Command failed: $cmd`n$stderr"
  }
  return $p.ExitCode
}

# --- Load config & derive paths ---
$config = ConvertFrom-JsonFile $Config

$projName = $config.project.name
$workDir  = Initialize-Directory $config.project.work_dir
$video    = $config.project.video
if (-not (Test-Path $video)) { throw "Video not found: $video" }

$tools      = $config.tools
$ffmpeg     = $tools.ffmpeg.path
$colmap     = $tools.colmap.bat
$lichtfeldExe = $tools.lichtfeld.exe
$cudaHome   = $tools.cuda.home

if (-not $ffmpeg) { $ffmpeg = "ffmpeg" }
if (-not (Get-Command $ffmpeg -ErrorAction SilentlyContinue)) {
  if (-not (Test-Path $ffmpeg)) { throw "ffmpeg not found or not on PATH. Provide tools.ffmpeg.path" }
}

if (-not (Test-Path $colmap)) { throw "COLMAP .bat not found: $colmap" }
if ($lichtfeldExe -and -not (Test-Path $lichtfeldExe)) { throw "LichtFeld executable not found: $lichtfeldExe" }
if ($cudaHome -and -not (Test-Path $cudaHome)) { throw "CUDA home not found: $cudaHome" }

# Project structure
$logDir     = Initialize-Directory (Join-Path $workDir "logs")
$log        = Join-Path $logDir "run-$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$framesDir  = Initialize-Directory (Join-Path $workDir "frames")
$colmapDir  = Initialize-Directory (Join-Path $workDir "colmap")
$sparseDir  = Initialize-Directory (Join-Path $colmapDir "sparse")
$undistDir  = Initialize-Directory (Join-Path $colmapDir "undistorted")
$dbPath     = Join-Path $colmapDir ($config.colmap.db_name)

$lfTrainDir = Initialize-Directory (Join-Path $workDir (if ($config.lichtfeld.train.work_dir_name) { $config.lichtfeld.train.work_dir_name } else { "lf_train" }))
$modelDir   = Initialize-Directory (Join-Path $lfTrainDir "model")
$outDir     = Initialize-Directory (Join-Path $workDir "output")
$splatPath  = Join-Path $outDir "$($projName)_gaussians.ply"

$nsDataDir  = Initialize-Directory (Join-Path $workDir "ns_data")
$nsOutDir   = Initialize-Directory (Join-Path $workDir "ns_train")

# Environment for subprocesses
$env = @{}
if ($cudaHome) {
  $env["CUDA_HOME"] = $cudaHome
  $env["PATH"] = "$cudaHome\bin;$cudaHome\libnvvp;$($env:PATH)"
}
$env["CUDA_VISIBLE_DEVICES"] = $env:CUDA_VISIBLE_DEVICES  # pass-through if user set it
$env["PYTHONIOENCODING"] = "utf-8"
$env["PYTHONUTF8"] = "1"

# Context for template expansion
$ctx = @{
  project      = $projName
  work_dir     = $workDir
  video        = (Resolve-Path $video).Path
  frames_dir   = $framesDir
  colmap_dir   = $colmapDir
  sparse_dir   = $sparseDir
  undist_dir   = $undistDir
  db           = $dbPath
  python       = if ($python) { (Resolve-Path $python).Path } else { "" }
  colmap_bat   = (Resolve-Path $colmap).Path
  model_dir    = $modelDir
  data_dir     = $undistDir  # default: use undistorted images for training
  ns_data_dir  = $nsDataDir
  ns_out_dir   = $nsOutDir
  splat_path   = $splatPath
  seed         = $config.project.seed
}

Write-Section "Config summary"
$summary = @{
  Project   = $projName
  WorkDir   = $workDir
  Video     = $video
  FramesDir = $framesDir
  ColmapDir = $colmapDir
  ModelDir  = $modelDir
  Output    = $splatPath
  Pipeline  = $config.pipeline
}
$summary.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0,-10} : {1}" -f $_.Name, $_.Value } | Tee-Object -FilePath $log -Append

# --------------------- Step 1: Extract frames ---------------------
Write-Section "Step 1/4: Extract frames with ffmpeg"
$imgExt   = $config.extract.image_ext
$fps      = $config.extract.fps
$longEdge = $config.extract.resize_long_edge
$pattern  = Join-Path $framesDir ("frame_%05d.$imgExt")
$already  = Get-ChildItem -Path $framesDir -Filter "*.$imgExt" -ErrorAction SilentlyContinue | Measure-Object
$skip     = $config.extract.skip_if_exists -and ($already.Count -gt 0) -and (-not $Force)

if ($skip) {
  Write-Success "Skipping extraction (frames already exist)."
} else {
  $vf = "fps=$fps"
  if ($longEdge -gt 0) {
    # scale so that long edge == resize_long_edge, preserve aspect
    $vf = "$vf,scale='if(gt(iw,ih),$longEdge,-2)':'if(gt(ih,iw),$longEdge,-2)'"
  }
  $cmd = "`"$ffmpeg`" -y -i `"$($ctx.video)`" -vf $vf `"$pattern`""
  Invoke-Command $cmd $workDir $env $log | Out-Null
  Write-Success "Extracted frames -> $framesDir"
}

# --------------------- Step 2: COLMAP ---------------------
Write-Section "Step 2/4: COLMAP ($($config.colmap.mode))"
$templates = $config.colmap.templates
$denseFlag = if ($config.colmap.dense) {1} else {0}
$cmEnv = $env.Clone()

if ($config.colmap.mode -eq "automatic") {
  $cmd = Expand-TemplateString $templates.automatic (@{
    colmap_bat   = $ctx.colmap_bat
    frames_dir   = $ctx.frames_dir
    colmap_dir   = $ctx.colmap_dir
    dense        = $denseFlag
    single_camera= (ConvertTo-BinaryInt $config.colmap.single_camera)
  })
  Invoke-Command $cmd $workDir $cmEnv $log | Out-Null
  Write-Success "COLMAP automatic reconstruction complete."
} else {
  # Manual pipeline
  $cmd1 = Expand-TemplateString $templates.feature_extractor (@{
    colmap_bat = $ctx.colmap_bat; db = $ctx.db; frames_dir = $ctx.frames_dir;
    single_camera = (ConvertTo-BinaryInt $config.colmap.single_camera);
    sift_threads  = $config.colmap.sift_threads
  })
  Invoke-Command $cmd1 $colmapDir $cmEnv $log | Out-Null

  $cmd2 = Expand-TemplateString $templates.matcher (@{
    colmap_bat = $ctx.colmap_bat; db = $ctx.db
  })
  Invoke-Command $cmd2 $colmapDir $cmEnv $log | Out-Null

  $cmd3 = Expand-TemplateString $templates.mapper (@{
    colmap_bat = $ctx.colmap_bat; db = $ctx.db; frames_dir = $ctx.frames_dir;
    sparse_dir = $ctx.sparse_dir; mapper_num_threads = $config.colmap.mapper_num_threads
  })
  Invoke-Command $cmd3 $colmapDir $cmEnv $log | Out-Null

  $cmd4 = Expand-TemplateString $templates.undistort (@{
    colmap_bat = $ctx.colmap_bat; frames_dir = $ctx.frames_dir;
    sparse_dir = $ctx.sparse_dir; undist_dir = $ctx.undist_dir
  })
  Invoke-Command $cmd4 $colmapDir $cmEnv $log | Out-Null

  Write-Success "COLMAP manual pipeline complete."
}

# --------------------- Step 3: Train ---------------------
Write-Section "Step 3/4: Train"

switch ($config.pipeline) {
  'lichtfeld' {
    $lf = $config.lichtfeld
    # Merge args with optional args_from_file
    $trainArgs = $lf.train.args.Clone()
    $trainArgs = Merge-ArgumentsFromFile $trainArgs $lf.train.args_from_file
    # Swap {seed} if present
    foreach ($k in @($trainArgs.Keys)) {
      if ("$($trainArgs[$k])" -eq "{seed}") { $trainArgs[$k] = $ctx.seed }
    }
    $trainCmd = Expand-TemplateString $lf.train.command $ctx
    $trainCmd = "$trainCmd $(ConvertTo-ArgString $trainArgs)"
    Invoke-Command $trainCmd $lfTrainDir $env $log | Out-Null
    Write-Success "Training completed (LichtFeld). Model -> $modelDir"
  }

  'nerfstudio' {
    $ns = $config.nerfstudio

    # Prepare (ns-process-data)
    $prepCmd = Expand-TemplateString $ns.prepare.command (@{
      video = $ctx.video; ns_data_dir = $ctx.ns_data_dir; fps = $fps
    })
    if ($ns.prepare.args) { $prepCmd = "$prepCmd $(ConvertTo-ArgString $ns.prepare.args)" }
    Invoke-Command $prepCmd $workDir $env $log | Out-Null

    # Train
    $trainCmd = Expand-TemplateString $ns.train.command (@{
      ns_data_dir = $ctx.ns_data_dir; ns_out_dir = $ctx.ns_out_dir
    })
    if ($ns.train.args) { $trainCmd = "$trainCmd $(ConvertTo-ArgString $ns.train.args)" }
    Invoke-Command $trainCmd $workDir $env $log | Out-Null

    Write-Success "Training completed (Nerfstudio)."
  }

  default { throw "Unknown pipeline: $($config.pipeline)" }
}

# --------------------- Step 4: Export splat ---------------------
Write-Section "Step 4/4: Export Gaussian Splat"

switch ($config.pipeline) {
  'lichtfeld' {
    $lf = $config.lichtfeld
    $expArgs = $lf.export.args.Clone()
    $expArgs = Merge-ArgumentsFromFile $expArgs $lf.export.args_from_file

    $expCmd = Expand-TemplateString $lf.export.command $ctx
    $expCmd = "$expCmd $(ConvertTo-ArgString $expArgs)"
    Invoke-Command $expCmd $workDir $env $log | Out-Null

    Write-Success "Exported Gaussian splat -> $splatPath"
  }

  'nerfstudio' {
    $ns = $config.nerfstudio
    $expCmd = Expand-TemplateString $ns.export.command (@{
      ns_out_dir = $ctx.ns_out_dir; splat_path = $ctx.splat_path
    })
    if ($ns.export.args) { $expCmd = "$expCmd $(ConvertTo-ArgString $ns.export.args)" }
    Invoke-Command $expCmd $workDir $env $log | Out-Null
    Write-Success "Exported Gaussian splat -> $splatPath"
  }
}

# --------------------- Result manifest ---------------------
Write-Section "Done"
$result = @{
  project   = $projName
  work_dir  = $workDir
  video     = $video
  frames    = $framesDir
  colmap    = $colmapDir
  model_dir = $modelDir
  output    = $splatPath
  log       = $log
  pipeline  = $config.pipeline
}
$resultJson = ($result | ConvertTo-Json -Depth 5)
$resultPath = Join-Path $outDir "result.json"
$resultJson | Set-Content -Encoding UTF8 -LiteralPath $resultPath
Write-Success "Result manifest: $resultPath"
