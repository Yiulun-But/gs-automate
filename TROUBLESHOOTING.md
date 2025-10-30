# Troubleshooting Guide

## Common Issues

### Error: "& was unexpected at this time"

**Cause:** The `&` operator is being used in command templates in your config file.

**Why this happens:** Commands are executed through `cmd.exe`, not PowerShell. The `&` operator is PowerShell-specific and causes errors in `cmd.exe`.

**Solution:** Remove all `&` operators from your config file's command templates:

**WRONG:**
```json
"command": "& \"{lichtfeld_exe}\" train --data \"{data_dir}\" --output \"{model_dir}\""
```

**CORRECT:**
```json
"command": "\"{lichtfeld_exe}\" train --data \"{data_dir}\" --output \"{model_dir}\""
```

**Where to check:**
- `colmap.templates.*` - All COLMAP command templates
- `lichtfeld.train.command` - LichtFeld training command
- `lichtfeld.export.command` - LichtFeld export command
- `nerfstudio.*.command` - All Nerfstudio commands

### Script Hangs During Execution

**Use `-ShowOutput` flag to see real-time progress:**
```powershell
.\make_splat.ps1 -Config my_config.json -ShowOutput
```

This displays stdout/stderr in real-time so you can monitor what's happening.

### COLMAP Takes Too Long

**Check your thread settings in config:**
```json
"sift_threads": 8,        // Increase to match CPU core count
"mapper_num_threads": 8   // Increase to match CPU core count
```

**Skip COLMAP if already completed:**
The script now automatically skips COLMAP if output exists. Delete the `colmap/undistorted/` directory to force re-run, or use `-Force` flag.

### Training Takes Too Long

**The script now skips training if model exists:**
Delete the model directory to force re-training, or use `-Force` flag:
```powershell
.\make_splat.ps1 -Config my_config.json -Force
```

### Commands Not Found

**Ensure paths are correctly set in config:**
```json
"tools": {
  "ffmpeg": { "path": "ffmpeg" },  // or full path
  "colmap": { "bat": "C:/Program Files/COLMAP/colmap.bat" },
  "lichtfeld": { "exe": "C:/Program Files/LichtFeld Studio/LichtFeld.exe" }
}
```

### Output Not Showing

Make sure you're using the `-ShowOutput` flag:
```powershell
.\make_splat.ps1 -Config my_config.json -ShowOutput
```

All output is still logged to files in `work_dir/logs/` regardless of the flag.
