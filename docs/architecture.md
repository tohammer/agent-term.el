# Architecture

agent-term runs an agent CLI (GitHub Copilot CLI or Claude Code) in a
ghostel terminal, one session per project directory, and optionally serves
Emacs functions to the agent over MCP.

## Files

| File                              | Role                                                          |
|-----------------------------------|---------------------------------------------------------------|
| `agent-term.el`                  | Agents, sessions, command line, display, commands             |
| `agent-term-draft.el`            | Draft buffers: persistent prompts sent with C-c C-c          |
| `agent-term-transient.el`        | `agent-term-menu` and its submenus                           |
| `agent-term-mcp-server.el`       | Tool registry, session registry, server lifecycle             |
| `agent-term-mcp-http-server.el`  | HTTP/1.1 server and MCP JSON-RPC dispatch                     |
| `agent-term-emacs-tools.el`      | The Emacs tools (xref, imenu, treesit, buffers, …)            |
| `agent-term-diagnostics.el`      | The `get_diagnostics` tool (Flycheck/Flymake)                  |
| `agent-term-debug.el`            | Logging                                                       |

## Autoloads

`agent-term.el` requires all other files. Commands defined in
`agent-term-draft.el` and `agent-term-transient.el` call functions of
`agent-term.el`, so their autoload cookies name `"agent-term"` as the file
to load (`;;;###autoload (autoload 'agent-term-draft "agent-term" nil t)`);
a plain cookie would load only their own file and fail with
`void-function` in a fresh Emacs. Test:
`agent-term-test-autoloads-load-main-file`.

## Emacs versions

The package supports Emacs 28.1. Only `treesit_info` needs tree-sitter
(Emacs 29): its functions are declared, and `agent-term-mcp--treesit-p`
checks each of them with `fboundp` before use (which also keeps
package-lint quiet). Test: `agent-term-test-treesit-info-without-treesit`.
CI (`.github/workflows/test.yml`) runs `make all` on 28.2, 30.2 and 31.1,
with ghostel from MELPA and its prebuilt native module.

## Agents

`agent-term-agents` describes each agent by a plist: display name,
default program and the flags for the MCP config and the four tool lists.
Everything else is shared, because both CLIs agree on it:

- `--continue` and `--resume [ID]`,
- an MCP config JSON of the form `{"mcpServers": {"emacs-tools": {"type": "http", "url": …}}}`
  (Copilot: `--additional-mcp-config`, Claude: `--mcp-config`),
- backslash + return inserts a newline in the prompt.

Flags with values are passed as `--flag=value`: Claude declares the tool
and MCP flags as variadic (`<tools...>`), and the `=` form keeps a
following argument from being taken as another value. Tool lists are joined with commas, which both
accept. Claude has a single `--disallowedTools` for both excluded and
denied tools, so the two lists are merged into one flag. Claude has no
equivalent of Copilot's `--available-tools`; the option is ignored there
with a warning.

The argument list is built as a list (`agent-term--build-args`) and handed
to `ghostel-exec`, so no shell quoting is involved. Only
`agent-term-cli-extra-flags` is split with `split-string-shell-command`.

Tests: `agent-term-test-args-*`.

## Sessions

A `agent-term--session` struct holds agent, directory, buffer, process and
the MCP session token. `agent-term--sessions` maps the project directory
(project root, or `default-directory` outside a project) to the session.
The session buffer also points to its session through the buffer-local
`agent-term--buffer-session`, so commands run from the session buffer use
that session without a project lookup (`agent-term--current-session`).

Buffer names come from `agent-term-buffer-name-function`
(`*copilot[dir]*`, `*claude[dir]*`) and are made unique with
`generate-new-buffer-name`. Lookups never go through the name.

Start (`agent-term--create-session`):

1. register the MCP session (the agent connects right after starting),
2. display the buffer, so `ghostel-exec` sizes the terminal to the window
   and the agent does not receive a resize right after start-up,
3. `ghostel-exec` with `ghostel-environment` let-bound to
   `agent-term-environment` + the global value,
4. buffer-local setup: session pointer, `ghostel-exit-functions` and
   `kill-buffer-hook` entries that end the session, key overrides.

On any error the session is ended and the buffer killed.

End (`agent-term--end-session`) is idempotent: it only acts while the
table still maps the directory to that very session. It runs from the
agent's exit (ghostel kills the buffer afterwards) and from
`kill-buffer-hook` (`agent-term-stop`, or the user killing the buffer).

