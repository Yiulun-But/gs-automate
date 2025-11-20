<# 
.SYNOPSIS
  Orchestrate MP4 -> frames -> COLMAP -> (train) -> export Gaussian splat
  Default pipeline is LichtFeld Studio; Nerfstudio supported as optional fallback.

.PARAMETER Config
  Path to JSON config file (see template via -InitConfig).

.PARAMETER InitConfig
  Write a config template to this path and exit.

.PARAMETER DryRun
  Print what would run, but don’t execute.

.PARAMETER Force
  Re-run steps even if outputs exist.

.PARAMETER ShowOutput
  Display stdout/stderr from COLMAP, LichtFeld, and Nerfstudio in real-time.

.PARAMETER StartFrom
  Start pipeline from a specific stage: extract, colmap, train, or export.
  Prerequisites from earlier stages must exist. Default is 'extract'.

.NOTES
  Assumes:
    - CUDA is installed (or specify in tools.cuda.home)
    - COLMAP .bat path provided (tools.colmap.bat)
    - ffmpeg available (tools.ffmpeg.path or on PATH)
    - LichtFeld Studio CLI provided (tools.lichtfeld.exe)
#>

[CmdletBinding()]
param(
  [string]$Config,
  [string]$InitConfig,
  [switch]$DryRun,
  [switch]$Force,
  [switch]$ShowOutput,
  [ValidateSet('extract', 'colmap', 'train', 'export')]
  [string]$StartFrom = 'extract'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Step($t)    { Write-Host "[*] $t" -ForegroundColor Yellow }
function Write-OK($t)      { Write-Host "[OK] $t" -ForegroundColor Green }
function Write-Err($t)     { Write-Host "[ERR] $t" -ForegroundColor Red }

# ---------- JSON helpers (PS 5.1 compatible) ----------

function ConvertTo-Hashtable($obj) {
  if ($null -eq $obj) { return $null }
  if ($obj -is [System.Collections.IDictionary]) {
    $ht = @{}
    foreach ($k in $obj.Keys) { $ht[$k] = ConvertTo-Hashtable $obj[$k] }
    return $ht
  }
  if ($obj -is [pscustomobject]) {
    $ht = @{}
    $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = ConvertTo-Hashtable $_.Value }
    return $ht
  }
  if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
    $list = @()
    foreach ($item in $obj) { $list += ,(ConvertTo-Hashtable $item) }
    return $list
  }
  return $obj
}

# Allow // and /* */ comments in JSON; always return hashtable
function ConvertFrom-JsonFile($path) {
  if (-not (Test-Path $path)) { throw "Config not found: $path" }
  $raw = Get-Content -Raw -LiteralPath $path
  $raw = [regex]::Replace($raw, '(?s)/\*.*?\*/|//.*(?=\r?$)', '')
  $obj = $raw | ConvertFrom-Json
  ConvertTo-Hashtable $obj
}

# ---------- Utilities ----------

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
    "ffmpeg":    { "path": "ffmpeg" },
    "colmap":    { "bat":  "C:/Program Files/COLMAP/colmap.bat" },
    "lichtfeld": { "exe":  "C:/Program Files/LichtFeld Studio/LichtFeld.exe" },
    "cuda":      { "home": null }
  },

  "pipeline": "lichtfeld",  // or "nerfstudio"

  "extract": {
    "fps": 2,
    "resize_long_edge": 1080,
    "image_ext": "png",
    "skip_if_exists": true,
    // optional: if your source is rotated, set transpose to 1|2|3 (see ffmpeg transpose)
    "transpose": null
  },

  "colmap": {
    "mode": "automatic",  // "automatic" or "manual"
    "db_name": "database.db",
    "single_camera": true,
    "sift_threads": 8,
    "mapper_num_threads": 8,
    "dense": false,
    "matcher_type": "sequential",  // "sequential" (fast, for video), "exhaustive" (thorough), or "vocab_tree" (large datasets)

    "templates": {
      "automatic": "\"{colmap_bat}\" automatic_reconstructor --workspace_path \"{colmap_dir}\" --image_path \"{frames_dir}\" --dense {dense} --single_camera {single_camera}",
      "feature_extractor": "\"{colmap_bat}\" feature_extractor --database_path \"{db}\" --image_path \"{frames_dir}\" --ImageReader.single_camera {single_camera} --SiftExtraction.num_threads {sift_threads}",
      "sequential_matcher": "\"{colmap_bat}\" sequential_matcher --database_path \"{db}\" --SequentialMatching.loop_detection 1",
      "exhaustive_matcher": "\"{colmap_bat}\" exhaustive_matcher --database_path \"{db}\"",
      "vocab_tree_matcher": "\"{colmap_bat}\" vocab_tree_matcher --database_path \"{db}\" --VocabTreeMatching.vocab_tree_path \"{vocab_tree_path}\"",
      "mapper": "\"{colmap_bat}\" mapper --database_path \"{db}\" --image_path \"{frames_dir}\" --output_path \"{sparse_dir}\" --Mapper.num_threads {mapper_num_threads}",
      "undistort": "\"{colmap_bat}\" image_undistorter --image_path \"{frames_dir}\" --input_path \"{sparse_dir}/0\" --output_path \"{undist_dir}\" --output_type COLMAP"
    }
  },

  "lichtfeld": {
    "train": {
      "work_dir_name": "lf_train",
      "command": "\"{lichtfeld_exe}\" -d \"{data_dir}\" -o \"{model_dir}\"",
      "args": {
        "iter": 30000,
        "resize_factor": 1,
        "strategy": "mcmc",
        "max-cap": 1000000,
        "headless": true,
        "eval": false,
        "save-eval-images": false,
        "test-every": 8
      },
      "args_from_file": null
    },
    "export": {
      "command": "echo LichtFeld exports during training. Check model_dir for .ply files",
      "args": {},
      "args_from_file": null
    }
  },

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
  Write-OK "Wrote template: $InitConfig"
  return
}

