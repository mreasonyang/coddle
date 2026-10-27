from pathlib import Path

app = str(Path(defines["app"]).resolve())
format = "UDZO"
filesystem = "HFS+"
files = [(app, "Coddle.app")]
symlinks = {"Applications": "/Applications"}
icon = str(Path(app) / "Contents/Resources/AppIcon.icns")
background = defines["background"]
window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
icon_size = 96
text_size = 13
grid_spacing = 80
arrange_by = None
icon_locations = {"Coddle.app": (166, 190), "Applications": (474, 190)}
