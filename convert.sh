#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# WebP to JPEG Converter - Production Edition
# =============================================================================
# Usage: ./webp_to_jpg.sh [directory]
#        QUALITY=95 DELETE_ORIGINAL=1 ./webp_to_jpg.sh
# =============================================================================

# --------------------------- Config (overridable) ----------------------------
: "${QUALITY:=90}"                         # JPEG quality (1-100)
: "${PARALLEL:=}"                          # force parallelism, e.g. PARALLEL=8
: "${DELETE_ORIGINAL:=0}"                  # 1 = delete .webp after success
: "${DRY_RUN:=0}"                          # 1 = show what would be converted
: "${DRY_RUN_LIMIT:=20}"                   # max files to show in dry run
: "${RECURSIVE:=1}"                        # 1 = recursive search, 0 = current dir only
: "${MAX_PARALLEL:=64}"                    # safety limit for parallelism
: "${PROGRESS_MODE:=auto}"                 # auto/pv/simple/none
# -----------------------------------------------------------------------------

# --------------------------- Help -------------------------------------------
show_help() {
  cat <<EOF
Usage: $0 [OPTIONS] [DIRECTORY]

Convert WebP images to JPEG format with parallel processing.

OPTIONS:
  -h, --help              Show this help message
  -q, --quality NUM       JPEG quality (1-100, default: 90)
  -p, --parallel NUM      Number of parallel jobs (default: auto-detect)
  -d, --delete            Delete original .webp files after conversion
  -n, --dry-run           Show what would be converted without doing it
  --dry-run-limit NUM     Max files to show in dry run (default: 20)
  --no-recursive          Don't search subdirectories
  --progress MODE         Progress display: auto/pv/simple/none (default: auto)

ENVIRONMENT VARIABLES:
  QUALITY                 JPEG quality (default: 90)
  PARALLEL                Force specific parallelism
  DELETE_ORIGINAL         Set to 1 to delete originals
  DRY_RUN                 Set to 1 for dry run
  DRY_RUN_LIMIT           Max files to show in dry run
  RECURSIVE               Set to 0 to disable recursive search
  PROGRESS_MODE           Progress display mode
  IM_CMD                  Override ImageMagick command

EXAMPLES:
  $0                                    # Convert all .webp in current dir
  $0 /path/to/images                    # Convert in specific directory
  QUALITY=95 $0                         # Use quality 95
  DELETE_ORIGINAL=1 $0                  # Delete .webp files after conversion
  DRY_RUN=1 $0                          # Preview what would be converted
  $0 --progress pv                      # Force pv progress bar

CONVERSION LOGIC:
  file.webp         → file.jpg
  image.jpg.webp    → image.jpg
  photo.png.webp    → photo.jpg
  doc.backup.webp   → doc.jpg

EOF
  exit 0
}

# --------------------------- Parse arguments ---------------------------------
TARGET_DIR="."
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      ;;
    -q|--quality)
      QUALITY="$2"
      shift 2
      ;;
    -p|--parallel)
      PARALLEL="$2"
      shift 2
      ;;
    -d|--delete)
      DELETE_ORIGINAL=1
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    --dry-run-limit)
      DRY_RUN_LIMIT="$2"
      shift 2
      ;;
    --no-recursive)
      RECURSIVE=0
      shift
      ;;
    --progress)
      PROGRESS_MODE="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
    *)
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

# Validate target directory
if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Directory '$TARGET_DIR' does not exist." >&2
  exit 1
fi

cd "$TARGET_DIR" || exit 1

# --- Choose ImageMagick (allow env override IM_CMD if provided) --------------
if [ "${IM_CMD:-}" != "" ] && command -v "$IM_CMD" >/dev/null 2>&1; then
  : # use provided IM_CMD
elif command -v magick >/dev/null 2>&1; then
  IM_CMD="magick"
elif command -v convert >/dev/null 2>&1; then
  IM_CMD="convert"
else
  echo "Error: ImageMagick is not installed." >&2
  echo "Install it with: brew install imagemagick  (macOS)" >&2
  echo "                 apt install imagemagick   (Debian/Ubuntu)" >&2
  exit 1
fi
export IM_CMD

# --- Verify WebP support -----------------------------------------------------
if ! "$IM_CMD" -version 2>/dev/null | grep -Ei 'webp' >/dev/null; then
  echo "Error: ImageMagick build does not support WebP." >&2
  echo "You may need to reinstall with WebP support enabled." >&2
  exit 1
fi