if (-not $Config) { throw "Provide -Config <path to json> or -InitConfig to generate one." }

function Initialize-Directory($p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  (Resolve-Path $p).Path
}

function ConvertTo-BinaryInt($b) { if ($b -is [bool]) { if ($b) {1} else {0} } else { $b } }
function Copy-Hashtable([hashtable]$h) { $n=@{}; if ($h){ foreach ($k in $h.Keys){ $n[$k]=$h[$k] } }; return $n }

# Argument aliases for LichtFeld Studio CLI (maps config keys to CLI flags)
$script:LichtFeldArgAliases = @{
  'iter'          = '-i'
  'data-path'     = '-d'
  'output-path'   = '-o'
  'resize_factor' = '-r'
}

function ConvertTo-ArgString([hashtable]$kv, [hashtable]$aliases = $null) {
  if (-not $kv) { return "" }
  $parts = @()
  foreach ($k in $kv.Keys) {
    $v = $kv[$k]
    # Determine the flag to use (alias or default --key format)
    $flag = if ($aliases -and $aliases.ContainsKey($k)) { $aliases[$k] } else { "--$k" }

    if ($v -is [bool]) {
      if ($v) { $parts += $flag }
    } elseif ($null -eq $v -or $v -eq "") {
      # skip
    } else {
      $vstr = "$v"
      if ($vstr -match '\s' -or $vstr -match '[\\"]') { $vstr = '"' + $vstr.Replace('"','\"') + '"' }
      $parts += "$flag $vstr"
    }
  }
  ($parts -join ' ')
}

function Merge-ArgumentsFromFile([hashtable]$base,[string]$file) {
  if (-not $file) { return $base }
  if (-not (Test-Path $file)) { throw "args_from_file not found: $file" }
  $extra = ConvertFrom-JsonFile $file
  foreach ($k in $extra.Keys) { $base[$k] = $extra[$k] }
  $base
}

function Expand-TemplateString([string]$template,[hashtable]$ctx) {
  $expanded = $template
  foreach ($key in $ctx.Keys) {
    $val = [string]$ctx[$key]
    $expanded = $expanded.Replace("{$key}", $val)
  }
  $expanded
}

# --- Stage management ---

$script:StageOrder = @{
  'extract' = 1
  'colmap'  = 2
  'train'   = 3
  'export'  = 4
}

function Test-ShouldRunStage([string]$stage) {
  $stageNum = $script:StageOrder[$stage]
  $startNum = $script:StageOrder[$StartFrom]
  return $stageNum -ge $startNum
}

function Test-StagePrerequisites([string]$stage, [string]$framesDir, [string]$undistDir, [string]$modelDir) {
  switch ($stage) {
    'colmap' {
      # Requires frames from extract stage
      if (-not (Test-Path $framesDir)) {
        throw "Cannot start from 'colmap': frames directory not found at: $framesDir`nRun the 'extract' stage first."
      }
      $frameCount = (Get-ChildItem -Path $framesDir -File -ErrorAction SilentlyContinue | Measure-Object).Count
      if ($frameCount -eq 0) {
        throw "Cannot start from 'colmap': no frames found in: $framesDir`nRun the 'extract' stage first."
      }
      Write-Step "Prerequisite check: Found $frameCount frames in $framesDir"
    }
    'train' {
      # Requires COLMAP undistorted output
      $colmapImages = Join-Path $undistDir "images"
      $colmapSparse = Join-Path $undistDir "sparse"

      if (-not (Test-Path $colmapImages)) {
        throw "Cannot start from 'train': COLMAP undistorted images not found at: $colmapImages`nRun the 'colmap' stage first."
      }
      $imageCount = (Get-ChildItem -Path $colmapImages -File -ErrorAction SilentlyContinue | Measure-Object).Count
      if ($imageCount -eq 0) {
        throw "Cannot start from 'train': no images in COLMAP output: $colmapImages`nRun the 'colmap' stage first."
      }
      if (-not (Test-Path $colmapSparse)) {
        throw "Cannot start from 'train': COLMAP sparse data not found at: $colmapSparse`nRun the 'colmap' stage first."
      }
      Write-Step "Prerequisite check: Found $imageCount undistorted images"
    }
    'export' {
      # Requires trained model
      if (-not (Test-Path $modelDir)) {
        throw "Cannot start from 'export': model directory not found at: $modelDir`nRun the 'train' stage first."
      }
      $plyFiles = Get-ChildItem -Path $modelDir -Filter "*.ply" -ErrorAction SilentlyContinue
      if ($plyFiles.Count -eq 0) {
        throw "Cannot start from 'export': no .ply files found in model directory: $modelDir`nRun the 'train' stage first."
      }
      Write-Step "Prerequisite check: Found $($plyFiles.Count) .ply file(s) in model directory"
    }
  }
}