Tests: `agent-term-test-same-basename-projects`,
`agent-term-test-agent-exit-ends-session`,
`agent-term-test-failed-start-cleans-up`,
`agent-term-test-send-prompt-from-session-buffer`.

### ghostel behaviours this relies on

- `ghostel-exec` calls `ghostel-mode` on a buffer that is not in it yet,
  which runs `kill-all-local-variables`. Buffer-local settings made before
  the call are lost; everything is set up after it, and the environment is
  passed by dynamic binding (ghostel reads `ghostel-environment` while
  spawning). Test: `agent-term-test-session-environment-and-args`.
- ghostel switches input modes with `use-local-map`, and the maps are
  shared by all ghostel buffers. `local-set-key` would change every ghostel
  buffer. The session keys are therefore an entry in the buffer-local
  `minor-mode-overriding-map-alist`, keyed by the buffer-local
  `agent-term--keybinding-override`. That entry also ranks above global
  minor modes, which is what makes `C-_` reach the agent. Its keymap
  inherits from `agent-term-session-map`, where users add keys. Test:
  `agent-term-test-session-keys-are-buffer-local`.
- ghostel's process sentinel cleans up ghostel's own state (and, for the
  native PTY, kills the child). The package must not replace it; it hooks
  into `ghostel-exit-functions` instead.
- `ghostel-paste-string` sends bracketed paste, so a multi-line prompt from
  `agent-term-send-prompt` is not submitted line by line.

## Drafts

`agent-term-draft.el`. A draft is a buffer in `agent-term-draft-major-mode`
with the minor mode `agent-term-draft-mode` (C-c C-c send, C-c C-k cancel).
It is identified by an id (creation time plus random suffix) and stored as
two files in `agent-term-draft-directory`: `ID.eld` (plist: id, project
directory, agent, creation time) and `ID.txt` (the text). Both are written
only while the text is not blank; a draft that is or becomes blank has no
files, so empty drafts never show up as saved. Sending or cancelling
deletes both; otherwise only emptying the draft does. Test:
`agent-term-test-draft-empty-not-saved`.

- **Many drafts:** every `agent-term-draft` creates a new id and buffer;
  buffers are found by their buffer-local id, never by name. Test:
  `agent-term-test-draft-many`.
- **Saving:** a repeating timer (`agent-term-draft-save-delay`) writes every
  draft whose `buffer-chars-modified-tick` changed; it stops when no draft
  buffer is left. `kill-buffer-hook` and `kill-emacs-hook` save as well.
  `after-change-functions` is not used: in Emacs 31, after a change of
  major mode the first change in the buffer skips a buffer-local
  after-change function (reproduced in batch; a message or redisplay in
  between hides it). Tests: `agent-term-test-draft-saved-while-typing`,
  `agent-term-test-draft-survives-kill-and-restart`.
- **Major-mode changes:** the draft variables, the minor mode and the
  kill-buffer hook are permanent-local, so e.g. `M-x markdown-mode` keeps
  the buffer a saved draft. Test:
  `agent-term-test-draft-survives-major-mode-change`.
- **Target:** the project directory, resolved at send time with
  `agent-term--session-for-directory`, so drafts outlive sessions and Emacs
  restarts. Without a session, sending fails and the draft is kept. Test:
  `agent-term-test-draft-kept-without-session`.
- **Sending:** `agent-term--send-text` (bracketed paste, then Return after
  0.1 s), shared with `agent-term-send-prompt`. Test:
  `agent-term-test-draft-send`.
- **Buffer names** have no leading `*`: Doom's popup defaults treat such
  buffers as popups and kill them when their window closes.

## Display

With `agent-term-use-side-window`, `display-buffer-in-side-window` with the
configured side and size. Otherwise `pop-to-buffer-same-window`, which
honors `display-buffer-alist` (Doom popup rules apply; see the README for
the `:ignore` rule). Hiding uses `quit-restore-window`: it deletes windows
made for the buffer and shows the previous buffer in a window that was
reused. Test: `agent-term-test-toggle-in-single-window`.

## MCP server

`agent-term-mcp-server.el` keeps the tool list (`agent-term-make-tool`
replaces a tool of the same name) and the session table (token → project
directory, session buffer, last active file buffer). The server starts
with the first session when `agent-term-enable-mcp-server` is set and
stops when the last session ends.

`agent-term-mcp-http-server.el` is a small HTTP/1.1 server on
`make-network-process`, 127.0.0.1 only, one request per connection:

