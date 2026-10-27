//! `--workspace` on Sway: assign the workspace to the virtual output, switch
//! to it (Sway creates an assigned workspace on its output), move it there
//! if it already lived elsewhere, then switch back to the workspace the user
//! had focused. Sway's default `mouse_warping output` may move the pointer
//! across outputs on the way; it ends on the user's workspace again.

/// A Sway command argument in double quotes.
pub fn quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

/// The commands, in order. `focused` is the user's focused workspace.
pub fn plan(workspace: &str, output: &str, focused: Option<&str>) -> Vec<String> {
    let (ws, out) = (quote(workspace), quote(output));
    let mut steps = vec![
        format!("workspace {ws} output {out}"),
        format!("workspace {ws}"),
        format!("move workspace to output {out}"),
    ];
    if let Some(prev) = focused.filter(|p| *p != workspace) {
        steps.push(format!("workspace {}", quote(prev)));
    }
    steps
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assign_switch_move_and_return() {
        assert_eq!(
            plan("8", "HEADLESS-2", Some("1")),
            [
                r#"workspace "8" output "HEADLESS-2""#,
                r#"workspace "8""#,
                r#"move workspace to output "HEADLESS-2""#,
                r#"workspace "1""#,
            ]
        );
        // The user was on that very workspace: it moves, focus follows it.
        assert_eq!(plan("8", "HEADLESS-2", Some("8")).len(), 3);
    }

    #[test]
    fn names_are_quoted() {
        assert_eq!(quote(r#"a "b" \c"#), r#""a \"b\" \\c""#);
    }
}