# --- Process invocation helpers ---

function Quote-Arg([string]$s) {
  if ($s -match '[\s"]') { return '"' + $s.Replace('"','""') + '"' }
  return $s
}

function Invoke-Process([string]$exe, [string[]]$argv, [string]$workdir, [hashtable]$env, [string]$logFile) {
  $exePrintable = $exe
  if ($exePrintable -match '[\s"]') { $exePrintable = '"' + $exePrintable + '"' }
  $argStr = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '
  Write-Step ("{0} {1}" -f $exePrintable, $argStr)

  if ($DryRun) { return 0 }

  if ($logFile) { ">>> $exe $argStr`n" | Add-Content -Encoding UTF8 -LiteralPath $logFile }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = $exe
  $psi.Arguments = $argStr
  $psi.WorkingDirectory = $workdir
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  if ($env) { foreach ($k in $env.Keys) { $psi.Environment[$k] = "$($env[$k])" } }

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  $null = $p.Start()

  # Create synchronized collections for real-time output (PS 5.1 compatible)
  $outLines = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
  $errLines = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

  # Read stdout in a runspace
  $rsOut = [runspacefactory]::CreateRunspace()
  $rsOut.Open()
  $rsOut.SessionStateProxy.SetVariable('stream', $p.StandardOutput)
  $rsOut.SessionStateProxy.SetVariable('lines', $outLines)

  $psOut = [powershell]::Create()
  $psOut.Runspace = $rsOut
  $null = $psOut.AddScript({
    while (-not $stream.EndOfStream) {
      $line = $stream.ReadLine()
      if ($line) { $null = $lines.Add($line) }
    }
  })
  $handleOut = $psOut.BeginInvoke()

  # Read stderr in a runspace
  $rsErr = [runspacefactory]::CreateRunspace()
  $rsErr.Open()
  $rsErr.SessionStateProxy.SetVariable('stream', $p.StandardError)
  $rsErr.SessionStateProxy.SetVariable('lines', $errLines)

  $psErr = [powershell]::Create()
  $psErr.Runspace = $rsErr
  $null = $psErr.AddScript({
    while (-not $stream.EndOfStream) {
      $line = $stream.ReadLine()
      if ($line) { $null = $lines.Add($line) }
    }
  })
  $handleErr = $psErr.BeginInvoke()

  # Monitor output in real-time from main thread
  $outIdx = 0
  $errIdx = 0
  while (-not $p.HasExited -or $outIdx -lt $outLines.Count -or $errIdx -lt $errLines.Count) {
    # Display new stdout lines
    while ($outIdx -lt $outLines.Count) {
      if ($ShowOutput) { Write-Host $outLines[$outIdx] }
      $outIdx++
    }
    # Display new stderr lines
    while ($errIdx -lt $errLines.Count) {
      if ($ShowOutput) { Write-Host $errLines[$errIdx] -ForegroundColor Yellow }
      $errIdx++
    }
    if (-not $p.HasExited) { Start-Sleep -Milliseconds 50 }
  }

  $p.WaitForExit()

  # Wait for runspaces to finish
  $null = $psOut.EndInvoke($handleOut)
  $null = $psErr.EndInvoke($handleErr)

  # Display any remaining lines
  while ($outIdx -lt $outLines.Count) {
    if ($ShowOutput) { Write-Host $outLines[$outIdx] }
    $outIdx++
  }
  while ($errIdx -lt $errLines.Count) {
    if ($ShowOutput) { Write-Host $errLines[$errIdx] -ForegroundColor Yellow }
    $errIdx++
  }

  # Cleanup
  $psOut.Dispose()
  $psErr.Dispose()
  $rsOut.Close()
  $rsErr.Close()

  $stdout = ($outLines -join "`n")
  $stderr = ($errLines -join "`n")

  if ($logFile) {
    $stdout | Add-Content -Encoding UTF8 -LiteralPath $logFile
    if ($stderr) { "`n[stderr]`n$stderr`n" | Add-Content -Encoding UTF8 -LiteralPath $logFile }
  }
  if ($p.ExitCode -ne 0) {
    Write-Error "ExitCode=$($p.ExitCode)"
    if ($stderr) { Write-Error $stderr }
    throw "Invoke-Process failed."
  }
  return $p.ExitCode
}

