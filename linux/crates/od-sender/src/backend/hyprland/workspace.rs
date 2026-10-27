//! `--workspace`: show a given workspace on the virtual output without
//! taking the user's focus. Hyprland >= 0.55 dispatches through Lua
//! (`dispatch` on the IPC socket is `hl.dispatch(<expr>)`); in 0.56.2:
//!
//! * `hl.dsp.workspace.move({ workspace, monitor })` moves an *existing*
//!   workspace ("Workspace not found" otherwise);
//! * `hl.dsp.focus({ monitor })` / `hl.dsp.focus({ workspace })` focus a
//!   monitor, or switch to a workspace (creating it on the focused monitor);
//! * `hl.dsp.cursor.move({ x, y })` puts the pointer back, since focusing a
//!   monitor warps it.

/// A Lua string literal.
pub fn lua_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\{}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// What the session sees of Hyprland right before placing the workspace.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Before {
    /// The monitor the workspace is on, if it exists.
    pub workspace_on: Option<String>,
    /// The monitor's active workspace is already the one wanted.
    pub already_shown: bool,
    /// The user's focused monitor.
    pub focused: Option<String>,
    /// Pointer position in layout coordinates.
    pub cursor: Option<(f64, f64)>,
}

/// The dispatch expressions, in order, that put `workspace` on `output`
/// and hand focus and pointer back to where the user had them.
pub fn plan(workspace: &str, output: &str, before: &Before) -> Vec<String> {
    if before.workspace_on.as_deref() == Some(output) && before.already_shown {
        return vec![];
    }
    let (ws, out) = (lua_str(workspace), lua_str(output));
    let mut steps = Vec::new();
    if before.workspace_on.as_deref().is_some_and(|m| m != output) {
        steps.push(format!(
            "hl.dsp.workspace.move({{ workspace = {ws}, monitor = {out} }})"
        ));
    }
    // Switching to it from the virtual output creates it there if needed,
    // and makes it the output's visible workspace.
    steps.push(format!("hl.dsp.focus({{ monitor = {out} }})"));
    steps.push(format!("hl.dsp.focus({{ workspace = {ws} }})"));
    if let Some(prev) = before.focused.as_deref().filter(|p| *p != output) {
        steps.extend(restore(prev, before.cursor));
    }
    steps
}

/// Focus and pointer back to the user's monitor.
pub fn restore(focused: &str, cursor: Option<(f64, f64)>) -> Vec<String> {
    let mut steps = vec![format!(
        "hl.dsp.focus({{ monitor = {} }})",
        lua_str(focused)
    )];
    if let Some((x, y)) = cursor {
        steps.push(format!("hl.dsp.cursor.move({{ x = {x}, y = {y} }})"));
    }
    steps
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strings_are_lua_safe() {
        assert_eq!(lua_str("8"), r#""8""#);
        assert_eq!(lua_str(r#"name:a"b\c"#), r#""name:a\"b\\c""#);
    }

    fn before(on: Option<&str>, shown: bool) -> Before {
        Before {
            workspace_on: on.map(Into::into),
            already_shown: shown,
            focused: Some("eDP-1".into()),
            cursor: Some((812.0, 400.5)),
        }
    }

    #[test]
    fn a_new_workspace_is_created_on_the_output_and_focus_returns() {
        assert_eq!(
            plan("8", "od-3f31ed", &before(None, false)),
            [
                r#"hl.dsp.focus({ monitor = "od-3f31ed" })"#,
                r#"hl.dsp.focus({ workspace = "8" })"#,
                r#"hl.dsp.focus({ monitor = "eDP-1" })"#,
                "hl.dsp.cursor.move({ x = 812, y = 400.5 })",
            ]
        );
    }

    #[test]
    fn an_existing_workspace_moves_first() {
        let p = plan("8", "od-3f31ed", &before(Some("eDP-1"), false));
        assert_eq!(
            p[0],
            r#"hl.dsp.workspace.move({ workspace = "8", monitor = "od-3f31ed" })"#
        );
        assert_eq!(p.len(), 5);
    }

    #[test]
    fn nothing_to_do_when_it_is_already_shown_there() {
        assert!(plan("8", "od-3f31ed", &before(Some("od-3f31ed"), true)).is_empty());
        // On the output but not visible: show it, no move.
        let p = plan("8", "od-3f31ed", &before(Some("od-3f31ed"), false));
        assert!(!p[0].contains("workspace.move"));
    }

    #[test]
    fn focus_stays_when_the_user_was_on_the_output() {
        let b = Before {
            focused: Some("od-3f31ed".into()),
            ..before(None, false)
        };
        let p = plan("8", "od-3f31ed", &b);
        assert_eq!(p.len(), 2, "{p:?}");
    }
}
