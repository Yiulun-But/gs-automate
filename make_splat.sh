#!/usr/bin/env bash
set -euo pipefail

# ==============================================================
# make_splat.sh — MP4 -> frames -> COLMAP -> train -> export
# Pipelines: lichtfeld (default) or nerfstudio (optional)
# Usage: ./make_splat.sh config.env [--dry-run] [--force]
# ==============================================================

# ---- Parse args ----
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 config.env [--dry-run] [--force]" >&2
  exit 1
fi

CFG="$1"; shift || true
DRYRUN=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRYRUN=1 ;;
    --force)      FORCE=1 ;;
    *) echo "[WARN] Unknown arg: $1" ;;
  esac
  shift || true
done

if [[ ! -f "$CFG" ]]; then
  echo "[ERR] Config not found: $CFG" >&2
  exit 2
fi

# ---- Load KEY=VALUE config (ignore blank and #comment lines) ----
# (No eval; just export lines that look like NAME=VALUE)
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    key="${line%%=*}"
    val="${line#*=}"
    # trim surrounding quotes if present
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    export "$key=$val"
  fi
done < "$CFG"

# ---- Defaults ----
: "${PIPELINE:=lichtfeld}"
: "${FPS:=2}"
: "${LONG_EDGE:=1080}"
: "${IMAGE_EXT:=png}"
: "${SINGLE_CAMERA:=1}"
: "${DENSE:=0}"
: "${SIFT_THREADS:=8}"
: "${MAPPER_THREADS:=8}"
: "${SEED:=42}"
: "${LF_WORK_DIRNAME:=lf_train}"

# ---- Validate required ----
missing=()
for v in PROJECT WORK_DIR VIDEO; do
  if [[ -z "${!v:-}" ]]; then missing+=("$v"); fi
done
# Linux uses COLMAP_BIN (fallback to COLMAP_BAT for shared config, or plain 'colmap')
COLMAP_BIN="${COLMAP_BIN:-${COLMAP_BAT:-colmap}}"
FFMPEG="${FFMPEG:-ffmpeg}"

if [[ "${PIPELINE,,}" == "lichtfeld" && -z "${LICHTFELD_EXE:-}" ]]; then
  missing+=("LICHTFELD_EXE")
