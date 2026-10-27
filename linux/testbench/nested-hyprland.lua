-- Sacrificial Hyprland for od-sender tests.
-- Runs as a window inside the real session; no Omarchy includes, no
-- autostart, permissions off. Started by nested.sh.

hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = 1,
})

hl.config({
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
    },
})

-- Super+Return opens a terminal inside the nested instance (it inherits the
-- nested HYPRLAND_INSTANCE_SIGNATURE and WAYLAND_DISPLAY); Super+Shift+E quits.
hl.bind("SUPER + Return", hl.dsp.exec_cmd("foot"))
hl.bind("SUPER + SHIFT + E", hl.dsp.exit())
