# claude-tmux

An Emacs package that sends file references from the current buffer to a Claude CLI session running inside a tmux pane.

## How it works

When you invoke a send command, the package:

1. Computes the absolute path and, if a project is detected, the project-relative path of the current buffer file.
2. Scans all tmux panes for a running process whose arguments match `claude`.
3. If a Claude pane is found, it sends the file reference to that pane. If multiple panes are found, it prompts you to choose one.
4. If no Claude pane is found, it creates a new tmux split, optionally runs `claude` in it, and then sends the reference.

## Requirements

- Emacs 27.1 or later
- tmux running in the terminal where Emacs is launched (or accessible via the tmux server)
- Claude CLI installed and available on your PATH

## Installation

Drop `claude-tmux.el` somewhere on your `load-path`, then add this to your init file:

```elisp
(require 'claude-tmux)
```

Or with `use-package`:

```elisp
(use-package claude-tmux
  :load-path "/path/to/claude-tmux"
  :custom
  ;; Send project-relative path when available, else fall back to absolute
  (claude-tmux-prefer-project-relative t)
  ;; Prefix added before the path when sending to the tmux pane
  ;; Default " %s" sends a bare path; use "@%s" for the @ mention style
  (claude-tmux-file-reference-format " %s")
  ;; Automatically run `claude` in a newly created pane before sending the reference
  (claude-tmux-start-claude-in-new-pane t)
  ;; Switch tmux focus to the Claude pane after sending
  (claude-tmux-switch-after-send nil)
  ;; Direction of the new pane: "-h" horizontal, "-v" vertical
  (claude-tmux-create-pane-args '("-h"))
  ;; The command started in a new pane when claude-tmux-start-claude-in-new-pane is t
  (claude-tmux-claude-command "claude")
  :bind
  ("C-c c f" . claude-tmux-send-file-reference)
  ("C-c c t" . claude-tmux-dispatch))
```

## Commands

| Command | Description |
|---|---|
| `M-x claude-tmux-dispatch` | Open the transient menu (recommended entry point) |
| `M-x claude-tmux-send-file-reference` | Send smart path (project-relative if available, else absolute) |
| `M-x claude-tmux-send-absolute-path` | Always send the absolute path |
| `M-x claude-tmux-send-project-relative-path` | Send project-relative path, falling back to absolute |

For `claude-tmux-send-file-reference`, passing a prefix argument (`C-u`) forces an absolute path even when a project-relative path is available.

### Transient menu

`M-x claude-tmux-dispatch` opens a transient menu (requires the `transient` package, which is bundled with Emacs 29+). The menu exposes toggles for the most common options and the three send actions.

```
Options
  r  Prefer project-relative  on/off
  s  Switch to pane after send  on/off
  c  Start claude in new pane  on/off

Send
  f  Send file reference (smart)
  a  Send absolute path
  p  Send project-relative path
```

## Configuration

All options are in the `claude-tmux` customization group (`M-x customize-group RET claude-tmux`).

### claude-tmux-prefer-project-relative

Default: `t`

When non-nil, send the project-relative path when one is available. Falls back to the absolute path if no project root is found.

### claude-tmux-start-claude-in-new-pane

Default: `t`

When non-nil, send the command in `claude-tmux-claude-command` followed by Enter to a newly created pane before sending the file reference.

### claude-tmux-switch-after-send

Default: `nil`

When non-nil, switch tmux focus to the Claude pane after sending the reference.

### claude-tmux-create-pane-args

Default: `'("-h")`

Arguments passed to `tmux split-window` when creating a new pane. Use `'("-v")` for a vertical split. You can add further arguments such as `"-p" "40"` to control the pane size.

### claude-tmux-file-reference-format

Default: `" %s"`

Format string for the text sent to the pane. The single `%s` is replaced with the chosen path. For example, set it to `"@%s"` if you want the reference prefixed with `@`.

### claude-tmux-claude-regexp

Default: `"\\bclaude\\b"`

Regular expression matched against `ps` output to detect a running Claude process. Adjust this if your Claude binary has a different name.

### claude-tmux-claude-command

Default: `"claude"`

Command sent to a newly created pane when `claude-tmux-start-claude-in-new-pane` is non-nil.

### claude-tmux-tmux-binary

Default: `"tmux"`

Path or name of the tmux executable.

## License

MIT. See LICENSE for details.
