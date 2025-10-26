WebP to GIF/PNG/JPEG Converter Script

This repository provides a robust Bash script for converting .webp images to their appropriate formats: GIF (for *.gif.webp), JPG (for *.png.webp), and JPG (for all others). It is designed for WordPress and other CMS setups where .webp uploads cause compatibility or CDN issues.

Why You Should Avoid Uploading .webp Files
-----------------------------------------

Although .webp can reduce file size, it often introduces several problems:

1. Browser and email incompatibility
   Many email clients, older browsers, and tools cannot display .webp images properly.

2. CDN optimization conflicts
   CDNs like BunnyCDN, Cloudflare, and KeyCDN already serve .webp automatically from .jpg or .png sources. Uploading .webp files can lead to double compression, reduced image quality, and cache duplication.

3. WordPress plugin and theme issues
   Some plugins (e.g., Elementor, WooCommerce) and thumbnail generators expect .jpg, .png, or .gif images and fail on .webp.

4. No real performance advantage
   When your CDN and caching handle image optimization, .webp brings no measurable speed benefit and adds unnecessary complexity.

Recommendation: Always upload .jpg, .png, or .gif files. Let your CDN perform automatic .webp delivery.

Features
--------

- Smart format detection:
  - Converts animated .webp or *.gif.webp to .gif (preserves animations).
  - Converts *.png.webp or .webp with alpha channel to .png.
  - Converts all other .webp (e.g., *.jpg.webp, *.jpeg.webp, *.webp) to .jpg.
- ImageMagick compatibility: Detects both ImageMagick 6 (convert) and 7 (magick).
- Parallel processing: Utilizes all available CPU cores for faster conversions.
- Skip existing files: Avoids overwriting already converted files.
- Detailed logging: Generates logs with timestamps, file sizes, and success/failure details.
- Safe by default: Never deletes original .webp files unless explicitly enabled (DELETE_ORIGINAL=1).
- Dry run mode: Preview conversions without modifying files (--dry-run).
- Optimized output:
  - GIFs: Reduced to 256 colors with Floyd-Steinberg dithering for smaller file sizes.
  - PNGs: Uses ZIP compression with maximum level and adaptive filtering.
  - JPEGs: Auto-orients based on EXIF data for correct rotation.
- Case-insensitive: Handles extensions like .GIF.webp, .PNG.webp, etc.
- Error handling: Detailed diagnostics for permissions, disk space, or corrupted files.
- Portable: Works on Linux, BSD, and macOS with fallbacks for missing tools.

Installation
------------

Prerequisites:
- ImageMagick: Required for image conversion.
- Optional tools:
  - pv: For progress bar visualization.
  - flock: For synchronized progress updates in parallel mode.
  - wp-cli: For WordPress database updates (if used in a WordPress environment).

Install on Debian/Ubuntu:
```console
  sudo apt update
  sudo apt install imagemagick pv -y
```

Setup:
1. Clone the repository and set up the script:
```console
   cd wp-content/uploads
   git clone https://github.com/lukapaunovic/convert-all-webp-back-to-jpg.git
   cd convert-all-webp-back-to-jpg
   chmod +x convert.sh
```
3. (Optional) Edit convert.sh to set custom variables, e.g.:
   - QUALITY=95: JPEG quality (1–100, default 90).
   - PARALLEL=4: Number of parallel jobs (default: auto-detected CPU cores).
   - DELETE_ORIGINAL=1: Delete original .webp files after successful conversion.
   - DRY_RUN=1: Preview conversions without modifying files.
   - PROGRESS_MODE=pv|simple|none: Progress display mode (default: auto).

Usage
-----

Run the script in the target directory:
```console
  ./convert.sh [directory]
```
Examples:
```console
  ./convert.sh
```
```console
  QUALITY=95 ./convert.sh /path/to/images
  DELETE_ORIGINAL=1 ./convert.sh --progress pv
```
Options:
  -h, --help              Show help
  -q, --quality NUM       JPEG quality (1–100, default 90)
  -p, --parallel NUM      Number of parallel jobs (default: auto)
  -d, --delete            Delete original .webp after success
  -n, --dry-run           Show actions without converting
  --dry-run-limit NUM     Limit dry-run listing (default 20)
  --no-recursive          Do not descend into subdirectories
  --progress MODE         auto|pv|simple|none (default auto)

WordPress Database Update
-------------------------

To update file references in the WordPress database to match the script's output, run the following wp-cli commands as the site user (or use sudo -H -u www-data if needed, replacing www-data with your web server user):
```console
wp search-replace --regex '(?i)\.gif\.webp\b'  '.gif' --all-tables --report-changed-only
wp search-replace --regex '(?i)\.jpe?g\.webp\b' '.jpg' --all-tables --report-changed-only
wp search-replace --regex '(?i)\.png\.webp\b'  '.jpg' --all-tables --report-changed-only
wp search-replace --regex '(?i)\.webp\b'       '.jpg' --all-tables --report-changed-only
```
These commands replace case-insensitive .gif.webp, .png.webp, .jpg.webp, .jpeg.webp, and .webp extensions with .gif, .png, or .jpg in the database.

Notes:
- Ensure wp-cli is installed and configured.
- Run these commands after the script to avoid broken image links.
- Back up your database before running search-replace.

Contributing
------------

Contributions are welcome! Please submit pull requests or issues to the GitHub repository:
https://github.com/lukapaunovic/convert-all-webp-back-to-jpg

License
-------

This project is licensed under the MIT License.
