//! Output-adapter tests: verbatim stdin delivery and the clipboard fallback.

mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
        restore_delay: Duration::from_millis(10),
        paste_lock: Mutex::new(()),
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
        restore_delay: Duration::from_millis(20),
        paste_lock: Mutex::new(()),
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

fn stub_process_output(
    clipboard: &StubSelection,
    primary: &StubSelection,
    paste: PathBuf,
    notify_log: &Path,
    restore_delay: Duration,
) -> ProcessOutput {
    let notify = write_script(
        notify_log.parent().unwrap(),
        "notify-stub",
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n",
            notify_log.display()
        ),
    );
    ProcessOutput {
        mode: OutputMode::Paste,
        type_text: CommandSpec::new("false", [] as [&str; 0]),
        paste: CommandSpec::new(paste, [] as [&str; 0]),
        copy: CommandSpec::new(&clipboard.copy, [] as [&str; 0]),
        copy_primary: CommandSpec::new(&primary.copy, [] as [&str; 0]),
        paste_read: CommandSpec::new(&clipboard.read, [] as [&str; 0]),
        paste_read_primary: CommandSpec::new(&primary.read, [] as [&str; 0]),
        paste_types: CommandSpec::new(&clipboard.types, [] as [&str; 0]),
        paste_types_primary: CommandSpec::new(&primary.types, [] as [&str; 0]),
        clear: CommandSpec::new(&clipboard.clear, [] as [&str; 0]),
        clear_primary: CommandSpec::new(&primary.clear, [] as [&str; 0]),
        notify: CommandSpec::new(notify, [] as [&str; 0]),
        restore_delay,
        paste_lock: Mutex::new(()),
    }
}

