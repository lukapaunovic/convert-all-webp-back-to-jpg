#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# WebP to GIF/PNG/JPEG Converter — Production Edition
# =============================================================================
# Usage: ./convert.sh [directory]
# Options (env or flags):
#   QUALITY=90            # JPEG quality (1–100)
#   PARALLEL=8            # Force number of parallel jobs
#   DELETE_ORIGINAL=0     # 1 = remove .webp after success
#   DRY_RUN=0             # 1 = print what would be converted
#   DRY_RUN_LIMIT=20      # Max lines shown in dry run
#   RECURSIVE=1           # 0 = current dir only
#   PROGRESS_MODE=auto    # auto|pv|simple|none
#   IM_CMD=magick         # Override ImageMagick command
#   EMOJI=1               # 1 = emoji in logs, 0 = plain ASCII
# =============================================================================

# --------------------------- Config (overridable) ----------------------------
: "${QUALITY:=90}"
: "${PARALLEL:=}"
: "${DELETE_ORIGINAL:=0}"
: "${DRY_RUN:=0}"
: "${DRY_RUN_LIMIT:=20}"
: "${RECURSIVE:=1}"
: "${MAX_PARALLEL:=64}"
: "${PROGRESS_MODE:=auto}"
: "${EMOJI:=1}"          # 1 = emoji u logu, 0 = čisti ASCII
# -----------------------------------------------------------------------------

# --------------------------- Log simboli -------------------------------------
if [ "$EMOJI" = "1" ]; then
  S_OK="✓"; S_SKIP="⊘"; S_ERR="✗"; S_ARROW="→"; S_BIN="🗑️ "
else
  S_OK="[OK]"; S_SKIP="[SKIP]"; S_ERR="[ERR]"; S_ARROW="->"; S_BIN="[DEL] "
fi

