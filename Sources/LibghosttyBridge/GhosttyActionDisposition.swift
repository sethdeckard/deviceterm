// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GhosttyKit

/// Reports the libghostty actions deviceterm
/// doesn't handle, once each.
///
/// deviceterm loads the user's Ghostty config through
/// `ghostty_config_load_default_files`, and the C API exposes no keybind
/// mutator, so a `keybind = ctrl+shift+n=new_tab` line is parsed, matched,
/// and dispatched to `action_cb`. deviceterm owns tabs, windows, and splits
/// itself, so nothing answers it. Without a diagnostic the shortcut simply
/// looks broken.
///
/// An *enabled* catalog chord never gets this far: main-menu key-equivalent
/// matching precedes `keyDown:`, so the engine never sees it. What reaches
/// here is a chord the catalog does not claim, or one whose menu item
/// validated disabled for the current focus and fell through.
///
/// ## Everything unhandled reports, deliberately
///
/// Do not infer from a tag whether a keystroke caused an action. libghostty
/// offers at least three counterexamples:
///
///   - `readonly` looks like engine feedback but is emitted *only* from the
///     `toggle_readonly` binding.
///   - `show_gtk_inspector` looks GTK-only but ships through core
///     `App.performAction`, which every apprt shares.
///   - `secure_input` has two producers: `toggle_secure_input` sends
///     `.toggle`, termios password detection sends `.on` / `.off`.
///
/// A tag filtered on a wrong guess is a shortcut that fails silently, the
/// bug this type exists to prevent. Reporting is one-shot, so the cost of
/// filtering nothing is bounded by the number of distinct tags the process
/// sees. There is therefore no classification here, and the message says
/// "unhandled" rather than "declined": it claims only what is observable,
/// never why.
///
/// Two exceptions live in `GhosttyRuntime.reportUnhandledAction`, not here,
/// because an action's payload rather than its tag settles them. They read
/// a fact off the C union instead of guessing.
///
/// One report per tag, for the lifetime of the process. A keybind held
/// down would otherwise flood stderr at the repeat rate.
@MainActor
enum GhosttyActionDisposition {
    private static var reportedTags: Set<UInt32> = []

