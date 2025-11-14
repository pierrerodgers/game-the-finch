# Site Overhaul Implementation Overview

## Current Site Structure

### Entry Points
- **index.html** - Current landing page with:
  - Black background
  - Embedded Vimeo video reel (1081909242)
  - "Enter Site" button linking to home.html

- **home.html** - Main portfolio page with:
  - Grid layout showing various projects
  - Projects: Sankyo Stream, Music Videos, Telling George, Petty Atlas, Writings
  - Footer with social media links

### Other Pages
- sankyo-stream.html
- music-videos.html
- evenings-you-missed.html
- petty-atlas.html
- writings.html
- sankyo-7.html

## New Assets Available

### Images
- `new-assets/bar_only.png` - Main navigation bar image

### GIFs (in new-assets/gif_finals/)
1. `Substack-A.gif` - For Substack link
2. `reel_icon_final.gif` - For Reel link
3. `book_icon.gif` - For Book link
4. `sparks_logo_final.gif` - For Sparks link
5. `sankyo_flies.gif` - For Sankyo Files (site archive) link

### Labels (in new-assets/labels/)
- `substack_label.png`
- `reel_label.png`
- `book_label.png`
- `coming_soon_label.png`
- `site_archive_label.png`

### Other
- `Rager_Poster.jpg` - Image for Sparks coming soon page

## Implementation Plan

### 1. Restructure Site Architecture

**Phase 1: Backup and Rename**
- Rename current `index.html` to `old-index.html` (backup)
- Keep `home.html` as the "old site" archive

**Phase 2: Create New Landing Page**
- Create new `index.html` with:
  - Background color: #ff9862 (coral/orange)
  - Centered layout
  - `bar_only.png` positioned in center

**Phase 3: Add Interactive Elements**
Within the bar, position 5 clickable GIF icons in order (left to right):
1. **Substack** → https://fergstack.substack.com
   - "thoughts on writing, watching and making films"

2. **Reel** → https://vimeo.com/1081909242?fl=pl&fe=vl
   - "I am available for fire"

3. **Book** → https://www.buildweekproductions.com/sankyostream/p/coffeetablebook
   - "Sankyo Stream is a coffee table book"

4. **Sparks** → /new-assets/Rager_Poster.jpg (or new page)
   - "coming soon"

5. **Sankyo Files** → /home.html (old site archive)
   - "Site archive"

### 2. Update Old Site (home.html)

- Remove the welcome page flow (the old index.html video + enter button)
- Make home.html directly accessible
- This becomes the "archive" section

## Technical Implementation Details

### New index.html Structure
```html
<!DOCTYPE html>
<html lang="en">
<head>
    - Set page title
    - Link to CSS (new or updated style.css)
    - Mobile viewport meta tag
</head>
<body style="background-color: #ff9862;">
    - Container div (centered)
    - Bar image (bar_only.png)
    - Navigation container overlaid on bar
        - 5 GIF icons positioned horizontally
        - Each wrapped in <a> tag with appropriate href
        - Proper spacing (justify-content: space-around/between)
</body>
</html>
```

### CSS Considerations
- Flexbox or CSS Grid for icon positioning
- Responsive design for mobile
- Hover effects on GIF icons (optional)
- Maintain aspect ratio of bar image
- Center everything vertically and horizontally

### File Organization
- Keep existing pages intact (sankyo-stream.html, etc.)
- New assets stay in `new-assets/` folder
- Old assets remain in `images/` folder
- Archive old index.html as backup

## User Requirements Summary

1. ✅ New landing page background: #ff9862
2. ✅ Center bar_only.png
3. ✅ 5 interactive GIFs/labels in order: substack, reel, book, sparks, sankyo_files
4. ✅ Correct links for each icon
5. ✅ Remove welcome page from old site (make home.html the direct archive link)

## Next Steps

1. Create new index.html
2. Style and position elements
3. Test all links
4. Ensure responsive design works
5. Verify old site archive is accessible