# --- Validate quality --------------------------------------------------------
if ! [[ "$QUALITY" =~ ^[0-9]+$ ]] || [ "$QUALITY" -lt 1 ] || [ "$QUALITY" -gt 100 ]; then
  echo "Error: QUALITY must be between 1 and 100 (got: $QUALITY)" >&2
  exit 1
fi

# --- Validate progress mode --------------------------------------------------
if [[ ! "$PROGRESS_MODE" =~ ^(auto|pv|simple|none)$ ]]; then
  echo "Error: PROGRESS_MODE must be one of: auto, pv, simple, none (got: $PROGRESS_MODE)" >&2
  exit 1
fi

# --- Determine parallelism ---------------------------------------------------
if [ -n "${PARALLEL}" ]; then
  nproc_cmd="$PARALLEL"
else
  if command -v nproc >/dev/null 2>&1; then
    nproc_cmd="$(nproc)"
  elif command -v getconf >/dev/null 2>&1 && getconf _NPROCESSORS_ONLN >/dev/null 2>&1; then
    nproc_cmd="$(getconf _NPROCESSORS_ONLN)"
  elif command -v sysctl >/dev/null 2>&1; then
    nproc_cmd="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  else
    nproc_cmd=4
  fi
fi

# Safety clamp
[ "$nproc_cmd" -ge 1 ] || nproc_cmd=1
[ "$nproc_cmd" -le "$MAX_PARALLEL" ] || nproc_cmd="$MAX_PARALLEL"

# --- Build find command based on RECURSIVE -----------------------------------
if [ "$RECURSIVE" = "1" ]; then
  find_depth=""
else
  find_depth="-maxdepth 1"
fi

# --- Count candidates (all .webp files) --------------------------------------
total="$(find . $find_depth -type f -iname '*.webp' 2>/dev/null | wc -l | awk '{print $1}')"
if [ "$total" -eq 0 ]; then
  echo "No .webp files found in: $(pwd)"
  exit 0
fi

# --- Determine progress mode -------------------------------------------------
use_pv=0
use_simple_progress=0

if [ "$PROGRESS_MODE" = "auto" ]; then
  if command -v pv >/dev/null 2>&1; then
    use_pv=1
  else
    use_simple_progress=1
  fi
elif [ "$PROGRESS_MODE" = "pv" ]; then
  if command -v pv >/dev/null 2>&1; then
    use_pv=1
  else
    echo "Warning: pv not found, falling back to simple progress" >&2
    use_simple_progress=1
  fi
elif [ "$PROGRESS_MODE" = "simple" ]; then
  use_simple_progress=1
elif [ "$PROGRESS_MODE" = "none" ]; then
  use_pv=0
  use_simple_progress=0
fi

# --- Dry run early exit ------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  echo "=== DRY RUN MODE ==="
  echo "Would convert $total .webp files"
  echo "Quality: $QUALITY"
  echo "Parallelism: $nproc_cmd"
  echo "Delete original: $DELETE_ORIGINAL"
  echo ""
  echo "Files to be converted (showing first $DRY_RUN_LIMIT):"
  find . $find_depth -type f -iname '*.webp' 2>/dev/null | head -"$DRY_RUN_LIMIT"
  if [ "$total" -gt "$DRY_RUN_LIMIT" ]; then
    echo "... and $((total - DRY_RUN_LIMIT)) more"
  fi
  exit 0
fi

# --- Confirmation for DELETE_ORIGINAL ----------------------------------------
if [ "${DELETE_ORIGINAL}" = "1" ]; then
  echo ""
  echo "⚠️  WARNING: DELETE_ORIGINAL=1 will permanently delete all .webp files after conversion!"
  echo "   Found $total files to process."
  echo ""
  read -p "   Continue? (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted by user."
    exit 0
  fi
  echo ""
fi

echo "Found $total .webp files. Converting (parallel: $nproc_cmd)..."
echo "Using: $IM_CMD  |  QUALITY=$QUALITY  |  DELETE_ORIGINAL=$DELETE_ORIGINAL"
if [ "$use_pv" = "1" ]; then
  echo "Progress mode: pv"
elif [ "$use_simple_progress" = "1" ]; then
  echo "Progress mode: simple (install 'pv' for better progress bar)"
fi
echo ""

# --- Log file (atomically created with mktemp) -------------------------------
ts="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$(mktemp "webp_to_jpg_${ts}_XXXX.log")"
export LOG_FILE

{
  echo "=== WEBP → JPG Conversion ==="
  echo "Date: $(date)"
  echo "Directory: $(pwd)"
  echo "Files to process: $total"
  echo "Parallelism: $nproc_cmd"
  echo "Quality: $QUALITY"
  echo "Delete original: $DELETE_ORIGINAL"
  echo "Recursive: $RECURSIVE"
  echo "---"
} >>"$LOG_FILE"
echo "Log: $LOG_FILE"
echo ""

