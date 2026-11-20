//! Output-adapter tests: verbatim stdin delivery and the clipboard fallback.

mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use common::{FakeOutput, temporary_directory};
use whistt::config::OutputMode;
use whistt::output::{CommandSpec, Delivery, ProcessOutput, TextOutput, deliver};

#[test]
fn legacy_type_mode_sends_unicode_and_line_breaks_verbatim() {
    let directory = temporary_directory("output-stdin");
    let copied = directory.join("copied.txt");
    let output = ProcessOutput {
        mode: OutputMode::Type,
        type_text: CommandSpec::new("tee", [copied.clone()]),
        paste: CommandSpec::new("true", [] as [&str; 0]),
        copy: CommandSpec::new("false", [] as [&str; 0]),
        copy_primary: CommandSpec::new("false", [] as [&str; 0]),
        paste_read: CommandSpec::new("false", [] as [&str; 0]),
        paste_read_primary: CommandSpec::new("false", [] as [&str; 0]),
        paste_types: CommandSpec::new("false", [] as [&str; 0]),
        paste_types_primary: CommandSpec::new("false", [] as [&str; 0]),
        clear: CommandSpec::new("false", [] as [&str; 0]),
        clear_primary: CommandSpec::new("false", [] as [&str; 0]),
        notify: CommandSpec::new("true", [] as [&str; 0]),
    };

    // Shell metacharacters and multi-byte text must survive untouched; there is
    // no trailing newline, so no Enter key can reach the focused application.
    let text = "日本語のテスト。\n改行もそのまま\n絵文字 🎙 \"quotes\" $(rm -rf /) `id`; echo";
    output.insert(text).expect("the insertion should succeed");

    assert_eq!(std::fs::read_to_string(&copied).unwrap(), text);
    assert!(!std::fs::read_to_string(&copied).unwrap().ends_with('\n'));
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn a_failed_insertion_copies_the_transcript_without_retrying_typing() {
    let output = FakeOutput::failing_insert();
    let delivery = deliver(&output, "テキスト\n二行目");

    assert!(matches!(delivery, Delivery::Copied { .. }), "{delivery:?}");
    assert_eq!(
        output.insert_attempts(),
        vec!["テキスト\n二行目".to_string()],
        "typing must be attempted exactly once"
    );
    assert_eq!(output.copies(), vec!["テキスト\n二行目".to_string()]);
    assert_eq!(output.notifications().len(), 1);
}

#[test]
fn a_failed_insertion_and_copy_still_notifies_the_user() {
    let output = FakeOutput::failing_insert_and_copy();
    let delivery = deliver(&output, "text");

    assert!(matches!(delivery, Delivery::Failed { .. }), "{delivery:?}");
    assert_eq!(output.insert_attempts().len(), 1);
    assert_eq!(output.copies().len(), 1);
    assert_eq!(output.notifications().len(), 1);
}

#[test]
fn a_successful_insertion_does_not_touch_the_clipboard() {
    let output = FakeOutput::new();
    assert!(matches!(deliver(&output, "ok"), Delivery::Inserted));
    assert!(output.copies().is_empty());
    assert!(output.notifications().is_empty());
}

/// Writes an executable stub command whose body ignores its arguments, the
/// way the paste flow appends `--type` to some of the real commands.
fn write_script(directory: &Path, name: &str, body: &str) -> PathBuf {
    let path = directory.join(name);
    std::fs::write(&path, body).unwrap();
    let mut permissions = std::fs::metadata(&path).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&path, permissions).unwrap();
    path
}

/// One file-backed selection: the same stub shape serves the clipboard and
/// the primary selection, differing only in the state file.
struct StubSelection {
    copy: PathBuf,
    read: PathBuf,
    types: PathBuf,
    clear: PathBuf,
}

fn stub_selection(directory: &Path, name: &str, state: &Path) -> StubSelection {
    let state = state.display();
    StubSelection {
        copy: write_script(
            directory,
            &format!("{name}-copy"),
            &format!("#!/bin/sh\ncat > '{state}'\n"),
        ),
        read: write_script(
            directory,
            &format!("{name}-read"),
            &format!("#!/bin/sh\ncat '{state}'\n"),
        ),
        types: write_script(
            directory,
            &format!("{name}-types"),
            &format!(
                "#!/bin/sh\nif [ -f '{state}' ]; then echo 'text/plain;charset=utf-8'; else exit 1; fi\n"
            ),
        ),
        clear: write_script(
            directory,
            &format!("{name}-clear"),
            &format!("#!/bin/sh\nrm -f '{state}'\n"),
        ),
    }
}

#[test]
fn paste_mode_publishes_both_selections_and_restores_them() {
    let directory = temporary_directory("output-paste");
    let clipboard_state = directory.join("clipboard.bin");
    let primary_state = directory.join("primary.bin");
    std::fs::write(&clipboard_state, "前のクリップボード").unwrap();
    std::fs::write(&primary_state, "前の primary").unwrap();

    let clipboard = stub_selection(&directory, "clipboard", &clipboard_state);
    let primary = stub_selection(&directory, "primary", &primary_state);
    // The focused application pastes from the clipboard selection when it
    // receives the chord; the stub records what it would have received.
    let pasted = directory.join("pasted.txt");
    let paste = write_script(
        &directory,
        "paste",
        &format!(
            "#!/bin/sh\ncat '{}' > '{}'\n",
            clipboard_state.display(),
            pasted.display()
        ),
    );

    let output = ProcessOutput {
        mode: OutputMode::Paste,
        type_text: CommandSpec::new("false", [] as [&str; 0]),
        paste: CommandSpec::new(paste, [] as [&str; 0]),
        copy: CommandSpec::new(clipboard.copy, [] as [&str; 0]),
        copy_primary: CommandSpec::new(primary.copy, [] as [&str; 0]),
        paste_read: CommandSpec::new(clipboard.read, [] as [&str; 0]),
        paste_read_primary: CommandSpec::new(primary.read, [] as [&str; 0]),
        paste_types: CommandSpec::new(clipboard.types, [] as [&str; 0]),
        paste_types_primary: CommandSpec::new(primary.types, [] as [&str; 0]),
        clear: CommandSpec::new(clipboard.clear, [] as [&str; 0]),
        clear_primary: CommandSpec::new(primary.clear, [] as [&str; 0]),
        notify: CommandSpec::new("true", [] as [&str; 0]),
    };

    output
        .insert("日本語の確定テキスト")
        .expect("the paste should succeed");

    assert_eq!(
        std::fs::read_to_string(&pasted).unwrap(),
        "日本語の確定テキスト",
        "the application receives the transcript exactly once"
    );
    assert_eq!(
        std::fs::read_to_string(&clipboard_state).unwrap(),
        "前のクリップボード",
        "the previous clipboard contents are restored"
    );
    assert_eq!(
        std::fs::read_to_string(&primary_state).unwrap(),
        "前の primary",
        "the previous primary contents are restored"
    );
    let _ = std::fs::remove_dir_all(directory);
}
