# agent-term.el

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
  (`M-x ghostel-download-module`, or see ghostel's README)
- [transient](https://github.com/magit/transient) 0.9.0 or newer
- the agent CLI on `PATH`: `copilot` or `claude`

## Quick start

```elisp
(use-package agent-term
  :vc (:url "https://github.com/tohammer/agent-term.el")
  :bind ("C-c C-'" . agent-term-menu)
  :custom
  (agent-term-agent 'claude))   ; or 'copilot (the default)
```

Then, in a file of a project, `M-x agent-term` starts the agent in a side
window. Run it again to hide or show the window.

## Installation

### Emacs 30+ (`use-package :vc`)

```elisp
(use-package agent-term
  :vc (:url "https://github.com/tohammer/agent-term.el")
  :commands (agent-term agent-term-menu))
```

### Emacs 29 (`package-vc-install`)

```elisp
(package-vc-install "https://github.com/tohammer/agent-term.el")
(require 'agent-term)
```

### Doom Emacs

In `packages.el`:

```elisp
(package! ghostel :recipe (:host github :repo "dakra/ghostel"))
(package! agent-term :recipe (:host github :repo "tohammer/agent-term.el"))
```

In `config.el`:

```elisp
(use-package! agent-term
  :commands (agent-term agent-term-menu))
```

Doom shows terminal buffers as popups by default. To show sessions in the
current window instead (with `agent-term-use-side-window` set to nil):

```elisp
(set-popup-rule! "^\\*\\(copilot\\|claude\\)\\[" :ignore t)
```

## Usage

| Command                            | Description                                               |
|------------------------------------|-----------------------------------------------------------|
| `agent-term`                      | Start the agent for the project, or toggle its window     |
| `agent-term-start-agent`          | Start a chosen agent, regardless of `agent-term-agent`    |
| `agent-term-continue`             | Start with `--continue` (last conversation of the project) |
| `agent-term-resume`               | Start with `--resume`; `C-u` asks for a session ID        |
| `agent-term-stop`                 | Stop the session                                          |
| `agent-term-toggle`               | Hide or show the session window                           |
| `agent-term-toggle-recent`        | Hide all session windows, or show the most recent one     |
| `agent-term-switch-to-buffer`     | Select the session window                                 |
| `agent-term-list-sessions`        | Pick one of the running sessions                          |
| `agent-term-draft`                | Write a prompt in a draft buffer (`C-u`: saved drafts)    |
| `agent-term-drafts`               | Reopen a saved draft of any project                       |
| `agent-term-send-prompt`          | Send a prompt from the minibuffer                         |
| `agent-term-send-escape`          | Send ESC to the agent                                     |
| `agent-term-insert-newline`       | Insert a newline in the agent prompt                      |
| `agent-term-check-status`         | Show the agent CLI version                                |
| `agent-term-menu`                 | Transient menu with all of the above and the settings     |

The session commands act on the session of the current buffer when called
from a session buffer, otherwise on the session of the current project.

Keys in a session buffer (in addition to ghostel's own):

| Key          | Action                                                     |
|--------------|------------------------------------------------------------|
| `S-RET`      | `agent-term-insert-newline` (backslash + return)          |
| `C-<escape>` | `agent-term-send-escape`                                  |
| `C-_`        | sent to the agent, even when an undo mode binds it globally |
| `C-c '`      | `agent-term-draft`: open a new draft                       |

These keys live in `agent-term-session-map`; add your own there. Keys that
Emacs should handle with their global binding instead of the terminal go
into `agent-term-emacs-keybindings`, e.g. `'("C-l")`.

## Drafts

For longer prompts, press `C-c '` in a session buffer (or `M-x
agent-term-draft` in any buffer of the project). A draft buffer opens below,
with full Emacs editing:

| Key           | Action                                                         |
|---------------|----------------------------------------------------------------|
| `C-c C-c`     | Send the draft to the agent and submit it, close the draft     |
| `C-u C-c C-c` | Send it into the agent's prompt without submitting             |
| `C-c C-k`     | Throw the draft away                                           |

- Any number of drafts can be open at once, for one or several projects.
- Each draft is written to `agent-term-draft-directory` while you type and
  stays there until it is sent or thrown away. Killing the buffer or
  restarting Emacs does not lose it: `C-u C-c '` reopens a saved draft of
  the project, `M-x agent-term-drafts` one of any project. Starting a
  session reports its saved drafts. Empty drafts (only whitespace) are
  not saved.
- A draft belongs to its project directory and goes to the session that runs
  there when you send it. Without a running session, the draft is kept.

```elisp
(setq agent-term-draft-major-mode #'markdown-mode   ; default: text-mode
      agent-term-draft-window-height 15)
```

## Configuration

### Session and window

| Variable                          | Default    | Description                                                  |
|-----------------------------------|------------|--------------------------------------------------------------|
| `agent-term-agent`               | `copilot`  | Agent for new sessions: `copilot` or `claude`                 |
| `agent-term-cli-path`            | `nil`      | Agent executable; nil means `copilot` or `claude` on `PATH`  |
| `agent-term-cli-extra-flags`     | `""`       | Extra flags, split like a shell command line                 |
| `agent-term-environment`         | `nil`      | Extra `"NAME=VALUE"` environment variables for the agent     |
| `agent-term-buffer-name-function`| default    | Called with the project directory and the agent              |
| `agent-term-use-side-window`     | `t`        | Side window; nil uses `pop-to-buffer-same-window`            |
| `agent-term-window-side`         | `right`    | `left`, `right`, `top` or `bottom`                           |
| `agent-term-window-width`        | `100`      | Width for left/right side windows                            |
| `agent-term-window-height`       | `20`       | Height for top/bottom side windows                           |
| `agent-term-focus-on-open`       | `t`        | Select the window when it is shown                           |
| `agent-term-show-modeline`       | `t`        | Turn `hide-mode-line-mode` off in session buffers            |
| `agent-term-emacs-keybindings`   | `()`       | Keys handled by their global Emacs binding                   |
| `agent-term-draft-directory`     | `~/.emacs.d/agent-term-drafts/` | Where drafts are kept until sent           |
| `agent-term-draft-major-mode`    | `text-mode` | Major mode of draft buffers                                 |
| `agent-term-draft-window-height` | `10`       | Height of the draft window                                   |
| `agent-term-draft-save-delay`    | `0.5`      | Idle seconds after which changed drafts are saved            |
| `agent-term-draft-save-interval` | `10`       | Seconds between saves while typing without a pause           |

Example for a different Claude model:

```elisp
(setq agent-term-agent 'claude
      agent-term-cli-extra-flags "--model sonnet")
```

### Tool permissions

Entries are passed to the agent as they are, so they use the agent's own syntax.

| Variable                          | Copilot flag         | Claude flag          |
|-----------------------------------|----------------------|----------------------|
| `agent-term-mcp-available-tools` | `--available-tools`  | not supported (warning) |
| `agent-term-mcp-excluded-tools`  | `--excluded-tools`   | `--disallowedTools`  |
| `agent-term-mcp-allow-tools`     | `--allow-tool`       | `--allowedTools`     |
| `agent-term-mcp-deny-tools`      | `--deny-tool`        | `--disallowedTools`  |

Copilot entries look like `"ServerName"` or `"ServerName(tool_name)"`;
Claude entries like `"mcp__emacs-tools"`, `"mcp__emacs-tools__imenu_list_symbols"`
or `"Bash(git log:*)"`.

```elisp
;; Let Claude use all Emacs tools without asking.
(setq agent-term-mcp-allow-tools '("mcp__emacs-tools"))
;; The same for Copilot.
(setq agent-term-mcp-allow-tools '("emacs-tools"))
```

### Emacs MCP tools

```elisp
(with-eval-after-load 'agent-term
  (agent-term-emacs-tools-setup))
```

This turns on `agent-term-enable-mcp-server` and registers the tools below
under the MCP server name `emacs-tools`. The server listens on 127.0.0.1
only, on a free port (or `agent-term-mcp-server-port`), and every session
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

`get_diagnostics` uses Flycheck when it is active in a buffer, else Flymake;
set `agent-term-diagnostics-backend` to `flycheck` or `flymake` to force one.

Relative file paths are resolved against the project root. The agent asks
for permission before each tool call unless the tool is allowed with
`agent-term-mcp-allow-tools`; be careful with `eval_elisp`.

Your own tools:

```elisp
(defun my-project-todo-count ()
  ;; Run in the user's last file buffer of the session's project.
  (agent-term-mcp-server-with-session-context nil
    (number-to-string (how-many "TODO" (point-min) (point-max)))))

(agent-term-make-tool
 :name "todo_count"
 :function #'my-project-todo-count
 :description "Count TODO markers in the user's current buffer"
 :args nil)
```

Tool functions receive their arguments in the order of `:args`; JSON `false`
and `null` arrive as nil. `agent-term-mcp-server-with-session-context` makes
the user's last file buffer of the session's project current and binds
`default-directory` to the project root.

## Debugging

```elisp
(setq agent-term-debug t)
(agent-term-show-debug)   ; *agent-term-debug*
(agent-term-clear-debug)
```

Or use the debug submenu of `agent-term-menu`.

| Variable                       | Default                | Description                                 |
|--------------------------------|------------------------|---------------------------------------------|
| `agent-term-debug`             | `nil`                  | Log to the debug buffer                     |
| `agent-term-debug-buffer`      | `"*agent-term-debug*"` | Name of the debug buffer                    |
| `agent-term-log-with-context`  | `t`                    | Prefix messages with the project name       |

## Development

```sh
make            # byte-compile (warnings are errors), checkdoc, tests
make test
```

The dependencies are taken from package.el (`~/.emacs.d/elpa`), or from
directories given in `LOAD_PATH`, e.g.
`make LOAD_PATH="-L ../transient/lisp -L ../compat -L ../ghostel/lisp"`.
CI runs `make all` on Emacs 28.2, 30.2 and 31.1.
The session tests start `test/fake-agent` in ghostel and are skipped when
ghostel or its native module is not available. How the package works is
described in [docs/architecture.md](docs/architecture.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

This package is based on [claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el)
by Yoav Orot, Copyright (C) 2025 Yoav Orot, used under GPL-3.0.

## AI Disclaimer

This package was developed with the help of AI coding agents.