# --- Portable timestamp function ---------------------------------------------
now() {
  if printf '%(%Y-%m-%d %H:%M:%S)T' -1 >/dev/null 2>&1; then
    printf '%(%Y-%m-%d %H:%M:%S)T' -1
  else
    date "+%Y-%m-%d %H:%M:%S"
  fi
}

# --- Improved file size function with error handling ------------------------
filesize_bytes() {
  local file="$1" size
  
  if command -v gstat >/dev/null 2>&1; then
    if size=$(gstat -c%s -- "$file" 2>/dev/null); then
      echo "$size"
      return 0
    fi
  fi
  
  if command -v stat >/dev/null 2>&1; then
    if stat --version >/dev/null 2>&1 | grep -q GNU; then
      if size=$(stat -c%s -- "$file" 2>/dev/null); then
        echo "$size"
        return 0
      fi
    else
      if size=$(stat -f%z -- "$file" 2>/dev/null); then
        echo "$size"
        return 0
      fi
    fi
  fi
  
  if size=$(wc -c <"$file" 2>/dev/null | tr -d ' '); then
    echo "$size"
    return 0
  fi
  
  echo "Warning: Cannot determine size of $file" >&2
  echo 0
  return 1
}

format_size() {
  local bytes="$1"
  if [ "$bytes" -ge 1048576 ]; then
    awk "BEGIN {printf \"%.1fM\", $bytes/1048576}"
  elif [ "$bytes" -ge 1024 ]; then
    awk "BEGIN {printf \"%.1fK\", $bytes/1024}"
  else
    echo "${bytes}B"
  fi
}

export -f format_size filesize_bytes now

# --- Progress counter (with flock if available) ------------------------------
if [ "$use_simple_progress" = "1" ]; then
  PROGRESS_FILE="$(mktemp)"
  PROGRESS_LOCK="$(mktemp)"
  echo "0" >"$PROGRESS_FILE"
  export PROGRESS_FILE PROGRESS_LOCK total
  
  # Check if flock is available
  HAS_FLOCK=0
  if command -v flock >/dev/null 2>&1; then
    HAS_FLOCK=1
  fi
  export HAS_FLOCK
fi

# --- Failure tracker ---------------------------------------------------------
FAIL_FILE="$(mktemp)"
export FAIL_FILE

# --- Cleanup trap ------------------------------------------------------------
cleanup() {
  local exit_code=$?
  rm -f "$FAIL_FILE"
  if [ "$use_simple_progress" = "1" ]; then
    rm -f "$PROGRESS_FILE" "$PROGRESS_LOCK"
  fi
  # Keep LOG_FILE for user reference
  exit $exit_code
}
trap cleanup EXIT INT TERM