#[test]
fn paste_mode_preserves_clipboard_when_another_app_copies_clears_or_sets_image() {
    let directory = temporary_directory("output-race");
    let clipboard_state = directory.join("clipboard.bin");
    let clipboard_mime = directory.join("clipboard.mime");
    let primary_state = directory.join("primary.bin");
    let notify_log = directory.join("notify.log");

    let clipboard = StubSelection {
        copy: write_script(
            &directory,
            "cb-copy",
            &format!(
                "#!/bin/sh\ncat > '{}'\nprintf 'text/plain;charset=utf-8\\n' > '{}'\n",
                clipboard_state.display(),
                clipboard_mime.display()
            ),
        ),
        read: write_script(
            &directory,
            "cb-read",
            &format!(
                "#!/bin/sh\nif [ ! -f '{}' ]; then exit 1; fi\ncat '{}'\n",
                clipboard_state.display(),
                clipboard_state.display()
            ),
        ),
        types: write_script(
            &directory,
            "cb-types",
            &format!(
                "#!/bin/sh\nif [ -f '{}' ]; then cat '{}'; else exit 1; fi\n",
                clipboard_state.display(),
                clipboard_mime.display()
            ),
        ),
        clear: write_script(
            &directory,
            "cb-clear",
            &format!(
                "#!/bin/sh\nrm -f '{}' '{}'\n",
                clipboard_state.display(),
                clipboard_mime.display()
            ),
        ),
    };
    let primary = stub_selection(&directory, "primary", &primary_state);

    // 1. Another app copies new text right after paste, before restore runs.
    std::fs::write(&clipboard_state, "元のクリップボード").unwrap();
    std::fs::write(&clipboard_mime, "text/plain;charset=utf-8\n").unwrap();
    std::fs::write(&primary_state, "元の primary").unwrap();
    let paste_text_race = write_script(
        &directory,
        "paste-text-race",
        &format!(
            "#!/bin/sh\nprintf '別アプリの新規コピー' > '{}'\nprintf 'text/plain;charset=utf-8\\n' > '{}'\n",
            clipboard_state.display(),
            clipboard_mime.display()
        ),
    );
    let output = stub_process_output(
        &clipboard,
        &primary,
        paste_text_race,
        &notify_log,
        Duration::from_millis(10),
    );
    assert_eq!(deliver(&output, "文字起こし結果"), Delivery::Inserted);
    assert_eq!(
        std::fs::read_to_string(&clipboard_state).unwrap(),
        "別アプリの新規コピー",
        "newer text copied by another app must not be overwritten"
    );
    assert_eq!(
        std::fs::read_to_string(&primary_state).unwrap(),
        "元の primary",
        "unchanged primary selection must still be restored"
    );

    // 2. Another app clears the clipboard right after paste (`wl-paste` exits non-zero).
    std::fs::write(&clipboard_state, "元のクリップボード").unwrap();
    std::fs::write(&clipboard_mime, "text/plain;charset=utf-8\n").unwrap();
    std::fs::write(&primary_state, "元の primary").unwrap();
    let paste_clear_race = write_script(
        &directory,
        "paste-clear-race",
        &format!(
            "#!/bin/sh\nrm -f '{}' '{}'\n",
            clipboard_state.display(),
            clipboard_mime.display()
        ),
    );
    let output = stub_process_output(
        &clipboard,
        &primary,
        paste_clear_race,
        &notify_log,
        Duration::from_millis(10),
    );
    assert_eq!(
        deliver(&output, "文字起こし結果"),
        Delivery::Inserted,
        "clearing the clipboard before restore must not trigger a false insertion failure"
    );
    assert!(
        !clipboard_state.exists(),
        "cleared clipboard must remain cleared and not be clobbered by fallback copy"
    );
    assert_eq!(
        std::fs::read_to_string(&primary_state).unwrap(),
        "元の primary"
    );

    // 3. Another app copies an image (`image/png` with no text MIME) right after paste.
    std::fs::write(&clipboard_state, "元のクリップボード").unwrap();
    std::fs::write(&clipboard_mime, "text/plain;charset=utf-8\n").unwrap();
    std::fs::write(&primary_state, "元の primary").unwrap();
    let paste_image_race = write_script(
        &directory,
        "paste-image-race",
        &format!(
            "#!/bin/sh\nprintf '\\x89PNG-binary' > '{}'\nprintf 'image/png\\n' > '{}'\n",
            clipboard_state.display(),
            clipboard_mime.display()
        ),
    );
    let output = stub_process_output(
        &clipboard,
        &primary,
        paste_image_race,
        &notify_log,
        Duration::from_millis(10),
    );
    assert_eq!(deliver(&output, "文字起こし結果"), Delivery::Inserted);
    assert_eq!(
        std::fs::read(&clipboard_state).unwrap(),
        b"\x89PNG-binary",
        "binary image copied by another app must stay intact"
    );
    assert_eq!(
        std::fs::read_to_string(&primary_state).unwrap(),
        "元の primary"
    );
    assert!(
        !notify_log.exists(),
        "none of the post-paste clipboard races should emit error notifications"
    );

    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn paste_mode_does_not_clobber_clipboard_or_skip_primary_when_restore_fails() {
    let directory = temporary_directory("output-restore-err");
    let clipboard_state = directory.join("clipboard.bin");
    let primary_state = directory.join("primary.bin");
    let notify_log = directory.join("notify.log");
    let pasted = directory.join("pasted.txt");
    let pasted_done = directory.join("pasted.done");

    let mut clipboard = stub_selection(&directory, "clipboard", &clipboard_state);
    // Start with empty clipboard so `clear` runs on restore; make `clear` fail
    // after paste to simulate a transient `wl-copy --clear` failure.
    clipboard.clear = write_script(&directory, "cb-clear-fail", "#!/bin/sh\nexit 1\n");
    // Also simulate `copy` tracking whether `deliver()` wrongly runs fallback copy!
    let copy_count = directory.join("copy.count");
    clipboard.copy = write_script(
        &directory,
        "cb-copy-counted",
        &format!(
            "#!/bin/sh\ncat > '{}'\nprintf 'x' >> '{}'\n",
            clipboard_state.display(),
            copy_count.display()
        ),
    );
    let primary = stub_selection(&directory, "primary", &primary_state);
    std::fs::write(&primary_state, "元の primary").unwrap();

    let paste = write_script(
        &directory,
        "paste-ok",
        &format!(
            "#!/bin/sh\ncat '{}' > '{}'\ntouch '{}'\n",
            clipboard_state.display(),
            pasted.display(),
            pasted_done.display()
        ),
    );
    let output = stub_process_output(
        &clipboard,
        &primary,
        paste,
        &notify_log,
        Duration::from_millis(10),
    );

    assert_eq!(deliver(&output, "確定テキスト"), Delivery::Inserted);
    assert!(pasted_done.exists());
    assert_eq!(std::fs::read_to_string(&pasted).unwrap(), "確定テキスト");
    assert_eq!(
        std::fs::read_to_string(&copy_count).unwrap().len(),
        1,
        "fallback copy must not run when paste succeeded"
    );
    assert_eq!(
        std::fs::read_to_string(&primary_state).unwrap(),
        "元の primary",
        "primary selection must still be restored even if clipboard restore errored"
    );
    assert!(!notify_log.exists());
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn paste_mode_serializes_back_to_back_sessions_so_original_clipboard_survives() {
    let directory = temporary_directory("output-concurrent");
    let clipboard_state = directory.join("clipboard.bin");
    let primary_state = directory.join("primary.bin");
    let notify_log = directory.join("notify.log");
    let pasted = directory.join("pasted.log");
    std::fs::write(&clipboard_state, "本当の元のクリップボード").unwrap();
    std::fs::write(&primary_state, "本当の元の primary").unwrap();

    let clipboard = stub_selection(&directory, "clipboard", &clipboard_state);
    let primary = stub_selection(&directory, "primary", &primary_state);
    let paste = write_script(
        &directory,
        "paste-append",
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"$(cat '{}')\" >> '{}'\n",
            clipboard_state.display(),
            pasted.display()
        ),
    );
    let output = Arc::new(stub_process_output(
        &clipboard,
        &primary,
        paste,
        &notify_log,
        Duration::from_millis(60),
    ));

    let out1 = output.clone();
    let t1 = std::thread::spawn(move || deliver(out1.as_ref(), "一回目の発話"));
    std::thread::sleep(Duration::from_millis(15));
    let out2 = output.clone();
    let t2 = std::thread::spawn(move || deliver(out2.as_ref(), "二回目の発話"));

    assert_eq!(t1.join().unwrap(), Delivery::Inserted);
    assert_eq!(t2.join().unwrap(), Delivery::Inserted);
    assert_eq!(
        std::fs::read_to_string(&pasted).unwrap(),
        "一回目の発話\n二回目の発話\n"
    );
    assert_eq!(
        std::fs::read_to_string(&clipboard_state).unwrap(),
        "本当の元のクリップボード",
        "second session must not snapshot the first session's transient transcript"
    );
    assert_eq!(
        std::fs::read_to_string(&primary_state).unwrap(),
        "本当の元の primary"
    );
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn paste_mode_skips_restore_for_oversized_clipboard_instead_of_aborting_paste() {
    let directory = temporary_directory("output-oversized");
    let clipboard_state = directory.join("clipboard.bin");
    let primary_state = directory.join("primary.bin");
    let notify_log = directory.join("notify.log");
    let pasted = directory.join("pasted.txt");

    // 16 MiB + 1024 bytes exceeds MAX_SNAPSHOT_BYTES.
    std::fs::write(&clipboard_state, vec![b'A'; 16 * 1024 * 1024 + 1024]).unwrap();
    std::fs::write(&primary_state, "元の primary").unwrap();

    let clipboard = stub_selection(&directory, "clipboard", &clipboard_state);
    let primary = stub_selection(&directory, "primary", &primary_state);
    let paste = write_script(
        &directory,
        "paste-oversized",
        &format!(
            "#!/bin/sh\ncat '{}' > '{}'\n",
            clipboard_state.display(),
            pasted.display()
        ),
    );
    let output = stub_process_output(
        &clipboard,
        &primary,
        paste,
        &notify_log,
        Duration::from_millis(10),
    );

    assert_eq!(
        deliver(&output, "大きな画像の後でも貼り付け成功"),
        Delivery::Inserted
    );
    assert_eq!(
        std::fs::read_to_string(&pasted).unwrap(),
        "大きな画像の後でも貼り付け成功"
    );
    assert!(
        !clipboard_state.exists(),
        "transient transcript is cleared when the previous item skipped snapshotting"
    );
    assert_eq!(
        std::fs::read_to_string(&primary_state).unwrap(),
        "元の primary"
    );
    assert!(!notify_log.exists());
    let _ = std::fs::remove_dir_all(directory);
}
