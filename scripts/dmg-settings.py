# dmgbuild settings for the installer window; geometry matches scripts/make-dmg-background.swift.
#   dmgbuild -s scripts/dmg-settings.py -D app=CodeCatch.app -D icon=AppIcon.icns -D background=background.png CodeCatch CodeCatch.dmg
format = "UDZO"
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
window_rect = ((200, 200), (640, 400))
icon_size = 128
text_size = 13
icon_locations = {"CodeCatch.app": (170, 190), "Applications": (470, 190)}