# --- Core conversion function ------------------------------------------------
convert_file() {
  local in="$1"

  # Normalize destination:
  # 1. Remove .webp extension (case insensitive)
  # 2. Remove any remaining extension (handles .jpg.webp, .png.webp, .backup.webp, etc.)
  # 3. Add .jpg
  local base="${in%.[Ww][Ee][Bb][Pp]}"  # remove .webp
  base="${base%.*}"                      # remove any remaining extension
  local out="${base}.jpg"

  local name_in="${in##*/}"
  local name_out="${out##*/}"
  local stamp="$(now)"

  # Skip if target exists
  if [ -f "$out" ]; then
    echo "⊘ [$stamp] Skipped: $name_in (already exists as $name_out)" | tee -a "$LOG_FILE" >&2
    
    # Update progress with locking if simple mode
    if [ "${use_simple_progress:-0}" = "1" ]; then
      if [ "${HAS_FLOCK}" = "1" ]; then
        flock "$PROGRESS_LOCK" bash -c 'echo $(($(cat "$PROGRESS_FILE") + 1)) >"$PROGRESS_FILE"'
      else
        echo $(($(cat "$PROGRESS_FILE") + 1)) >"$PROGRESS_FILE" 2>/dev/null || true
      fi
    fi
    
    return 0
  fi

  # Update progress with locking if simple mode
  local current=0
  if [ "${use_simple_progress:-0}" = "1" ]; then
    if [ "${HAS_FLOCK}" = "1" ]; then
      current=$(flock "$PROGRESS_LOCK" bash -c 'current=$(($(cat "$PROGRESS_FILE") + 1)); echo "$current" >"$PROGRESS_FILE"; echo "$current"')
    else
      current=$(($(cat "$PROGRESS_FILE") + 1))
      echo "$current" >"$PROGRESS_FILE" 2>/dev/null || true
    fi
    echo "→ [$stamp] [$current/$total] Converting: $name_in → $name_out" | tee -a "$LOG_FILE"
  else
    echo "→ [$stamp] Converting: $name_in → $name_out" | tee -a "$LOG_FILE"
  fi

  # Do the conversion; capture stderr
  # Note: some ImageMagick versions are picky about argument order
  local error_output
  if error_output=$("$IM_CMD" "$in" -quality "${QUALITY}" -strip "$out" 2>&1); then
    # Ensure output was actually created
    if [ ! -f "$out" ]; then
      echo "✗ [$stamp] ERROR: $name_in → $name_out (no output file created)" | tee -a "$LOG_FILE" >&2
      echo 1 >>"$FAIL_FILE"
      return 1
    fi

    local size_in_b size_out_b size_in size_out
    size_in_b="$(filesize_bytes "$in")"
    size_out_b="$(filesize_bytes "$out")"
    size_in="$(format_size "$size_in_b")"
    size_out="$(format_size "$size_out_b")"

    # Calculate savings percentage
    local change_msg
    if [ "$size_in_b" -gt 0 ]; then
      local savings
      savings=$(awk "BEGIN {printf \"%.1f\", (1 - $size_out_b/$size_in_b) * 100}")
      if [ "${savings%.*}" -lt 0 ]; then
        change_msg="↑${savings#-}%"
      else
        change_msg="↓${savings}%"
      fi
    else
      change_msg="N/A"
    fi

    echo "✓ [$stamp] Success: $name_in → $name_out ($size_in → $size_out, $change_msg)" | tee -a "$LOG_FILE"

    if [ "${DELETE_ORIGINAL}" = "1" ]; then
      rm -f -- "$in"
      echo "  🗑️  Deleted: $name_in" | tee -a "$LOG_FILE"
    fi
  else
    echo "✗ [$stamp] ERROR during conversion: $name_in" | tee -a "$LOG_FILE" >&2
    echo "   Details: $error_output" | tee -a "$LOG_FILE" >&2
    
    # Enhanced error diagnostics
    if echo "$error_output" | grep -qi "permission denied"; then
      echo "   Likely cause: Insufficient permissions for $in or $out" | tee -a "$LOG_FILE" >&2
    elif echo "$error_output" | grep -qi "no space"; then
      echo "   Likely cause: Disk full" | tee -a "$LOG_FILE" >&2
    elif echo "$error_output" | grep -qi "unable to open"; then
      echo "   Likely cause: File not readable or corrupted" | tee -a "$LOG_FILE" >&2
    fi
    
    echo 1 >>"$FAIL_FILE"
    return 1
  fi
}

export -f convert_file
export use_simple_progress

# --- Execute conversion with appropriate progress tracking -------------------
if [ "$use_pv" = "1" ]; then
  # Use pv for nice progress bar
  find . $find_depth -type f -iname '*.webp' -print0 2>/dev/null \
  | pv -0lps "$total" -N "Converting" \
  | xargs -0 -n 1 -P "$nproc_cmd" -I {} bash -c 'convert_file "$@"' _ {}
else
  # Use simple progress or no progress
  find . $find_depth -type f -iname '*.webp' -print0 2>/dev/null \
  | xargs -0 -n 1 -P "$nproc_cmd" -I {} bash -c 'convert_file "$@"' _ {}
fi

echo "" | tee -a "$LOG_FILE"
echo "---" | tee -a "$LOG_FILE"
echo "✓ Conversion finished." | tee -a "$LOG_FILE"
echo ""  | tee -a "$LOG_FILE"

# --- Summary -----------------------------------------------------------------
success="$(grep -c "✓.*Success" "$LOG_FILE" || true)"
skipped="$(grep -c "⊘.*Skipped" "$LOG_FILE" || true)"
errors="$(grep -c "✗.*ERROR"   "$LOG_FILE" || true)"

echo "=== REPORT ==="           | tee -a "$LOG_FILE"
echo "Successfully converted: $success" | tee -a "$LOG_FILE"
echo "Skipped (already existed): $skipped" | tee -a "$LOG_FILE"
echo "Errors: $errors"          | tee -a "$LOG_FILE"
echo "Total candidates: $total" | tee -a "$LOG_FILE"
echo ""                         | tee -a "$LOG_FILE"
echo "Detailed log: $LOG_FILE"

# Non-zero exit if any conversion failed
if [ -s "$FAIL_FILE" ]; then
  exit 1
fi

echo ""
echo "✓ All done!"