- The filter collects data until the headers and `Content-Length` bytes
  of body are complete. Test: `agent-term-test-mcp-body-in-separate-write`.
- Only `POST /mcp/TOKEN` for a registered token is served (else 404);
  other methods get 405. The token is 128 bits from `/dev/urandom`. A
  request with a non-local `Origin` header gets 403 (DNS rebinding). No
  CORS headers are sent. Tests: `agent-term-test-mcp-rejects-*`.
- JSON-RPC: `initialize` (echoes a supported protocol version, else the
  newest), `ping`, `tools/list`, `tools/call`. Notifications get 202.
  Protocol errors are JSON-RPC errors with the request id
  (`-32700`, `-32601`, `-32602`, `-32603`); errors inside a tool become a
  result with `isError`. Tests: `agent-term-test-mcp-*`.
- Arguments: JSON `false` and `null` reach the tool function as nil; a
  required argument may be `false` but not `null` or missing.

Tools that need the user's context wrap their body in
`agent-term-mcp-server-with-session-context`: it makes the last active
file buffer of the project current (tracked by a cheap
`post-command-hook`, `agent-term--track-active-buffer`) and binds
`default-directory` to the project root *after* switching buffers —
`default-directory` is buffer-local in every buffer. Relative file
arguments go through `agent-term-mcp-server-expand-file-name`. Tests:
`agent-term-test-mcp-tool-runs-in-project-directory`,
`agent-term-test-relative-path-uses-project`.

The grep fallback of the xref tools uses one POSIX ERE for rg and
`grep -E`; the definitions pattern requires the identifier after a
definition keyword or at the start of an assignment. Test:
`agent-term-test-grep-definitions-only`.

## What earlier versions did wrong

Do not reintroduce these.

| Problem | Now |
|---|---|
| Three terminal backends (vterm, eat, ghostel) with resize, reflow and scroll workarounds for vterm and eat | ghostel only |
| `setq-local ghostel-environment` before `ghostel-exec` was wiped by `ghostel-mode`, so `TERM_PROGRAM=emacs` and `FORCE_CODE_TERMINAL` never reached the agent | environment let-bound; the defaults were dropped (agents have been running with ghostel's `TERM_PROGRAM=ghostty`), `agent-term-environment` for own variables |
| `local-set-key` in the session changed the keymap of every ghostel buffer | buffer-local `minor-mode-overriding-map-alist` entry |
| `set-process-sentinel` replaced ghostel's sentinel | `ghostel-exit-functions` |
| Sessions were looked up by buffer name derived from the directory name, so two projects named `src` shared one buffer and stopping one killed the other | session struct per directory, unique buffer names |
| `agent-term-send-escape`/`-insert-newline` looked up the session via the project of `default-directory`, failing in session buffers outside a project | buffer-local session pointer |
| Hiding with `delete-window` failed when the session filled the frame | `quit-restore-window` |
| MCP endpoints were `/mcp/copilot-DIR-TIMESTAMP` and unknown or missing session ids were served; with `Access-Control-Allow-Origin: *`, any web page could call `eval_elisp` | random token, unknown tokens refused, Origin check, no CORS |
| `json-rpc-error` was never defined, so every protocol error became "Invalid error symbol" with id null | `agent-term-mcp-error` and correct codes and ids |
| JSON `false` arrived as the non-nil `:false`, so `whole_file: false` meant true | converted to nil |
| web-server handled a request as soon as the headers were complete; a body in a later TCP segment was lost | own HTTP server that waits for `Content-Length` |
| The "definitions" grep matched every `def`/`class` line of the project | identifier-specific pattern |
| Tools resolved relative paths against the last buffer's directory | project root |
| Tool names carried a `copilot_cli_` prefix | plain names under the server name `emacs-tools` |
| The package was called copilot-ide, though it runs Claude as well and is a terminal runner rather than an IDE | renamed to agent-term |

## Known limitations and open points

- One session per project directory; starting a second agent for the same
  project toggles the existing session.
- The server speaks Streamable HTTP without SSE: no server-initiated
  messages, no progress notifications.
- The IDE features of Claude Code that claude-code-ide.el provides over
  its WebSocket IDE protocol (diffs shown in Emacs, at-mentions of the
  selection) are not implemented; Claude only gets the MCP tools.
- `eval_elisp` is registered by `agent-term-emacs-tools-setup`; the agents
  ask before each call unless the user allows the tool.