fi
if (( ${#missing[@]} > 0 )); then
  echo "[ERR] Missing required variables: ${missing[*]}" >&2
  cat <<'EOF' >&2

Minimal config example (demo.env):
----------------------------------
PROJECT=demo_splat
WORK_DIR=/data/work/demo_splat
VIDEO=/data/input.mp4
COLMAP_BIN=colmap
FFMPEG=ffmpeg
PIPELINE=lichtfeld
LICHTFELD_EXE=/opt/lichtfeld/LichtFeld       # adjust path
# Optional:
FPS=2
LONG_EDGE=1080
IMAGE_EXT=png
SINGLE_CAMERA=1
DENSE=0
SIFT_THREADS=8
MAPPER_THREADS=8
LF_WORK_DIRNAME=lf_train
LF_TRAIN_ARGS=--max_iters 30000 --batch_size 1 --fp16 --random_seed 42
LF_EXPORT_ARGS=--num_points 1000000 --format ply
# CUDA_HOME=/usr/local/cuda-12.8
# TRANSPOSE=1
# Nerfstudio (if PIPELINE=nerfstudio):
# NS_PREP_ARGS=
# NS_TRAIN_ARGS=--max-num-iterations 30000
# NS_EXPORT_ARGS=--num-points 1000000
----------------------------------
EOF
  exit 3
fi

# ---- PATH / CUDA environment (optional) ----
if [[ -n "${CUDA_HOME:-}" ]]; then
  export CUDA_HOME
  export PATH="$CUDA_HOME/bin:$PATH"
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$CUDA_HOME/lib64"
fi

# ---- Check critical tools ----
need_missing=0
for bin in "$FFMPEG" "$COLMAP_BIN"; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[ERR] Not found on PATH: $bin" >&2
    need_missing=1
  fi
done
if [[ "${PIPELINE,,}" == "lichtfeld" ]]; then
  if [[ ! -x "${LICHTFELD_EXE:-}" ]]; then
    echo "[ERR] LichtFeld executable not found or not executable: $LICHTFELD_EXE" >&2
    need_missing=1
  fi
fi
if (( need_missing )); then exit 4; fi

# ---- Directories ----
mkdir -p "$WORK_DIR"/{logs,frames,colmap,colmap/sparse,colmap/undistorted,"$LF_WORK_DIRNAME","$LF_WORK_DIRNAME"/model,output,ns_data,ns_train}
LOG_DIR="$WORK_DIR/logs"
FRAMES_DIR="$WORK_DIR/frames"
COLMAP_DIR="$WORK_DIR/colmap"
SPARSE_DIR="$COLMAP_DIR/sparse"
UNDIST_DIR="$COLMAP_DIR/undistorted"
LF_TRAIN_DIR="$WORK_DIR/$LF_WORK_DIRNAME"
MODEL_DIR="$LF_TRAIN_DIR/model"
OUT_DIR="$WORK_DIR/output"
NS_DATA_DIR="$WORK_DIR/ns_data"
NS_OUT_DIR="$WORK_DIR/ns_train"
SPLAT_PATH="$OUT_DIR/${PROJECT}_gaussians.ply"

LOG="$LOG_DIR/run-$(date +%Y%m%d_%H%M%S).log"

echo
echo "=== Config summary ==="
echo "Project   : $PROJECT"
echo "WorkDir   : $WORK_DIR"
echo "Video     : $VIDEO"
echo "FramesDir : $FRAMES_DIR"
echo "ColmapDir : $COLMAP_DIR"
echo "ModelDir  : $MODEL_DIR"
echo "Output    : $SPLAT_PATH"
echo "Pipeline  : $PIPELINE"

# ---- Runner (pretty print + log, supports argv safely) ----
run_cmd() {
  local -a cmd=( "$@" )
  # pretty-print command
  { printf '[*] '; printf '%q ' "${cmd[@]}"; printf '\n'; } | tee -a "$LOG"
  if (( DRYRUN )); then return 0; fi
  if ! "${cmd[@]}" >>"$LOG" 2>&1; then
    local rc=$?
    echo "[ERR] ExitCode=$rc" | tee -a "$LOG"
    return $rc
  fi
}

# ------------------ Step 1: Extract frames ------------------
echo
echo "=== Step 1/4: Extract frames with ffmpeg ==="
if (( ! FORCE )) && compgen -G "$FRAMES_DIR/*.${IMAGE_EXT}" > /dev/null; then
  echo "[OK] Skipping extraction (frames already exist)."
else
  vf="fps=${FPS}"
  if (( LONG_EDGE > 0 )); then
    # Long-edge resize, preserve AR (use -2 for the other side)
    vf="${vf},scale=if(gt(iw,ih),${LONG_EDGE},-2):if(gt(ih,iw),${LONG_EDGE},-2)"
  fi
  if [[ -n "${TRANSPOSE:-}" ]]; then
    vf="${vf},transpose=${TRANSPOSE}"
  fi
  run_cmd "$FFMPEG" -y -i "$VIDEO" -vf "$vf" "$FRAMES_DIR/frame_%05d.$IMAGE_EXT"
  echo "[OK] Extracted frames -> $FRAMES_DIR"
fi

# ------------------ Step 2: COLMAP ------------------
echo
echo "=== Step 2/4: COLMAP (${PIPELINE}) ==="
COLMAP_MODE="${COLMAP_MODE:-automatic}"

if [[ "${COLMAP_MODE}" == "manual" ]]; then
  run_cmd "$COLMAP_BIN" feature_extractor \
    --database_path "$COLMAP_DIR/database.db" \
    --image_path "$FRAMES_DIR" \
    --ImageReader.single_camera "$SINGLE_CAMERA" \
    --SiftExtraction.num_threads "$SIFT_THREADS"
  run_cmd "$COLMAP_BIN" exhaustive_matcher \
    --database_path "$COLMAP_DIR/database.db"
  run_cmd "$COLMAP_BIN" mapper \
    --database_path "$COLMAP_DIR/database.db" \
    --image_path "$FRAMES_DIR" \
    --output_path "$SPARSE_DIR" \
    --Mapper.num_threads "$MAPPER_THREADS"
else
  run_cmd "$COLMAP_BIN" automatic_reconstructor \
    --workspace_path "$COLMAP_DIR" \
    --image_path "$FRAMES_DIR" \
    --dense "$DENSE" \
    --single_camera "$SINGLE_CAMERA"
  echo "[OK] COLMAP automatic reconstruction complete."
fi

# Always undistort (LichtFeld expects undistorted)
run_cmd "$COLMAP_BIN" image_undistorter \
  --image_path "$FRAMES_DIR" \
  --input_path "$SPARSE_DIR/0" \
  --output_path "$UNDIST_DIR" \
  --output_type COLMAP
echo "[OK] COLMAP undistortion complete -> $UNDIST_DIR"

# ------------------ Step 3: Train ------------------
echo
echo "=== Step 3/4: Train ==="
case "${PIPELINE,,}" in
  lichtfeld)
    # LF_TRAIN_ARGS can be a free-form string of extra flags
    LF_TRAIN_ARGS="${LF_TRAIN_ARGS:-}"
    # shellcheck disable=SC2086
    run_cmd "$LICHTFELD_EXE" train --data "$UNDIST_DIR" --output "$MODEL_DIR" $LF_TRAIN_ARGS
    echo "[OK] Training completed (LichtFeld). Model -> $MODEL_DIR"
    ;;
  nerfstudio)
    NS_PREP_ARGS="${NS_PREP_ARGS:-}"
    NS_TRAIN_ARGS="${NS_TRAIN_ARGS:-}"
    # Prepare
    # shellcheck disable=SC2086
    run_cmd ns-process-data video --data "$VIDEO" --output-dir "$NS_DATA_DIR" --fps "$FPS" \
      --max-frame-processes 8 --keep-extracted-frames --auto-orient $NS_PREP_ARGS
    # Train
    # shellcheck disable=SC2086
    run_cmd ns-train gsplat --data "$NS_DATA_DIR" --output-dir "$NS_OUT_DIR" $NS_TRAIN_ARGS
    echo "[OK] Training completed (Nerfstudio)."
    ;;
  *)
    echo "[ERR] Unknown PIPELINE: $PIPELINE" >&2
    exit 5
    ;;