abspath() {
  local f="$1" d b out
  b="$(basename -- "$f")"
  d="$(dirname -- "$f")"
  if command -v realpath >/dev/null 2>&1; then
    out=$(realpath -m -- "$f" 2>/dev/null) || {
      if [ -d "$d" ]; then
        out=$(printf '%s/%s' "$(cd "$d" && pwd -P)" "$b")
      else
        case "$d" in
          /*) out="$d/$b" ;;
          *)  out="$PWD/$d/$b" ;;
        esac
      fi
    }
  elif command -v readlink >/dev/null 2>&1; then
    out=$(readlink -f -- "$f" 2>/dev/null) || {
      case "$d" in
        /*) out="$d/$b" ;;
        *)  out="$PWD/$d/$b" ;;
      esac
    }
  else
    case "$d" in
      /*) out="$d/$b" ;;
      *)  out="$PWD/$d/$b" ;;
    esac
  fi
  echo "$out" | tr -s '/'
}
export -f abspath

show_help() {
  cat <<'EOF'
Usage: convert.sh [OPTIONS] [DIRECTORY]

Convert *.webp images to GIF, PNG, or JPEG format:
- Animated WebP or *.gif.webp → .gif (preserves animation)
- *.png.webp or WebP with alpha channel → .png
- Other *.webp → .jpg (e.g., photo.jpg.webp → photo.jpg, image.webp → image.jpg)

Options:
  -h, --help              Show help
  -q, --quality NUM       JPEG quality (1–100, default 90)
  -p, --parallel NUM      Number of parallel jobs (default: auto)
  -d, --delete            Delete original .webp after success
  -n, --dry-run           Show actions without converting
  --dry-run-limit NUM     Limit dry-run listing (default 20)
  --no-recursive          Do not descend into subdirectories
  --progress MODE         auto|pv|simple|none (default auto)
  --no-emoji              Use plain ASCII instead of emoji in logs

Environment:
  QUALITY, PARALLEL, DELETE_ORIGINAL, DRY_RUN, DRY_RUN_LIMIT,
  RECURSIVE, PROGRESS_MODE, EMOJI

Examples:
  ./convert.sh
  QUALITY=95 ./convert.sh /path/to/images
  DELETE_ORIGINAL=1 ./convert.sh --progress pv --no-emoji
EOF
  exit 0
}

# --------------------------- Parse args --------------------------------------
TARGET_DIR="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) show_help ;;
    -q|--quality) QUALITY="$2"; shift 2 ;;
    -p|--parallel) PARALLEL="$2"; shift 2 ;;
    -d|--delete) DELETE_ORIGINAL=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    --dry-run-limit) DRY_RUN_LIMIT="$2"; shift 2 ;;
    --no-recursive) RECURSIVE=0; shift ;;
    --progress) PROGRESS_MODE="$2"; shift 2 ;;
    --no-emoji) EMOJI=0; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) TARGET_DIR="$1"; shift ;;
  esac
done

[ -d "$TARGET_DIR" ] || { echo "Directory not found: $TARGET_DIR" >&2; exit 1; }
cd "$TARGET_DIR"

# ------------------------ ImageMagick command --------------------------------
if [ "${IM_CMD:-}" ] && command -v "$IM_CMD" >/dev/null 2>&1; then
  :
elif command -v magick >/dev/null 2>&1; then
  IM_CMD="magick"
elif command -v convert >/dev/null 2>&1; then
  IM_CMD="convert"
else
  echo "ImageMagick not found. Install: apt install imagemagick (Debian/Ubuntu)" >&2
  exit 1
fi
export IM_CMD

# Verify WebP support
if ! "$IM_CMD" -version 2>/dev/null | grep -Eiq 'webp'; then
  echo "This ImageMagick build lacks WebP support." >&2
  exit 1
fi

# Validate quality
[[ "$QUALITY" =~ ^[0-9]+$ ]] && [ "$QUALITY" -ge 1 ] && [ "$QUALITY" -le 100 ] || {
  echo "QUALITY must be 1–100 (got $QUALITY)" >&2; exit 1; }

# ------------------------- CPU / parallelism ---------------------------------
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
[ "$nproc_cmd" -ge 1 ] || nproc_cmd=1
[ "$nproc_cmd" -le "$MAX_PARALLEL" ] || nproc_cmd="$MAX_PARALLEL"

# --------------------------- Discovery ---------------------------------------
find_depth=""
[ "$RECURSIVE" = "1" ] || find_depth="-maxdepth 1"

total="$(find . $find_depth -type f -iname '*.webp' 2>/dev/null | wc -l | awk '{print $1}')"
[ "$total" -gt 0 ] || { echo "No .webp files found in $(pwd)"; exit 0; }

# --------------------------- Progress mode -----------------------------------
use_pv=0; use_simple_progress=0
case "$PROGRESS_MODE" in
  auto)    command -v pv >/dev/null 2>&1 && use_pv=1 || use_simple_progress=1 ;;
  pv)      command -v pv >/dev/null 2>&1 && use_pv=1 || { echo "pv not found, using simple"; use_simple_progress=1; } ;;
  simple)  use_simple_progress=1 ;;
  none)    : ;;
  *) echo "Invalid PROGRESS_MODE ($PROGRESS_MODE). Use auto|pv|simple|none" >&2; exit 1 ;;
esac

# --------------------------- Dry run -----------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  echo "=== DRY RUN ==="
  echo "Would process $total *.webp files (parallel: $nproc_cmd)"
  echo "Delete original: $DELETE_ORIGINAL"
  echo "First $DRY_RUN_LIMIT files:"
  c=0
  find . $find_depth -type f -iname '*.webp' -print0 | \
  while IFS= read -r -d '' f; do
    printf '%s\n' "$(abspath "$f")"
    c=$((c+1))
    [ "$c" -ge "$DRY_RUN_LIMIT" ] && break
  done
  [ "$total" -gt "$DRY_RUN_LIMIT" ] && echo "... and $((total - DRY_RUN_LIMIT)) more"
  exit 0
fi

# -------------------------- Confirm destructive ------------------------------
if [ "$DELETE_ORIGINAL" = "1" ]; then
  echo "⚠️  DELETE_ORIGINAL=1 will permanently remove .webp after success."
  echo "   Files to process: $total"
  read -p "Continue? (y/N): " -r; echo
  [[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ----------------------------- Logging ---------------------------------------
ts="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$(mktemp "webp_convert_${ts}_XXXXXX.log")"
export LOG_FILE
{
  echo "=== WebP → (GIF/PNG/JPEG) ==="
  echo "Date: $(date)"
  echo "Dir:  $(pwd)"
  echo "Total: $total"
  echo "Parallel: $nproc_cmd"
  echo "Quality: $QUALITY"
  echo "Delete original: $DELETE_ORIGINAL"
  echo "Recursive: $RECURSIVE"
  echo "Emoji: $EMOJI"
  echo "---"
} >>"$LOG_FILE"
echo "Log file: $LOG_FILE"
echo

# ----------------------------- Utils -----------------------------------------
now() {
  if printf '%(%Y-%m-%d %H:%M:%S)T' -1 >/dev/null 2>&1; then
    printf '%(%Y-%m-%d %H:%M:%S)T' -1
  else
    date "+%Y-%m-%d %H:%M:%S"
  fi
}

filesize_bytes() {
  local f="$1" s
  if command -v gstat >/dev/null 2>&1; then
    s=$(gstat -c%s -- "$f" 2>/dev/null || echo 0)
  elif command -v stat >/dev/null 2>&1 && stat --version 2>/dev/null | grep -q GNU; then
    s=$(stat -c%s -- "$f" 2>/dev/null || echo 0)
  elif command -v stat >/dev/null 2>&1; then
    s=$(stat -f%z -- "$f" 2>/dev/null || echo 0)
  else
    s=$(wc -c <"$f" 2>/dev/null | tr -d ' ' || echo 0)
  fi
  echo "${s:-0}"
}

format_size() {
  local b="$1"
  if [ "$b" -ge 1048576 ]; then awk "BEGIN{printf \"%.1fM\", $b/1048576}"
  elif [ "$b" -ge 1024 ]; then awk "BEGIN{printf \"%.1fK\", $b/1024}"
  else echo "${b}B"; fi
}

export -f now filesize_bytes format_size

# Progress (simple)
if [ "$use_simple_progress" = "1" ]; then
  PROGRESS_FILE="$(mktemp "webp_convert_progress_${ts}_XXXXXX")"
  PROGRESS_LOCK="$(mktemp "webp_convert_lock_${ts}_XXXXXX")"
  echo "0" >"$PROGRESS_FILE"; HAS_FLOCK=0
  command -v flock >/dev/null 2>&1 && HAS_FLOCK=1
  export PROGRESS_FILE PROGRESS_LOCK HAS_FLOCK total
fi

FAIL_FILE="$(mktemp "webp_convert_fail_${ts}_XXXXXX")"
export FAIL_FILE
cleanup() {
  local ec=$?
  rm -f "$FAIL_FILE" ${PROGRESS_FILE:-} ${PROGRESS_LOCK:-}
  exit $ec
}
trap cleanup EXIT INT TERM

# ---------------------- Animation / alpha detection --------------------------
has_alpha() {
  local in="$1"
  local ch; ch=$("$IM_CMD" "$in" -format "%[channels]" info: 2>/dev/null || echo "")
  [[ "$ch" =~ a ]] && echo "yes" || echo "no"
}

can_read_image() {
  local in="$1"
  "$IM_CMD" -ping "$in" -format "%wx%h" info: >/dev/null 2>&1
}

is_valid_image() {
  local f="$1" ext="$2"
  [ -s "$f" ] || return 1
  if [ "$ext" = "gif" ]; then
    "$IM_CMD" "$f" -format "%n" info: >/dev/null 2>&1
  else
    "$IM_CMD" -ping "$f" -format "%wx%h" info: >/dev/null 2>&1
  fi
}

is_animated_webp() {
  local in="$1"
  local IDENTIFY_CMD=""
  if command -v magick >/dev/null 2>&1; then
    IDENTIFY_CMD="magick identify"
  elif command -v identify >/dev/null 2>&1; then
    IDENTIFY_CMD="identify"
  fi
  if [ -n "$IDENTIFY_CMD" ]; then
    local frames
    frames=$($IDENTIFY_CMD -format "%n\n" -- "$in" 2>/dev/null | head -n1 || echo 1)
    [ "${frames:-1}" -ge 2 ] && echo "yes" || echo "no"
  else
    local frames
    frames=$("$IM_CMD" "$in" -format "%n\n" info: 2>/dev/null | head -n1 || echo 1)
    [ "${frames:-1}" -ge 2 ] && echo "yes" || echo "no"
  fi
}

decide_target_ext() {
  local in="$1"
  local stem="${in%.[Ww][Ee][Bb][Pp]}"
  local file; file="$(basename -- "$stem")"
  local ext_lc="${file##*.}"; ext_lc="$(printf '%s' "$ext_lc" | tr '[:upper:]' '[:lower:]')"

  # Ako identify ne uspe, detekcija alfe rešava PNG; u suprotnom JPG.
  if [ "$(is_animated_webp "$in")" = "yes" ] || [ "$ext_lc" = "gif" ]; then
    echo "gif"; return
  fi
  if [ "$ext_lc" = "png" ] || [ "$(has_alpha "$in")" = "yes" ]; then
    echo "png"; return
  fi
  echo "jpg"
}



# ----------------------------- Conversion ------------------------------------
convert_file() {
  local in="$1"
  local stamp; stamp="$(now)"

  # 1) Ulaz čitljiv?
  if ! can_read_image "$in"; then
    echo "$S_ERR [$stamp] ERROR: unreadable or corrupt input: $in" | tee -a "$LOG_FILE" >&2
    echo 1 >>"$FAIL_FILE"; return 1
  fi

  # 2) Odredi TARGET EXT prvo (sa fallback-om) + hardening
  local target_ext; target_ext="$(decide_target_ext "$in")"

  # Skini whitespace i spusti na mala slova (za svaki slučaj)
  target_ext="${target_ext//[[:space:]]/}"
  target_ext="${target_ext,,}"

  # Ako nije striktno gif/png/jpg → podrazumevano jpg
  [[ "$target_ext" =~ ^(gif|png|jpg)$ ]] || target_ext="jpg"

  # 3) Izgradi izlaz bez seckanja putanje
  local stem="${in%.[Ww][Ee][Bb][Pp]}"     # /a/b/photo.gif.webp -> /a/b/photo.gif
  local dir;  dir="$(dirname -- "$stem")"
  local file; file="$(basename -- "$stem")"

  # Skini samo “pre-webp” ekstenziju iz imena fajla (ne iz foldera)
  case "${file,,}" in
    *.gif|*.png|*.jpg|*.jpeg) file="${file%.*}" ;;
  esac

  local out="${dir}/${file}.${target_ext}"

  # 4) Ako već postoji, preskoči
  if [ -f "$out" ] || [ -d "$out" ]; then
    if [ "${use_simple_progress:-0}" = "1" ]; then
      if [ "${HAS_FLOCK}" = "1" ]; then
        flock "$PROGRESS_LOCK" bash -c 'echo $(($(cat "$PROGRESS_FILE")+1)) >"$PROGRESS_FILE"'
      else
        echo $(($(cat "$PROGRESS_FILE")+1)) >"$PROGRESS_FILE" 2>/dev/null || true
      fi
    fi
    echo "$S_SKIP [$stamp] Skipped: $(abspath "$in") (exists as $(abspath "$out"))" | tee -a "$LOG_FILE" >&2
    return 0
  fi

  # 5) Log progres
  if [ "${use_simple_progress:-0}" = "1" ]; then
    local current
    if [ "${HAS_FLOCK}" = "1" ]; then
      current=$(flock "$PROGRESS_LOCK" bash -c 'c=$(($(cat "$PROGRESS_FILE")+1)); echo "$c" >"$PROGRESS_FILE"; echo "$c"')
    else
      current=$(($(cat "$PROGRESS_FILE")+1)); echo "$current" >"$PROGRESS_FILE" 2>/dev/null || true
    fi
    echo "$S_ARROW [$stamp] [$current/$total] Converting: $(abspath "$in") → $(abspath "$out")" | tee -a "$LOG_FILE"
  else
    echo "$S_ARROW [$stamp] Converting: $(abspath "$in") → $(abspath "$out")" | tee -a "$LOG_FILE"
  fi

  # 6) Konverzija
  local err
  # 6) Konverzija (forsiraj encoder prefiksom)
  local err out_uri
  case "$target_ext" in
    gif)
      out_uri="gif:$out"
      if err=$("$IM_CMD" "$in" -coalesce -strip -colors 256 -dither FloydSteinberg -layers OptimizeFrame "$out_uri" 2>&1); then :; else
        echo "$S_ERR [$stamp] ERROR during conversion: $(abspath "$in") → $(abspath "$out")" | tee -a "$LOG_FILE" >&2
        echo "   Details: $err" | tee -a "$LOG_FILE" >&2
        echo 1 >>"$FAIL_FILE"; return 1
      fi
      ;;
    png)
      out_uri="png:$out"
      if err=$("$IM_CMD" "$in" -strip -define png:compression-level=9 -define png:compression-filter=5 "$out_uri" 2>&1); then :; else
        echo "$S_ERR [$stamp] ERROR during conversion: $(abspath "$in") → $(abspath "$out")" | tee -a "$LOG_FILE" >&2
        echo "   Details: $err" | tee -a "$LOG_FILE" >&2
        echo 1 >>"$FAIL_FILE"; return 1
      fi
      ;;
    jpg)
      out_uri="jpg:$out"
      if err=$("$IM_CMD" "$in" -auto-orient -strip -quality "$QUALITY" "$out_uri" 2>&1); then :; else
        echo "$S_ERR [$stamp] ERROR during conversion: $(abspath "$in") → $(abspath "$out")" | tee -a "$LOG_FILE" >&2
        echo "   Details: $err" | tee -a "$LOG_FILE" >&2
        echo 1 >>"$FAIL_FILE"; return 1
      fi
      ;;
  esac


  # 7) Validacija output-a
  if ! is_valid_image "$out" "$target_ext"; then
    echo "$S_ERR [$stamp] ERROR: invalid output produced: $(abspath "$in") → $(abspath "$out")" | tee -a "$LOG_FILE" >&2
    rm -f "$out"
    echo 1 >>"$FAIL_FILE"; return 1
  fi

  # 8) Statistika i brisanje originala
  local in_b out_b in_h out_h delta
  in_b="$(filesize_bytes "$in")"; out_b="$(filesize_bytes "$out")"
  in_h="$(format_size "$in_b")"; out_h="$(format_size "$out_b")"
  if [ "$in_b" -gt 0 ]; then
    delta=$(awk "BEGIN{printf \"%.1f\", (1 - $out_b/$in_b)*100}")
    if awk "BEGIN{exit ($delta < 0)}"; then delta="↓${delta}%"; else delta="↑${delta#-}%"; fi
  else
    delta="N/A"
  fi
  echo "$S_OK [$stamp] Success: $(abspath "$in") → $(abspath "$out") ($in_h → $out_h, $delta)" | tee -a "$LOG_FILE"

  if [ "$DELETE_ORIGINAL" = "1" ]; then
    rm -f -- "$in"
    echo "  ${S_BIN}Deleted: $(abspath "$in")" | tee -a "$LOG_FILE"
  fi
}

export -f convert_file is_animated_webp has_alpha can_read_image is_valid_image decide_target_ext

# ------------------------------- Run -----------------------------------------
echo "Found $total .webp files. Parallel: $nproc_cmd"
echo "Using: $IM_CMD | QUALITY=$QUALITY | DELETE_ORIGINAL=$DELETE_ORIGINAL | EMOJI=$EMOJI"
[ "$use_pv" = "1" ] && echo "Progress: pv" || { [ "$use_simple_progress" = "1" ] && echo "Progress: simple"; }
echo

if [ "$use_pv" = "1" ]; then
  find . $find_depth -type f -iname '*.webp' -print0 \
  | xargs -0 -n 1 -I {} bash -c 'abspath "$1"' _ {} \
  | pv -lps "$total" -N "Converting" \
  | xargs -n 1 -P "$nproc_cmd" -I {} bash -c 'convert_file "$1"' _ {}
else
  find . $find_depth -type f -iname '*.webp' -print0 \
  | xargs -0 -n 1 -I {} bash -c 'abspath "$1"' _ {} \
  | xargs -n 1 -P "$nproc_cmd" -I {} bash -c 'convert_file "$1"' _ {}
fi

echo | tee -a "$LOG_FILE"
echo "---" | tee -a "$LOG_FILE"
success="$(grep -cE "^(✓|\[OK\]) .* Success:" "$LOG_FILE" || true)"
skipped="$(grep -cE "^(⊘|\[SKIP\]) .* Skipped:" "$LOG_FILE" || true)"
errors="$(grep -cE "^(✗|\[ERR\]) .* ERROR" "$LOG_FILE" || true)"
echo "=== REPORT ==="                  | tee -a "$LOG_FILE"
echo "Converted successfully: $success" | tee -a "$LOG_FILE"
echo "Skipped (exists):      $skipped" | tee -a "$LOG_FILE"
echo "Errors:                $errors"  | tee -a "$LOG_FILE"
echo "Total candidates:      $total"   | tee -a "$LOG_FILE"
echo "Detailed log: $LOG_FILE"

[ -s "$FAIL_FILE" ] && exit 1 || { echo; echo "✓ All done!"; }
