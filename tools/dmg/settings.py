# dmgbuild settings for the OpenDisplay disk images. Run through build.sh,
# which passes the app bundle as -D app=..., this directory as -D dir=... and
# the background it just rendered from layout.json as -D background=...
#
# dmgbuild writes the window layout straight into the image's .DS_Store, so
# no Finder or AppleScript step is involved and the build runs headless.
import json
import os.path

app = defines["app"]
here = defines["dir"]
app_name = os.path.basename(app.rstrip("/"))

with open(os.path.join(here, "layout.json")) as fp:
    layout = json.load(fp)

format = "UDZO"
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: it sets a FinderInfo xattr on the bundle, which breaks
# `codesign --verify --strict` on the copied app. Finder already hides the
# .app extension unless the user shows all extensions.

# dmgbuild combines background.png and the background@2x.png beside it into
# one HiDPI TIFF.
background = defines["background"]

# WindowBounds is the window frame, title bar included. The title bar is
# 28 pt before macOS 26 and 32 pt from macOS 26, so size for the shorter one:
# newer systems clip 4 pt of the background's empty bottom margin instead of
# showing a strip past its edge.
TITLE_BAR = 28
window = layout["window"]
window_rect = ((200, 120), (window["width"], window["height"] + TITLE_BAR))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

arrange_by = None
icon_size = layout["iconSize"]
text_size = layout["textSize"]
icon_locations = {
    app_name: (layout["app"]["x"], layout["app"]["y"]),
    "Applications": (layout["applications"]["x"], layout["applications"]["y"]),
}
