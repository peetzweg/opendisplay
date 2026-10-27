KDE Wayland protocols the KDE backend speaks, copied unchanged from
[plasma-wayland-protocols](https://invent.kde.org/libraries/plasma-wayland-protocols)
(commit 1db07441870d54157e937674b99380a7dcc0fb32, `src/protocols/`).
The screencast and fake-input files are LGPL-2.1-or-later, the output
device/management files MIT-CMU, as stated in their `<copyright>` blocks.

- `zkde-screencast-unstable-v1.xml`: virtual outputs streamed over PipeWire.
- `fake-input.xml`: `org_kde_kwin_fake_input`, pointer injection.
- `kde-output-device-v2.xml`, `kde-output-management-v2.xml`: reading and
  setting an output's scale and position.