    /// Labels for the message. Cosmetic only: an unlabeled tag still
    /// reports, by number, so visibility never depends on this table being
    /// current. Names identify action tags, not bindings. One action can
    /// back several bindings, and `prompt_title` carries a payload naming
    /// which one, which a single diagnostic line does not read.
    private static let names: [UInt32: String] = [
        GHOSTTY_ACTION_QUIT.rawValue: "quit",
        GHOSTTY_ACTION_NEW_WINDOW.rawValue: "new_window",
        GHOSTTY_ACTION_NEW_TAB.rawValue: "new_tab",
        GHOSTTY_ACTION_CLOSE_TAB.rawValue: "close_tab",
        GHOSTTY_ACTION_NEW_SPLIT.rawValue: "new_split",
        GHOSTTY_ACTION_CLOSE_ALL_WINDOWS.rawValue: "close_all_windows",
        GHOSTTY_ACTION_CLOSE_WINDOW.rawValue: "close_window",
        GHOSTTY_ACTION_TOGGLE_MAXIMIZE.rawValue: "toggle_maximize",
        GHOSTTY_ACTION_TOGGLE_FULLSCREEN.rawValue: "toggle_fullscreen",
        GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW.rawValue: "toggle_tab_overview",
        GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL.rawValue: "toggle_quick_terminal",
        GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE.rawValue: "toggle_command_palette",
        GHOSTTY_ACTION_TOGGLE_VISIBILITY.rawValue: "toggle_visibility",
        GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY.rawValue: "toggle_background_opacity",
        GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS.rawValue: "toggle_window_decorations",
        GHOSTTY_ACTION_FLOAT_WINDOW.rawValue: "float_window",
        GHOSTTY_ACTION_MOVE_TAB.rawValue: "move_tab",
        GHOSTTY_ACTION_GOTO_TAB.rawValue: "goto_tab",
        GHOSTTY_ACTION_GOTO_SPLIT.rawValue: "goto_split",
        GHOSTTY_ACTION_GOTO_WINDOW.rawValue: "goto_window",
        GHOSTTY_ACTION_RESIZE_SPLIT.rawValue: "resize_split",
        GHOSTTY_ACTION_EQUALIZE_SPLITS.rawValue: "equalize_splits",
        GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM.rawValue: "toggle_split_zoom",
        GHOSTTY_ACTION_RESET_WINDOW_SIZE.rawValue: "reset_window_size",
        GHOSTTY_ACTION_INITIAL_SIZE.rawValue: "initial_size",
        GHOSTTY_ACTION_SIZE_LIMIT.rawValue: "size_limit",
        GHOSTTY_ACTION_CELL_SIZE.rawValue: "cell_size",
        GHOSTTY_ACTION_PRESENT_TERMINAL.rawValue: "present_terminal",
        GHOSTTY_ACTION_RENDER.rawValue: "render",
        GHOSTTY_ACTION_RENDER_INSPECTOR.rawValue: "render_inspector",
        GHOSTTY_ACTION_RENDERER_HEALTH.rawValue: "renderer_health",
        GHOSTTY_ACTION_MOUSE_SHAPE.rawValue: "mouse_shape",
        GHOSTTY_ACTION_MOUSE_VISIBILITY.rawValue: "mouse_visibility",
        GHOSTTY_ACTION_MOUSE_OVER_LINK.rawValue: "mouse_over_link",
        GHOSTTY_ACTION_OPEN_URL.rawValue: "open_url",
        GHOSTTY_ACTION_DESKTOP_NOTIFICATION.rawValue: "desktop_notification",
        GHOSTTY_ACTION_PROGRESS_REPORT.rawValue: "progress_report",
        GHOSTTY_ACTION_COMMAND_FINISHED.rawValue: "command_finished",
        GHOSTTY_ACTION_SHOW_CHILD_EXITED.rawValue: "show_child_exited",
        GHOSTTY_ACTION_SET_TAB_TITLE.rawValue: "set_tab_title",
        GHOSTTY_ACTION_PROMPT_TITLE.rawValue: "prompt_title",
        GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD.rawValue: "copy_title_to_clipboard",
        GHOSTTY_ACTION_INSPECTOR.rawValue: "inspector",
        GHOSTTY_ACTION_START_SEARCH.rawValue: "start_search",
        GHOSTTY_ACTION_END_SEARCH.rawValue: "end_search",
        GHOSTTY_ACTION_SEARCH_TOTAL.rawValue: "search_total",
        GHOSTTY_ACTION_SEARCH_SELECTED.rawValue: "search_selected",
        GHOSTTY_ACTION_SHOW_GTK_INSPECTOR.rawValue: "show_gtk_inspector",
        GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD.rawValue: "show_on_screen_keyboard",
        GHOSTTY_ACTION_SECURE_INPUT.rawValue: "secure_input",
        GHOSTTY_ACTION_READONLY.rawValue: "readonly",
        GHOSTTY_ACTION_KEY_SEQUENCE.rawValue: "key_sequence",
        GHOSTTY_ACTION_KEY_TABLE.rawValue: "key_table",
        GHOSTTY_ACTION_CONFIG_CHANGE.rawValue: "config_change",
        GHOSTTY_ACTION_QUIT_TIMER.rawValue: "quit_timer",
        GHOSTTY_ACTION_UNDO.rawValue: "undo",
        GHOSTTY_ACTION_REDO.rawValue: "redo",
        GHOSTTY_ACTION_CHECK_FOR_UPDATES.rawValue: "check_for_updates",
        GHOSTTY_ACTION_OPEN_CONFIG.rawValue: "open_config",
        GHOSTTY_ACTION_RELOAD_CONFIG.rawValue: "reload_config"
    ]

    /// The libghostty name for `tag`, or nil when the label table doesn't
    /// cover it. Reporting does not depend on this.
    static func name(for tag: UInt32) -> String? {
        names[tag]
    }

    /// The line to write for an unhandled action, or nil when this tag has
    /// already been reported. Returning the message rather than writing it
    /// keeps the one-shot rule testable without a sink to inject.
    static func unhandledMessage(for tag: UInt32) -> String? {
        guard reportedTags.insert(tag).inserted else { return nil }
        let described = name(for: tag) ?? "tag \(tag)"
        return "deviceterm: unhandled ghostty action: \(described)\n"
    }

    /// Clears the reported-tag set so a test starts from a known state.
    /// Process-wide state otherwise persists across tests in one run.
    static func resetReportedTags() {
        reportedTags.removeAll()
    }
}
