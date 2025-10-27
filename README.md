# Gaussian Splat Generator

A PowerShell pipeline tool that converts MP4 videos into Gaussian splat (.ply) files using COLMAP for reconstruction and either LichtFeld Studio or Nerfstudio for training.

## Pipeline Overview

The tool orchestrates a 4-step process:

1. **Extract Frames** - Extracts frames from input video using ffmpeg
2. **COLMAP Reconstruction** - Creates sparse 3D reconstruction from frames
3. **Train Model** - Trains Gaussian splatting model (LichtFeld or Nerfstudio)
4. **Export Splat** - Exports trained model to .ply format

## Prerequisites

- **COLMAP** - For 3D reconstruction ([Download](https://colmap.github.io/))
- **ffmpeg** - For video frame extraction (must be on PATH or specify path in config)
- **PowerShell 5.1+** (Windows PowerShell or PowerShell Core)
- **Training Tool** (choose one):
  - LichtFeld Studio, or
  - Nerfstudio

### Optional
- **CUDA** - Recommended for GPU acceleration (specify path in config if not on PATH)
- **Python** - Only needed if your training commands require it

## Quick Start

### 1. Generate Configuration Template

```powershell
.\make_splat.ps1 -InitConfig my_config.json
```

This creates a JSON config file with all available options.

### 2. Edit Configuration

Open `my_config.json` and configure:

- **project.video** - Path to your input MP4 file
- **project.work_dir** - Where to store all outputs
- **tools.colmap.bat** - Path to colmap.bat
- **tools.ffmpeg.path** - Path to ffmpeg (or "ffmpeg" if on PATH)
- **tools.cuda.home** - CUDA directory (optional, set to null if not needed)
- **tools.python** - Python path (optional, set to null if not needed)

### 3. Run Pipeline

```powershell
.\make_splat.ps1 -Config my_config.json
```

## Configuration Options

### Project Settings

```json
"project": {
  "name": "demo_splat",           // Project name (used for output filenames)
  "work_dir": "D:/GS/work/demo",  // Working directory for all outputs
  "video": "D:/GS/data/input.mp4", // Input video file
  "seed": 42                       // Random seed for reproducibility
}
```

### Frame Extraction

```json
"extract": {
  "fps": 2,                    // Frames per second to extract
  "resize_long_edge": 1080,    // Resize frames (0 = no resize)
  "image_ext": "png",          // Output image format
  "skip_if_exists": true       // Skip if frames already extracted
}
```

### COLMAP Settings

```json
"colmap": {
  "mode": "automatic",         // "automatic" or "manual"
  "db_name": "database.db",
  "single_camera": true,       // Assume single camera
  "sift_threads": 8,           // Threads for SIFT extraction
  "mapper_num_threads": 8,     // Threads for mapper
  "dense": false               // Create dense reconstruction (slower)
}
```

**Modes:**
- `automatic` - COLMAP runs everything in one step
- `manual` - Runs feature extraction → matching → mapping → undistortion separately

### Pipeline Selection

```json
"pipeline": "lichtfeld"  // or "nerfstudio"
```

#### LichtFeld Studio Configuration

```json
"lichtfeld": {
  "train": {
    "work_dir_name": "lf_train",
    "command": "lichtfeld-train --data \"{data_dir}\" --output \"{model_dir}\"",
    "args": {
      "max_iters": 30000,
      "batch_size": 1,
      "fp16": true,
      "random_seed": "{seed}"
    }
  },
  "export": {
    "command": "lichtfeld-export --model \"{model_dir}\" --output \"{splat_path}\"",
    "args": {
      "num_points": 1000000,
      "format": "ply"
    }
  }
}
```

**Note:** Commands assume `lichtfeld-train` and `lichtfeld-export` are on PATH. You can customize the commands to use Python modules or other executables.

#### Nerfstudio Configuration

```json
"nerfstudio": {
  "prepare": {
    "command": "ns-process-data video --data \"{video}\" --output-dir \"{ns_data_dir}\" --fps {fps}..."
  },
  "train": {
    "command": "ns-train gsplat --data \"{ns_data_dir}\" --output-dir \"{ns_out_dir}\"",
    "args": { "max-num-iterations": 30000 }
  },
  "export": {
    "command": "ns-export gaussian-splat --load-config \"{ns_out_dir}/outputs/latest/config.yml\"...",
    "args": { "num-points": 1000000 }
  }
}
```

## Command Line Options

### `-Config <path>`
Path to your JSON configuration file (required for running pipeline).

```powershell
.\make_splat.ps1 -Config my_config.json
```

### `-InitConfig <path>`
Generate a configuration template file and exit.

```powershell
.\make_splat.ps1 -InitConfig template.json
```

### `-DryRun`
Print commands without executing them (useful for debugging).

```powershell
.\make_splat.ps1 -Config my_config.json -DryRun
```

### `-Force`
Re-run all steps even if outputs already exist.

```powershell
.\make_splat.ps1 -Config my_config.json -Force
```

## Output Structure

After running, your work directory will contain:

```
work_dir/
├── frames/                    # Extracted video frames
├── colmap/                    # COLMAP reconstruction
│   ├── sparse/               # Sparse point cloud
│   └── undistorted/          # Undistorted images + cameras
├── lf_train/                  # LichtFeld training directory
│   └── model/                # Trained model checkpoint
├── output/                    # Final outputs
│   ├── demo_splat_gaussians.ply  # Final Gaussian splat
│   └── result.json           # Manifest with all paths
└── logs/                      # Execution logs
    └── run_20250123_143022.log
```

## Template Variables

Commands support template variables that are automatically expanded:

- `{video}` - Input video path
- `{frames_dir}` - Extracted frames directory
- `{colmap_dir}` - COLMAP workspace
- `{data_dir}` - Training data directory (undistorted frames)
- `{model_dir}` - Model output directory
- `{splat_path}` - Final .ply output path
- `{python}` - Python executable path
- `{seed}` - Random seed from config

## Troubleshooting

### COLMAP fails to reconstruct
- Try increasing `extract.fps` for more frames
- Ensure video has sufficient motion and detail
- Check frames were extracted correctly in `work_dir/frames/`

### Out of memory errors
- Reduce `extract.resize_long_edge` (e.g., 720 instead of 1080)
- Lower `extract.fps` to extract fewer frames
- Set `colmap.dense: false` (sparse only)

### Python/CUDA errors
- Verify `tools.cuda.home` points to correct CUDA installation
- Ensure Python environment has required packages installed
- Check `logs/` directory for detailed error messages

### Parser errors (Windows PowerShell)
- Script requires PowerShell 5.1+
- Some features work best with PowerShell 7+

## Example Workflow

```powershell
# 1. Create config
.\make_splat.ps1 -InitConfig my_project.json

# 2. Edit my_project.json with your paths

# 3. Test with dry run
.\make_splat.ps1 -Config my_project.json -DryRun

# 4. Run the pipeline
.\make_splat.ps1 -Config my_project.json

# 5. View result
# Output will be in: work_dir/output/my_project_gaussians.ply
```

## Advanced Customization

### Custom Command Templates

You can override COLMAP commands in the config:

```json
"colmap": {
  "templates": {
    "automatic": "\"{colmap_bat}\" automatic_reconstructor --workspace_path \"{colmap_dir}\" --custom-flag value"
  }
}
```

### External Arguments File

Keep training arguments in a separate file:

```json
"lichtfeld": {
  "train": {
    "args_from_file": "D:/configs/training_args.json"
  }
}
```

The external JSON will be merged with the inline `args`.

## License

This tool is a wrapper around existing tools. Please respect the licenses of:
- COLMAP
- ffmpeg
- LichtFeld Studio / Nerfstudio
- CUDA
