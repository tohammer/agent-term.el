# copilot-ide.el

Run an AI coding agent CLI — [GitHub Copilot CLI](https://docs.github.com/copilot/concepts/agents/about-copilot-cli)
or [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) — in a
[ghostel](https://github.com/dakra/ghostel) terminal inside Emacs, one session per
project. Optionally, an MCP server lets the agent call Emacs: xref, imenu,
tree-sitter, Flycheck/Flymake diagnostics, open buffers, the current region.

Typical uses:

- keep an agent session next to the code of each project and toggle it with one key,
- continue or resume the last agent conversation of a project,
- let the agent ask Emacs (and its LSP client) for definitions and references
  instead of grepping.

Heavily inspired by and based on [claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el)
by Yoav Orot (manzaltu), used under GPL-3.0.

## Requirements

- Emacs 28.1 or newer
- [ghostel](https://github.com/dakra/ghostel) 0.56 or newer, with its native module
- [transient](https://github.com/magit/transient) 0.9.0 or newer
- the agent CLI on `PATH`: `copilot` or `claude`

## Quick start

```elisp
(use-package copilot-ide
  :vc (:url "https://github.com/tohammer/copilot-ide.el")
  :bind ("C-c C-'" . copilot-ide-menu)
  :custom
  (copilot-ide-agent 'claude))   ; or 'copilot (the default)
```

Then, in a file of a project, `M-x copilot-ide` starts the agent in a side
window. Run it again to hide or show the window.

## Installation

### Emacs 30+ (`use-package :vc`)

```elisp
(use-package copilot-ide
  :vc (:url "https://github.com/tohammer/copilot-ide.el")
  :commands (copilot-ide copilot-ide-menu))
```

### Emacs 29 (`package-vc-install`)

```elisp
(package-vc-install "https://github.com/tohammer/copilot-ide.el")
(require 'copilot-ide)
```

### Doom Emacs

In `packages.el`:

```elisp
(package! ghostel :recipe (:host github :repo "dakra/ghostel"))
(package! copilot-ide :recipe (:host github :repo "tohammer/copilot-ide.el"))
```

In `config.el`:

```elisp
(use-package! copilot-ide
  :commands (copilot-ide copilot-ide-menu))
```

Doom shows terminal buffers as popups by default. To show sessions in the
current window instead (with `copilot-ide-use-side-window` set to nil):

```elisp
(set-popup-rule! "^\\*\\(copilot\\|claude\\)\\[" :ignore t)
```

## Usage

| Command                            | Description                                               |
|------------------------------------|-----------------------------------------------------------|
| `copilot-ide`                      | Start the agent for the project, or toggle its window     |
| `copilot-ide-start-agent`          | Start a chosen agent, regardless of `copilot-ide-agent`    |
| `copilot-ide-continue`             | Start with `--continue` (last conversation of the project) |
| `copilot-ide-resume`               | Start with `--resume`; `C-u` asks for a session ID        |
| `copilot-ide-stop`                 | Stop the session                                          |
| `copilot-ide-toggle`               | Hide or show the session window                           |
| `copilot-ide-toggle-recent`        | Hide all session windows, or show the most recent one     |
| `copilot-ide-switch-to-buffer`     | Select the session window                                 |
| `copilot-ide-list-sessions`        | Pick one of the running sessions                          |
| `copilot-ide-send-prompt`          | Send a prompt from the minibuffer                         |
| `copilot-ide-send-escape`          | Send ESC to the agent                                     |
| `copilot-ide-insert-newline`       | Insert a newline in the agent prompt                      |
| `copilot-ide-check-status`         | Show the agent CLI version                                |
| `copilot-ide-menu`                 | Transient menu with all of the above and the settings     |

The session commands act on the session of the current buffer when called
from a session buffer, otherwise on the session of the current project.

Keys in a session buffer (in addition to ghostel's own):

| Key          | Action                                                     |
|--------------|------------------------------------------------------------|
| `S-RET`      | `copilot-ide-insert-newline` (backslash + return)          |
| `C-<escape>` | `copilot-ide-send-escape`                                  |
| `C-_`        | sent to the agent, even when an undo mode binds it globally |

Add keys that Emacs should handle instead of the terminal to
`copilot-ide-emacs-keybindings`, e.g. `'("C-l")`.

## Configuration

### Session and window

| Variable                          | Default    | Description                                                  |
|-----------------------------------|------------|--------------------------------------------------------------|
| `copilot-ide-agent`               | `copilot`  | Agent for new sessions: `copilot` or `claude`                 |
| `copilot-ide-cli-path`            | `nil`      | Agent executable; nil means `copilot` or `claude` on `PATH`  |
| `copilot-ide-cli-extra-flags`     | `""`       | Extra flags, split like a shell command line                 |
| `copilot-ide-environment`         | `nil`      | Extra `"NAME=VALUE"` environment variables for the agent     |
| `copilot-ide-buffer-name-function`| default    | Called with the project directory and the agent              |
| `copilot-ide-use-side-window`     | `t`        | Side window; nil uses `pop-to-buffer-same-window`            |
| `copilot-ide-window-side`         | `right`    | `left`, `right`, `top` or `bottom`                           |
| `copilot-ide-window-width`        | `100`      | Width for left/right side windows                            |
| `copilot-ide-window-height`       | `20`       | Height for top/bottom side windows                           |
| `copilot-ide-focus-on-open`       | `t`        | Select the window when it is shown                           |
| `copilot-ide-show-modeline`       | `t`        | Turn `hide-mode-line-mode` off in session buffers            |
| `copilot-ide-emacs-keybindings`   | `()`       | Keys handled by their global Emacs binding                   |

Example for a different Claude model:

```elisp
(setq copilot-ide-agent 'claude
      copilot-ide-cli-extra-flags "--model sonnet")
```

### Tool permissions

Entries are passed to the agent as they are, so they use the agent's own syntax.

| Variable                          | Copilot flag         | Claude flag          |
|-----------------------------------|----------------------|----------------------|
| `copilot-ide-mcp-available-tools` | `--available-tools`  | not supported (warning) |
| `copilot-ide-mcp-excluded-tools`  | `--excluded-tools`   | `--disallowedTools`  |
| `copilot-ide-mcp-allow-tools`     | `--allow-tool`       | `--allowedTools`     |
| `copilot-ide-mcp-deny-tools`      | `--deny-tool`        | `--disallowedTools`  |

Copilot entries look like `"ServerName"` or `"ServerName(tool_name)"`;
Claude entries like `"mcp__emacs-tools"`, `"mcp__emacs-tools__imenu_list_symbols"`
or `"Bash(git log:*)"`.

```elisp
;; Let Claude use all Emacs tools without asking.
(setq copilot-ide-mcp-allow-tools '("mcp__emacs-tools"))
;; The same for Copilot.
(setq copilot-ide-mcp-allow-tools '("emacs-tools"))
```

### Emacs MCP tools

```elisp
(with-eval-after-load 'copilot-ide
  (copilot-ide-emacs-tools-setup))
```

This turns on `copilot-ide-enable-mcp-server` and registers the tools below
under the MCP server name `emacs-tools`. The server listens on 127.0.0.1
only, on a free port (or `copilot-ide-mcp-server-port`), and every session
gets an endpoint with a random secret token; other requests are refused.

| Tool                     | Description                                               |
|--------------------------|-----------------------------------------------------------|
| `xref_find_definitions`  | Definitions of an identifier (LSP, else grep)             |
| `xref_find_references`   | References to an identifier (LSP, else grep)              |
| `xref_find_apropos`      | Symbols matching a pattern                                |
| `imenu_list_symbols`     | Functions, classes and variables of a file                |
| `treesit_info`           | Tree-sitter node or tree of a file                        |
| `get_diagnostics`        | Flycheck/Flymake errors of a file or the project          |
| `project_info`           | Project directory and file count                          |
| `get_buffer_content`     | Content of an open buffer, including unsaved changes      |
| `list_open_buffers`      | Open file buffers, modified ones marked                   |
| `get_visible_buffers`    | Buffers visible in windows and their line ranges          |
| `get_current_region`     | The region or cursor position of the last file buffer     |
| `compilation_errors`     | Errors from the project's last `M-x compile`              |
| `eval_elisp`             | Evaluate an Emacs Lisp expression                         |

Relative file paths are resolved against the project root. The agent asks
for permission before each tool call unless the tool is allowed with
`copilot-ide-mcp-allow-tools`; be careful with `eval_elisp`.

Your own tools:

```elisp
(defun my-project-todo-count ()
  ;; Run in the user's last file buffer of the session's project.
  (copilot-ide-mcp-server-with-session-context nil
    (number-to-string (how-many "TODO" (point-min) (point-max)))))

(copilot-ide-make-tool
 :name "todo_count"
 :function #'my-project-todo-count
 :description "Count TODO markers in the user's current buffer"
 :args nil)
```

Tool functions receive their arguments in the order of `:args`; JSON `false`
and `null` arrive as nil. `copilot-ide-mcp-server-with-session-context` makes
the user's last file buffer of the session's project current and binds
`default-directory` to the project root.

## Debugging

```elisp
(setq copilot-ide-debug t)
(copilot-ide-show-debug)   ; *copilot-ide-debug*
(copilot-ide-clear-debug)
```

Or use the debug submenu of `copilot-ide-menu`.

## Development

```sh
make            # byte-compile (warnings are errors), checkdoc, tests
make test
```

The dependencies are found through `LOAD_PATH`, e.g.
`make LOAD_PATH="-L ../transient/lisp -L ../compat -L ../ghostel/lisp"`.
The session tests start `test/fake-agent` in ghostel and are skipped when
ghostel or its native module is not available. How the package works is
described in [docs/architecture.md](docs/architecture.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

This package is based on [claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el)
by Yoav Orot, Copyright (C) 2025 Yoav Orot, used under GPL-3.0.

## AI Disclaimer

This package was developed with the help of AI coding agents.
