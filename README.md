# WebP → JPG Converter Script

This repository provides a reliable Bash script that converts all uploaded `.webp` images to `.jpg` format.  
It is primarily intended for WordPress and other CMS setups where `.webp` uploads cause compatibility or CDN issues.

---

## Why You Should Avoid Uploading `.webp` Files

Although `.webp` can reduce file size, it frequently introduces several problems:

1. **Browser and email incompatibility**  
   Many email clients, older browsers, and tools cannot display `.webp` images properly.

2. **CDN optimization conflicts**  
   CDNs like BunnyCDN, Cloudflare, and KeyCDN already serve `.webp` automatically from `.jpg` sources.  
   Uploading `.webp` files can lead to double compression, reduced image quality, and cache duplication.

3. **WordPress plugin and theme issues**  
   Some plugins (e.g., Elementor, WooCommerce) and thumbnail generators expect `.jpg` or `.png` images and fail on `.webp`.

4. **No real performance advantage**  
   When your CDN and caching handle image optimization, `.webp` brings no measurable speed benefit and adds unnecessary complexity.

**Recommendation:** Always upload `.jpg` or `.png` files. Let your CDN perform automatic `.webp` delivery.

---

## Features

- Detects both ImageMagick 6 (`convert`) and 7 (`magick`)
- Parallel processing using all available CPU cores
- Skips already converted files
- Creates detailed logs with timestamps and file sizes
- Never overwrites or deletes original images

---

## Installation

```bash
sudo apt install imagemagick -y
git clone https://github.com/lukapaunovic/convert-all-webp-back-to-jpg.git
cd webp-to-jpg
chmod +x convert.sh