function Invoke-External([string]$cmd, [string]$workdir, [hashtable]$env, [string]$logFile) {
  Write-Step $cmd
  if ($DryRun) { return 0 }
  if ($logFile) { ">>> $cmd`n" | Add-Content -Encoding UTF8 -LiteralPath $logFile }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = "cmd.exe"
  $psi.Arguments = '/c "' + $cmd + '"'
  $psi.WorkingDirectory = $workdir
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  if ($env) { foreach ($k in $env.Keys) { $psi.Environment[$k] = "$($env[$k])" } }

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  $null = $p.Start()

  # Create synchronized collections for real-time output (PS 5.1 compatible)
  $outLines = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
  $errLines = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

  # Read stdout in a runspace
  $rsOut = [runspacefactory]::CreateRunspace()
  $rsOut.Open()
  $rsOut.SessionStateProxy.SetVariable('stream', $p.StandardOutput)
  $rsOut.SessionStateProxy.SetVariable('lines', $outLines)

  $psOut = [powershell]::Create()
  $psOut.Runspace = $rsOut
  $null = $psOut.AddScript({
    while (-not $stream.EndOfStream) {
      $line = $stream.ReadLine()
      if ($line) { $null = $lines.Add($line) }
    }
  })
  $handleOut = $psOut.BeginInvoke()

  # Read stderr in a runspace
  $rsErr = [runspacefactory]::CreateRunspace()
  $rsErr.Open()
  $rsErr.SessionStateProxy.SetVariable('stream', $p.StandardError)
  $rsErr.SessionStateProxy.SetVariable('lines', $errLines)

  $psErr = [powershell]::Create()
  $psErr.Runspace = $rsErr
  $null = $psErr.AddScript({
    while (-not $stream.EndOfStream) {
      $line = $stream.ReadLine()
      if ($line) { $null = $lines.Add($line) }
    }
  })
  $handleErr = $psErr.BeginInvoke()

  # Monitor output in real-time from main thread
  $outIdx = 0
  $errIdx = 0
  while (-not $p.HasExited -or $outIdx -lt $outLines.Count -or $errIdx -lt $errLines.Count) {
    # Display new stdout lines
    while ($outIdx -lt $outLines.Count) {
      if ($ShowOutput) { Write-Host $outLines[$outIdx] }
      $outIdx++
    }
    # Display new stderr lines
    while ($errIdx -lt $errLines.Count) {
      if ($ShowOutput) { Write-Host $errLines[$errIdx] -ForegroundColor Yellow }
      $errIdx++
    }
    if (-not $p.HasExited) { Start-Sleep -Milliseconds 50 }
  }

  $p.WaitForExit()

  # Wait for runspaces to finish
  $null = $psOut.EndInvoke($handleOut)
  $null = $psErr.EndInvoke($handleErr)

  # Display any remaining lines
  while ($outIdx -lt $outLines.Count) {
    if ($ShowOutput) { Write-Host $outLines[$outIdx] }
    $outIdx++
  }
  while ($errIdx -lt $errLines.Count) {
    if ($ShowOutput) { Write-Host $errLines[$errIdx] -ForegroundColor Yellow }
    $errIdx++
  }

  # Cleanup
  $psOut.Dispose()
  $psErr.Dispose()
  $rsOut.Close()
  $rsErr.Close()

  $stdout = ($outLines -join "`n")
  $stderr = ($errLines -join "`n")

  if ($logFile) {
    $stdout | Add-Content -Encoding UTF8 -LiteralPath $logFile
    if ($stderr) { "`n[stderr]`n$stderr`n" | Add-Content -Encoding UTF8 -LiteralPath $logFile }
  }
  if ($p.ExitCode -ne 0) {
    Write-Error "ExitCode=$($p.ExitCode)"
    if ($stderr) { Write-Error $stderr }
    throw "Invoke-External failed."
  }
  return $p.ExitCode
}

# ---------- Load & validate config ----------

$cfg = ConvertFrom-JsonFile $Config

Write-Section "Config Parse Diagnostics"
if ($null -eq $cfg) { throw "Config parse produced `$null. Check JSON syntax." }
"{0,-28}: {1}" -f "Parsed .NET type", $cfg.GetType().FullName | Write-Host
if ($cfg -is [hashtable]) {
  "{0,-28}: {1}" -f "Top-level keys", (@($cfg.Keys) -join ', ') | Write-Host
} else {
  "{0,-28}: {1}" -f "Top-level keys", "<not a dictionary>" | Write-Host
}

