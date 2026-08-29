# The app icon

`AppIcon.svg` is the source. `make-icon.py` writes it, so the shapes and the
colours live in one script rather than in a binary nobody can edit.

The colours are the app's own, from `Sources/NotebookApp/Palette.swift`. If the
accent changes there it should change here, or the Dock will disagree with the
window.

## What it is

A sheet of prose with one band picked out, and a score dot at the head of it.
That band is the whole of what this app does that a document reader does not:
it finds the passage. Two sheets behind say corpus rather than document.

**Drawn for 16 points, checked at 16 points.** At that size the prose lines
merge into texture and what is left is a white sheet with a teal band across it,
which is still the idea. Anything that only works at 512 is decoration.

## Rebuilding

Needs `rsvg-convert` (`brew install librsvg`). `iconutil` ships with macOS.

    python3 make-icon.py
    rm -rf NotebookMLX.iconset && mkdir NotebookMLX.iconset
    for s in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
             "128 128x128" "256 128x128@2x" "256 256x256" \
             "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
      set -- $s
      rsvg-convert -w "$1" -h "$1" AppIcon.svg -o "NotebookMLX.iconset/icon_$2.png"
    done
    iconutil -c icns NotebookMLX.iconset -o AppIcon.icns

`AppIcon.icns` is committed so that building the app needs none of the above.