esac

# ------------------ Step 4: Export splat ------------------
echo
echo "=== Step 4/4: Export Gaussian Splat ==="
case "${PIPELINE,,}" in
  lichtfeld)
    LF_EXPORT_ARGS="${LF_EXPORT_ARGS:-}"
    # shellcheck disable=SC2086
    run_cmd "$LICHTFELD_EXE" export --model "$MODEL_DIR" --output "$SPLAT_PATH" $LF_EXPORT_ARGS
    echo "[OK] Exported Gaussian splat -> $SPLAT_PATH"
    ;;
  nerfstudio)
    NS_EXPORT_ARGS="${NS_EXPORT_ARGS:-}"
    # shellcheck disable=SC2086
    run_cmd ns-export gaussian-splat --load-config "$NS_OUT_DIR/outputs/latest/config.yml" \
      --output "$SPLAT_PATH" $NS_EXPORT_ARGS
    echo "[OK] Exported Gaussian splat -> $SPLAT_PATH"
    ;;
esac

# ------------------ Result manifest ------------------
cat > "$OUT_DIR/result.json" <<EOF
{
  "project":   "$(printf '%s' "$PROJECT")",
  "work_dir":  "$(printf '%s' "$WORK_DIR")",
  "video":     "$(printf '%s' "$VIDEO")",
  "frames":    "$(printf '%s' "$FRAMES_DIR")",
  "colmap":    "$(printf '%s' "$COLMAP_DIR")",
  "model_dir": "$(printf '%s' "$MODEL_DIR")",
  "output":    "$(printf '%s' "$SPLAT_PATH")",
  "pipeline":  "$(printf '%s' "$PIPELINE")"
}
EOF
echo "[OK] Result manifest: $OUT_DIR/result.json"