foreach ($req in @('project','tools','pipeline','extract','colmap')) {
  if (-not $cfg.ContainsKey($req)) { throw "Config missing top-level key: `"$req`"" }
}

$proj = $cfg['project']
foreach ($req in @('name','work_dir','video')) {
  if (-not $proj.ContainsKey($req)) { throw "project.$req missing in config" }
}
$projName = $proj['name']
$workDir  = Initialize-Directory $proj['work_dir']
$video    = $proj['video']
$seed     = if ($proj.ContainsKey('seed')) { $proj['seed'] } else { 42 }

if (-not (Test-Path $video)) { throw "Video not found: $video" }

$tools        = $cfg['tools']
foreach ($req in @('ffmpeg','colmap','lichtfeld','cuda')) {
  if (-not $tools.ContainsKey($req)) { throw "tools.$req missing in config" }
}

$ffmpeg       = $tools['ffmpeg']['path']
$colmapBat    = $tools['colmap']['bat']
$lichtfeldExe = $tools['lichtfeld']['exe']
$cudaHome     = $tools['cuda']['home']

if (-not $ffmpeg) { $ffmpeg = "ffmpeg" }
if (-not (Get-Command $ffmpeg -ErrorAction SilentlyContinue)) {
  if (-not (Test-Path $ffmpeg)) { throw "ffmpeg not found or not on PATH. Provide tools.ffmpeg.path" }
}
if (-not (Test-Path $colmapBat)) { throw "COLMAP .bat not found: $colmapBat" }
if ($lichtfeldExe -and -not (Test-Path $lichtfeldExe)) { throw "LichtFeld executable not found: $lichtfeldExe" }
if ($cudaHome -and -not (Test-Path $cudaHome)) { throw "CUDA home not found: $cudaHome" }

# Project structure
$logDir     = Initialize-Directory (Join-Path $workDir "logs")
$log        = Join-Path $logDir "run-$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$framesDir  = Initialize-Directory (Join-Path $workDir "frames")
$colmapDir  = Initialize-Directory (Join-Path $workDir "colmap")
$sparseDir  = Initialize-Directory (Join-Path $colmapDir "sparse")
$undistDir  = Initialize-Directory (Join-Path $colmapDir "undistorted")
$dbPath     = Join-Path $colmapDir ($cfg['colmap']['db_name'])

$lfWorkDirName = "lf_train"
if ($cfg.ContainsKey('lichtfeld') -and $cfg['lichtfeld'] -and
    $cfg['lichtfeld'].ContainsKey('train') -and $cfg['lichtfeld']['train'] -and
    $cfg['lichtfeld']['train'].ContainsKey('work_dir_name') -and
    $cfg['lichtfeld']['train']['work_dir_name']) {
  $lfWorkDirName = $cfg['lichtfeld']['train']['work_dir_name']
}
$lfTrainDir = Initialize-Directory (Join-Path $workDir $lfWorkDirName)

$modelDir   = Initialize-Directory (Join-Path $lfTrainDir "model")
$outDir     = Initialize-Directory (Join-Path $workDir "output")
$splatPath  = Join-Path $outDir "$($projName)_gaussians.ply"
$nsDataDir  = Initialize-Directory (Join-Path $workDir "ns_data")
$nsOutDir   = Initialize-Directory (Join-Path $workDir "ns_train")

# Subprocess environment
$procEnv = @{}
if ($cudaHome) {
  $procEnv["CUDA_HOME"] = $cudaHome
  $procEnv["PATH"] = "$cudaHome\bin;$cudaHome\libnvvp;$($env:PATH)"
}
if ($env:CUDA_VISIBLE_DEVICES) { $procEnv["CUDA_VISIBLE_DEVICES"] = $env:CUDA_VISIBLE_DEVICES }
$procEnv["PYTHONIOENCODING"] = "utf-8"
$procEnv["PYTHONUTF8"] = "1"

# Paths for template expansion
$lichtfeldPath = ""
if ($lichtfeldExe) { $lichtfeldPath = (Resolve-Path $lichtfeldExe).Path }

$ctx = @{
  project       = $projName
  work_dir      = $workDir
  video         = (Resolve-Path $video).Path
  frames_dir    = $framesDir
  colmap_dir    = $colmapDir
  sparse_dir    = $sparseDir
  undist_dir    = $undistDir
  db            = $dbPath
  colmap_bat    = (Resolve-Path $colmapBat).Path
  lichtfeld_exe = $lichtfeldPath
  model_dir     = $modelDir
  data_dir      = $undistDir    # LichtFeld expects undistorted images
  ns_data_dir   = $nsDataDir
  ns_out_dir    = $nsOutDir
  splat_path    = $splatPath
  seed          = $seed
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
  Pipeline  = $cfg['pipeline']
  StartFrom = $StartFrom
}
$summary.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0,-10} : {1}" -f $_.Name, $_.Value } | Tee-Object -FilePath $log -Append | Out-Null

# Validate prerequisites if starting from a later stage
if ($StartFrom -ne 'extract') {
  Write-Section "Prerequisite Validation"
  Test-StagePrerequisites $StartFrom $framesDir $undistDir $modelDir
  Write-OK "Prerequisites validated for starting from '$StartFrom'"
}

# ---------- Step 1: Extract frames ----------
if (Test-ShouldRunStage 'extract') {
  Write-Section "Step 1/4: Extract frames with ffmpeg"
  $extract  = $cfg['extract']
  $imgExt   = $extract['image_ext']
  $fps      = [int]$extract['fps']
  $longEdge = [int]$extract['resize_long_edge']
  $pattern  = Join-Path $framesDir ("frame_%05d.$imgExt")
  $already  = Get-ChildItem -Path $framesDir -Filter "*.$imgExt" -ErrorAction SilentlyContinue | Measure-Object
  $skip     = $extract['skip_if_exists'] -and ($already.Count -gt 0) -and (-not $Force)

  if ($skip) {
    Write-OK "Skipping extraction (frames already exist)."
  } else {
    # Robust Windows-safe filtergraph (no if()): keep aspect ratio, fit within longEdge box
    $vfParts = @()
    $vfParts += ('fps={0}' -f $fps)
    if ($longEdge -gt 0) {
      $vfParts += ('scale={0}:{0}:force_original_aspect_ratio=decrease' -f $longEdge)
    }
    if ($extract.ContainsKey('transpose') -and $null -ne $extract['transpose'] -and "$($extract['transpose'])" -ne "") {
      $vfParts += ('transpose={0}' -f $extract['transpose'])
    }
    $vf = ($vfParts -join ',')

    # Prefer direct invocation (no cmd), then fallback with cmd.exe (%% escaping for %05d)
    $ffArgs = @('-y','-i', $ctx['video'], '-vf', $vf, $pattern)
    $didFallback = $false
    try {
      Invoke-Process $ffmpeg $ffArgs $workDir $procEnv $log | Out-Null
    } catch {
      Write-Err "ffmpeg failed via direct invocation; retrying through cmd.exe wrapper..."
      $didFallback = $true
      $patternCmd = $pattern -replace '%','%%'
      $cmd = ('{0} -y -i "{1}" -vf "{2}" "{3}"' -f $ffmpeg, $ctx['video'], $vf, $patternCmd)
      Invoke-External $cmd $workDir $procEnv $log | Out-Null
    }
    $suffix = ""
    if ($didFallback) { $suffix = " (via cmd.exe)" }
    Write-OK ("Extracted frames -> {0}{1}" -f $framesDir, $suffix)
  }
} else {
  Write-Section "Step 1/4: Extract frames with ffmpeg"
  Write-OK "Skipping (starting from '$StartFrom')"
}

# ---------- Step 2: COLMAP ----------
if (Test-ShouldRunStage 'colmap') {
  Write-Section "Step 2/4: COLMAP ($($cfg['colmap']['mode']))"
  $colmapCfg = $cfg['colmap']
  $templates = $colmapCfg['templates']
  $denseFlag = if ($colmapCfg['dense']) {1} else {0}

  # Check if COLMAP output already exists
  $colmapDone = (Test-Path (Join-Path $undistDir "images")) -and
                (Test-Path (Join-Path $undistDir "sparse")) -and
                (Get-ChildItem -Path (Join-Path $undistDir "images") -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0

  if ($colmapDone -and -not $Force) {
    Write-OK "Skipping COLMAP (output already exists: $undistDir). Use -Force to re-run."
  } else {
    if ($colmapCfg['mode'] -eq "automatic") {
      $cmd = Expand-TemplateString $templates['automatic'] @{
        colmap_bat    = $ctx['colmap_bat']
        frames_dir    = $ctx['frames_dir']
        colmap_dir    = $ctx['colmap_dir']
        dense         = $denseFlag
        single_camera = (ConvertTo-BinaryInt $colmapCfg['single_camera'])
      }
      Invoke-External $cmd $workDir $procEnv $log | Out-Null
      Write-OK "COLMAP automatic reconstruction complete."

      # Ensure undistorted images exist for training (LichtFeld expects undistorted)
      $undistCmd = Expand-TemplateString $templates['undistort'] @{
        colmap_bat = $ctx['colmap_bat']; frames_dir = $ctx['frames_dir'];
        sparse_dir = $ctx['sparse_dir']; undist_dir = $ctx['undist_dir']
      }
      Invoke-External $undistCmd $colmapDir $procEnv $log | Out-Null
      Write-OK "COLMAP undistortion complete -> $undistDir"
    } else {
    $cmd1 = Expand-TemplateString $templates['feature_extractor'] @{
      colmap_bat = $ctx['colmap_bat']; db = $ctx['db']; frames_dir = $ctx['frames_dir'];
      single_camera = (ConvertTo-BinaryInt $colmapCfg['single_camera']);
      sift_threads  = $colmapCfg['sift_threads']
    }
    Invoke-External $cmd1 $colmapDir $procEnv $log | Out-Null

    # Select matcher based on matcher_type config
    $matcherType = if ($colmapCfg.ContainsKey('matcher_type')) { $colmapCfg['matcher_type'] } else { 'sequential' }
    $matcherTemplate = "${matcherType}_matcher"
    if (-not $templates.ContainsKey($matcherTemplate)) {
      throw "Unknown matcher_type: '$matcherType'. Valid options: sequential, exhaustive, vocab_tree"
    }
    Write-Step "Using $matcherType matcher"
    $cmd2 = Expand-TemplateString $templates[$matcherTemplate] @{
      colmap_bat = $ctx['colmap_bat']; db = $ctx['db']
    }
    Invoke-External $cmd2 $colmapDir $procEnv $log | Out-Null

    $cmd3 = Expand-TemplateString $templates['mapper'] @{
      colmap_bat = $ctx['colmap_bat']; db = $ctx['db']; frames_dir = $ctx['frames_dir'];
      sparse_dir = $ctx['sparse_dir']; mapper_num_threads = $colmapCfg['mapper_num_threads']
    }
    Invoke-External $cmd3 $colmapDir $procEnv $log | Out-Null

    $cmd4 = Expand-TemplateString $templates['undistort'] @{
      colmap_bat = $ctx['colmap_bat']; frames_dir = $ctx['frames_dir'];
      sparse_dir = $ctx['sparse_dir']; undist_dir = $ctx['undist_dir']
    }
    Invoke-External $cmd4 $colmapDir $procEnv $log | Out-Null

    Write-OK "COLMAP manual pipeline complete."
    }
  }
} else {
  Write-Section "Step 2/4: COLMAP"
  Write-OK "Skipping (starting from '$StartFrom')"
}

# ---------- Step 3: Train ----------
if (Test-ShouldRunStage 'train') {
  Write-Section "Step 3/4: Train"

  # Pre-flight validation: verify COLMAP output before training
  Write-Step "Running pre-flight validation..."
  $colmapImages = Join-Path $undistDir "images"
  $colmapSparse = Join-Path $undistDir "sparse"

  if (-not (Test-Path $colmapImages)) {
    throw "Pre-flight failed: COLMAP undistorted images directory not found at: $colmapImages`nRun COLMAP step first or check for errors in the COLMAP output."
  }

  $imageFiles = Get-ChildItem -Path $colmapImages -File -ErrorAction SilentlyContinue
  $imageCount = ($imageFiles | Measure-Object).Count
  if ($imageCount -eq 0) {
    throw "Pre-flight failed: No images found in COLMAP output directory: $colmapImages`nCOLMAP may have failed to undistort images."
  }

  if (-not (Test-Path $colmapSparse)) {
    throw "Pre-flight failed: COLMAP sparse reconstruction not found at: $colmapSparse`nCOLMAP reconstruction may have failed."
  }

  # Check for essential COLMAP files (cameras, images, points)
  $sparseFiles = Get-ChildItem -Path $colmapSparse -File -ErrorAction SilentlyContinue
  $hasCameras = $sparseFiles | Where-Object { $_.Name -match '^cameras\.(bin|txt)$' }
  $hasImages = $sparseFiles | Where-Object { $_.Name -match '^images\.(bin|txt)$' }
  if (-not $hasCameras -or -not $hasImages) {
    throw "Pre-flight failed: COLMAP sparse reconstruction incomplete.`nMissing cameras or images files in: $colmapSparse"
  }

  Write-OK "Pre-flight passed: $imageCount images ready for training"

  # Check if training output already exists
  $trainDone = (Test-Path $modelDir) -and
               (Get-ChildItem -Path $modelDir -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0

  if ($trainDone -and -not $Force) {
    Write-OK "Skipping training (model already exists: $modelDir). Use -Force to re-run."
  } else {
  switch ($cfg['pipeline']) {
    'lichtfeld' {
      if (-not $lichtfeldExe) { throw "tools.lichtfeld.exe not set in config." }
      $lf = $cfg['lichtfeld']

      # Verify LichtFeld executable exists and try to get version
      if (-not (Test-Path $lichtfeldExe)) {
        throw "LichtFeld executable not found at: $lichtfeldExe"
      }

      Write-Step "Checking LichtFeld Studio..."
      try {
        $versionOutput = & $lichtfeldExe --help 2>&1 | Select-Object -First 5
        if ($versionOutput) {
          $versionLine = $versionOutput | Where-Object { $_ -match 'version|LichtFeld' } | Select-Object -First 1
          if ($versionLine) {
            Write-Step "LichtFeld: $versionLine"
          } else {
            Write-Step "LichtFeld executable verified"
          }
        }
      } catch {
        Write-Warning "Could not verify LichtFeld version: $_"
      }

      $trainArgs = Copy-Hashtable $lf['train']['args']
      $trainArgs = Merge-ArgumentsFromFile $trainArgs $lf['train']['args_from_file']
      foreach ($k in @($trainArgs.Keys)) {
        if ("$($trainArgs[$k])" -eq "{seed}") { $trainArgs[$k] = $ctx['seed'] }
      }

      $trainCmd = Expand-TemplateString $lf['train']['command'] $ctx
      # Use LichtFeld-specific argument aliases for CLI compatibility
      $trainCmd = "$trainCmd $(ConvertTo-ArgString $trainArgs $script:LichtFeldArgAliases)"

      # Execute training with error handling
      try {
        Invoke-External $trainCmd $lfTrainDir $procEnv $log | Out-Null
      } catch {
        Write-Err "LichtFeld training failed!"
        Write-Err "Command: $trainCmd"
        Write-Err "Check log for details: $log"

        # Check for common issues
        if ($_.Exception.Message -match 'CUDA|GPU|memory') {
          Write-Err "Hint: This may be a GPU/CUDA issue. Check CUDA installation and GPU memory."
        }
        if ($_.Exception.Message -match 'permission|access') {
          Write-Err "Hint: This may be a file permission issue. Check write access to output directory."
        }

        throw "LichtFeld training failed: $_"
      }

      # Verify training produced output
      $plyFiles = Get-ChildItem -Path $modelDir -Filter "*.ply" -ErrorAction SilentlyContinue
      if ($plyFiles.Count -eq 0) {
        Write-Warning "Training completed but no .ply output found in: $modelDir"
        Write-Warning "LichtFeld may have encountered an error. Check log: $log"

        # Check for checkpoint files as alternative indicator
        $ckptFiles = Get-ChildItem -Path $modelDir -Filter "*.ckpt" -ErrorAction SilentlyContinue
        if ($ckptFiles.Count -gt 0) {
          Write-Step "Found $($ckptFiles.Count) checkpoint file(s) - training may be incomplete"
        }
      } else {
        Write-OK "Training completed (LichtFeld). Model -> $modelDir ($($plyFiles.Count) .ply file(s))"
      }
    }

  'nerfstudio' {
    $ns = $cfg['nerfstudio']

    $prepCmd = Expand-TemplateString $ns['prepare']['command'] @{
      video = $ctx['video']; ns_data_dir = $ctx['ns_data_dir']; fps = $fps
    }
    if ($ns['prepare']['args']) { $prepCmd = "$prepCmd $(ConvertTo-ArgString $ns['prepare']['args'])" }
    Invoke-External $prepCmd $workDir $procEnv $log | Out-Null

    $trainCmd = Expand-TemplateString $ns['train']['command'] @{
      ns_data_dir = $ctx['ns_data_dir']; ns_out_dir = $ctx['ns_out_dir']
    }
    if ($ns['train']['args']) { $trainCmd = "$trainCmd $(ConvertTo-ArgString $ns['train']['args'])" }
    Invoke-External $trainCmd $workDir $procEnv $log | Out-Null

    Write-OK "Training completed (Nerfstudio)."
  }

  default { throw "Unknown pipeline: $($cfg['pipeline'])" }
  }
  }
} else {
  Write-Section "Step 3/4: Train"
  Write-OK "Skipping (starting from '$StartFrom')"
}

# ---------- Step 4: Export splat ----------
if (Test-ShouldRunStage 'export') {
  Write-Section "Step 4/4: Export Gaussian Splat"

switch ($cfg['pipeline']) {
  'lichtfeld' {
    # LichtFeld Studio exports .ply files automatically during training
    # Look for the output in the model directory
    $plyFiles = Get-ChildItem -Path $modelDir -Filter "*.ply" -ErrorAction SilentlyContinue
    if ($plyFiles.Count -gt 0) {
      # Copy the latest .ply file to the output directory
      $latestPly = $plyFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      Copy-Item -Path $latestPly.FullName -Destination $splatPath -Force
      Write-OK "Exported Gaussian splat -> $splatPath (copied from $($latestPly.Name))"
    } else {
      Write-Warning "No .ply files found in $modelDir. LichtFeld may not have completed successfully."
      # Still run the export command if specified (in case it's a custom command)
      $lf = $cfg['lichtfeld']
      $expArgs = Copy-Hashtable $lf['export']['args']
      $expArgs = Merge-ArgumentsFromFile $expArgs $lf['export']['args_from_file']
      $expCmd = Expand-TemplateString $lf['export']['command'] $ctx
      $expCmd = "$expCmd $(ConvertTo-ArgString $expArgs)"
      Invoke-External $expCmd $workDir $procEnv $log | Out-Null
    }
  }

  'nerfstudio' {
    $ns = $cfg['nerfstudio']
    $expCmd = Expand-TemplateString $ns['export']['command'] @{
      ns_out_dir = $ctx['ns_out_dir']; splat_path = $ctx['splat_path']
    }
    if ($ns['export']['args']) { $expCmd = "$expCmd $(ConvertTo-ArgString $ns['export']['args'])" }
    Invoke-External $expCmd $workDir $procEnv $log | Out-Null
    Write-OK "Exported Gaussian splat -> $splatPath"
  }
}
} else {
  Write-Section "Step 4/4: Export Gaussian Splat"
  Write-OK "Skipping (starting from '$StartFrom')"
}

# ---------- Result manifest ----------
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
  pipeline  = $cfg['pipeline']
}
$result | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $outDir "result.json")
Write-OK "Result manifest: $(Join-Path $outDir 'result.json')"

