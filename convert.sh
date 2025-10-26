#!/usr/bin/env bash
set -eu

# Check for ImageMagick (IM7: magick, IM6: convert)
if command -v magick >/dev/null 2>&1; then
  IM_CMD="magick"
elif command -v convert >/dev/null 2>&1; then
  IM_CMD="convert"
else
  echo "Error: ImageMagick is not installed." >&2
  exit 1
fi
export IM_CMD

if ! $IM_CMD -version | grep -qi webp; then
  echo "Error: ImageMagick does not support WebP." >&2
  exit 1
fi

# Number of parallel processes
nproc_cmd=$(nproc 2>/dev/null || echo 4)

# Count files
total=$(find . -type f -iname "*.webp" | wc -l)

# Check if there are files to convert
if [ "$total" -eq 0 ]; then
  echo "No .webp files found for conversion."
  exit 0
fi

echo "Found $total .webp files. Converting (parallel: $nproc_cmd)..."
echo "Using: $IM_CMD"
echo ""

# Log file with timestamp
LOG_FILE="webp_to_jpg_$(date +%Y%m%d_%H%M%S).log"
export LOG_FILE

echo "Log will be saved to: $LOG_FILE"
{
  echo "=== WEBP → JPG Conversion ==="
  echo "Date: $(date)"
  echo "Files to process: $total"
  echo "Parallelism: $nproc_cmd"
  echo "---"
} > "$LOG_FILE"

# Format file size helper
format_size() {
  local bytes=$1
  if [ "$bytes" -ge 1048576 ]; then
    awk "BEGIN {printf \"%.1fM\", $bytes/1048576}"
  elif [ "$bytes" -ge 1024 ]; then
    awk "BEGIN {printf \"%.1fK\", $bytes/1024}"
  else
    echo "${bytes}B"
  fi
}
export -f format_size

# Conversion
find . -type f -iname "*.webp" -print0 \
| xargs -0 -n 1 -P "$nproc_cmd" -I {} bash -c '
  in="$1"
  out="${in%.[Ww][Ee][Bb][Pp]}.jpg"
  basename="${in##*/}"
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")

  if [ -f "$out" ]; then
    echo "⊘ [$timestamp] Skipped: $basename (already exists $(basename "$out"))" | tee -a "$LOG_FILE" >&2
    exit 0
  fi

  echo "→ [$timestamp] Converting: $in" | tee -a "$LOG_FILE"

  if error_output=$($IM_CMD "$in" -strip -quality 90 "jpeg:$out" 2>&1); then
    if command -v stat >/dev/null 2>&1; then
      if stat --version >/dev/null 2>&1; then
        size_in_bytes=$(stat -c%s "$in");  size_out_bytes=$(stat -c%s "$out")
      else
        size_in_bytes=$(stat -f%z "$in"); size_out_bytes=$(stat -f%z "$out")
      fi
    else
      size_in_bytes=$(du -b "$in" | cut -f1); size_out_bytes=$(du -b "$out" | cut -f1)
    fi
    size_in=$(format_size "$size_in_bytes"); size_out=$(format_size "$size_out_bytes")
    echo "✓ [$timestamp] Success: $basename ($size_in → $size_out)" | tee -a "$LOG_FILE"
  else
    echo "✗ [$timestamp] ERROR during conversion: $in" | tee -a "$LOG_FILE" >&2
    echo "   Details: $error_output" | tee -a "$LOG_FILE" >&2
    exit 1
  fi
' _ {}


echo ""
echo "---" | tee -a "$LOG_FILE"
echo "✓ Conversion completed!" | tee -a "$LOG_FILE"
echo ""

# Summary report
{
  echo ""
  echo "=== REPORT ==="
  
  success=$(grep "✓.*Success" "$LOG_FILE" 2>/dev/null | wc -l | awk '{print $1}')
  skipped=$(grep "⊘.*Skipped" "$LOG_FILE" 2>/dev/null | wc -l | awk '{print $1}')
  errors=$(grep "✗.*ERROR" "$LOG_FILE" 2>/dev/null | wc -l | awk '{print $1}')
  
  echo "Successfully converted: $success"
  echo "Skipped: $skipped"
  echo "Errors: $errors"
  echo "Total processed: $total"
  echo ""
  echo "Detailed log: $LOG_FILE"
} | tee -a "$LOG_FILE"
