//! Output-adapter tests: verbatim stdin delivery and the clipboard fallback.

mod common;

use common::{FakeOutput, temporary_directory};
use whistt::output::{CommandSpec, Delivery, ProcessOutput, TextOutput, deliver};

#[test]
fn unicode_and_line_breaks_reach_stdin_verbatim() {
    let directory = temporary_directory("output-stdin");
    let typed = directory.join("typed.txt");
    let copied = directory.join("copied.txt");
    let output = ProcessOutput {
        insert: CommandSpec::new("tee", [typed.clone()]),
        copy: CommandSpec::new("tee", [copied.clone()]),
        notify: CommandSpec::new("true", [] as [&str; 0]),
    };

    // Shell metacharacters and multi-byte text must survive untouched; there is
    // no trailing newline, so no Enter key can reach the focused application.
    let text = "日本語のテスト。\n改行もそのまま\n絵文字 🎙 \"quotes\" $(rm -rf /) `id`; echo";
    output.insert(text).expect("the insertion should succeed");

    assert_eq!(std::fs::read_to_string(&typed).unwrap(), text);
    assert!(!std::fs::read_to_string(&typed).unwrap().ends_with('\n'));
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
