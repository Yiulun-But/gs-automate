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

### LichtFeld Studio Configuration

**✅ FIXED:** The script now uses correct LichtFeld Studio command-line syntax.

**Correct configuration:**
```json
"lichtfeld": {
  "train": {
    "command": "\"{lichtfeld_exe}\" --data-path \"{data_dir}\" --output-path \"{model_dir}\"",
    "args": {
      "iter": 30000,              // Training iterations
      "resize_factor": 1,         // Image resolution factor
      "strategy": "mcmc",         // Optimization strategy
      "max-cap": 1000000,        // Max Gaussians
      "headless": true           // Run without GUI
    }
  }
}
```

**Available arguments:**
- `--iter [NUM]` - Training iterations (default: 30000)
- `--resize_factor [NUM]` - Image resolution scaling (default: 1)
- `--strategy [mcmc|default]` - Optimization strategy (default: mcmc)
- `--max-cap [NUM]` - Maximum Gaussians for MCMC (default: 1000000)
- `--headless` - Run without GUI (recommended for scripting)
- `--eval` - Enable evaluation during training
- `--save-eval-images` - Save evaluation images
- `--test-every [NUM]` - Test/validation split ratio (default: 8)
- `--bilateral-grid` - Enable appearance modeling

**Note:** LichtFeld Studio exports .ply files automatically during training. The script will automatically copy the output to the final location.

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
