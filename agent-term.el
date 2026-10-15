;;; agent-term.el --- Run Copilot CLI or Claude Code in Emacs  -*- lexical-binding: t; -*-

;; Author: Tobias Hammer <tohammer@users.noreply.github.com>
;; Maintainer: Tobias Hammer <tohammer@users.noreply.github.com>
;; Copyright (C) 2025 Tobias Hammer
;; Copyright (C) 2025 Yoav Orot

;; Based on claude-code-ide.el by Yoav Orot (manzaltu)
;; https://github.com/manzaltu/claude-code-ide.el

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.9.0") (ghostel "0.56.0"))
;; Keywords: ai, copilot, claude, mcp, assistant
;; SPDX-License-Identifier: GPL-3.0-or-later
;; URL: https://github.com/tohammer/agent-term.el

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Runs an AI coding agent CLI -- GitHub Copilot CLI (`copilot') or
;; Claude Code (`claude') -- in a ghostel terminal buffer, one session
;; per project, and optionally connects an HTTP MCP server so the
;; agent can call Emacs functions such as xref, imenu and tree-sitter.
;;
;; Basic usage:
;;   M-x agent-term          Start (or toggle) the session for the project
;;   M-x agent-term-stop     Stop the session
;;   M-x agent-term-menu     Open the transient menu
;;
;; Choose the agent with `agent-term-agent'.  To enable the Emacs MCP
;; tools (xref, imenu, treesit, project info, diagnostics):
;;   (agent-term-emacs-tools-setup)

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'subr-x)
(require 'agent-term-debug)
(require 'agent-term-transient)
(require 'agent-term-mcp-server)
(require 'agent-term-diagnostics)
(require 'agent-term-emacs-tools)

(defvar ghostel-environment)
(defvar ghostel-exit-functions)
(defvar ghostel-kill-buffer-on-exit)
(defvar ghostel--input-mode)
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function ghostel-send-string "ghostel" (string))
(declare-function ghostel-paste-string "ghostel" (string))
(declare-function hide-mode-line-mode "hide-mode-line" (&optional arg))

;;; Customization

(defgroup agent-term nil
  "Run AI coding agent CLIs (Copilot, Claude) in Emacs."
  :group 'tools
  :prefix "agent-term-")

(defconst agent-term-agents
  '((copilot :name "Copilot"
             :program "copilot"
             :mcp-config-flag "--additional-mcp-config"
             :available-tools-flag "--available-tools"
             :excluded-tools-flag "--excluded-tools"
             :allow-tools-flag "--allow-tool"
             :deny-tools-flag "--deny-tool")
    (claude :name "Claude"
            :program "claude"
            :mcp-config-flag "--mcp-config"
            :available-tools-flag nil
            :excluded-tools-flag "--disallowedTools"
            :allow-tools-flag "--allowedTools"
            :deny-tools-flag "--disallowedTools"))
  "The supported agents and how their command line is built.
Each entry is (AGENT . PLIST).  PLIST keys:
  :name                  Display name.
  :program               Default executable.
  :mcp-config-flag       Flag that takes the MCP server JSON.
  :available-tools-flag  Flag for `agent-term-mcp-available-tools', or nil.
  :excluded-tools-flag   Flag for `agent-term-mcp-excluded-tools'.
  :allow-tools-flag      Flag for `agent-term-mcp-allow-tools'.
  :deny-tools-flag       Flag for `agent-term-mcp-deny-tools'.")

(defcustom agent-term-agent 'copilot
  "The agent CLI that new sessions run.
`copilot' runs the GitHub Copilot CLI, `claude' runs Claude Code."
  :type '(choice (const :tag "GitHub Copilot CLI" copilot)
                 (const :tag "Claude Code" claude))
  :group 'agent-term)

(defcustom agent-term-cli-path nil
  "Path to the agent executable.
When nil, the agent's default program (\"copilot\" or \"claude\") is
looked up on the variable `exec-path'."
  :type '(choice (const :tag "Agent default" nil) string)
  :group 'agent-term)

(defcustom agent-term-cli-extra-flags ""
  "Additional flags passed to the agent, as a shell-like string.
The string is split with `split-string-shell-command', so quoting works
as in a shell, but nothing is expanded."
  :type 'string
  :group 'agent-term)

(defcustom agent-term-environment nil
  "Extra environment variables for the agent process.
A list of \"NAME=VALUE\" strings; they take precedence over the
variables ghostel sets."
  :type '(repeat string)
  :group 'agent-term)

(defcustom agent-term-buffer-name-function #'agent-term--default-buffer-name
  "Function that returns the buffer name for a session.
Called with two arguments: the project directory and the agent symbol.
When another buffer already has that name, a unique name is derived
from it."
  :type 'function
  :group 'agent-term)

(defcustom agent-term-window-side 'right
  "Side of the frame where the session window appears."
  :type '(choice (const left) (const right) (const top) (const bottom))
  :group 'agent-term)

(defcustom agent-term-window-width 100
  "Width of the session side window (columns), for left/right placement."
  :type 'integer
  :group 'agent-term)

(defcustom agent-term-window-height 20
  "Height of the session side window (lines), for top/bottom placement."
  :type 'integer
  :group 'agent-term)

(defcustom agent-term-focus-on-open t
  "When non-nil, select the session window when it is displayed."
  :type 'boolean
  :group 'agent-term)

(defcustom agent-term-use-side-window t
  "When non-nil, display sessions in a dedicated side window.
When nil, display them with `pop-to-buffer-same-window', which
honors `display-buffer-alist' (and thus popup rules)."
  :type 'boolean
  :group 'agent-term)

(defcustom agent-term-show-modeline t
  "When non-nil, ensure the mode line is visible in the session buffer.
Some configurations (e.g. Doom Emacs) hide the mode line in terminal
buffers; this option turns `hide-mode-line-mode' off again."
  :type 'boolean
  :group 'agent-term)

(defcustom agent-term-emacs-keybindings '()
  "Keys handled by their global Emacs binding instead of the terminal.
Each entry is a key string accepted by `kbd'.  The global binding at
the time the session starts is used."
  :type '(repeat string)
  :group 'agent-term)

(defcustom agent-term-mcp-available-tools nil
  "Tools the agent may use at all (an allow list for the model).
Entries use the agent's own syntax.  Copilot only (`--available-tools'):
\"ServerName\" or \"ServerName(tool_name)\".  Claude Code has no
equivalent; the option is ignored with a warning there."
  :type '(repeat string)
  :group 'agent-term)

(defcustom agent-term-mcp-excluded-tools nil
  "Tools the agent may not use at all.
Entries use the agent's own syntax.  Copilot (`--excluded-tools'):
\"ServerName\" or \"ServerName(tool_name)\".  Claude
\(`--disallowedTools'): e.g. \"mcp__server\" or \"mcp__server__tool\"."
  :type '(repeat string)
  :group 'agent-term)

(defcustom agent-term-mcp-allow-tools nil
  "Tools the agent may run without asking for permission.
Entries use the agent's own syntax.  Copilot (`--allow-tool'):
\"ServerName\", \"ServerName(tool_name)\" or e.g. \"shell(git)\".
Claude (`--allowedTools'): e.g. \"mcp__emacs-tools\",
\"mcp__emacs-tools__imenu_list_symbols\" or \"Bash(git log:*)\"."
  :type '(repeat string)
  :group 'agent-term)

(defcustom agent-term-mcp-deny-tools nil
  "Tools the agent must never run.
Entries use the agent's own syntax.  Copilot (`--deny-tool', takes
precedence over `--allow-tool').  Claude (`--disallowedTools')."
  :type '(repeat string)
  :group 'agent-term)

;;; State

(cl-defstruct (agent-term--session (:constructor agent-term--session-create)
                                    (:copier nil))
  "A running agent session."
  agent directory buffer process id)

(defvar agent-term--sessions (make-hash-table :test 'equal)
  "Hash table mapping project directories to `agent-term--session's.")

(defvar agent-term--last-accessed-buffer nil
  "Most recently displayed session buffer.")

(defvar-local agent-term--buffer-session nil
  "The session shown in this buffer, or nil.")

(defvar-local agent-term--keybinding-override nil
  "Non-nil enables the session key overrides in this buffer.
Used as the key of an entry in `minor-mode-overriding-map-alist'.")

;;; Agents

(defun agent-term--agent-get (property &optional agent)
  "Return PROPERTY of AGENT (default `agent-term-agent')."
  (let ((agent (or agent agent-term-agent)))
    (plist-get (or (alist-get agent agent-term-agents)
                   (user-error "Unknown agent: %s" agent))
               property)))

(defun agent-term--agent-name (&optional agent)
  "Return the display name of AGENT (default `agent-term-agent')."
  (agent-term--agent-get :name agent))

(defun agent-term--program (&optional agent)
  "Return the executable for AGENT (default `agent-term-agent')."
  (or agent-term-cli-path (agent-term--agent-get :program agent)))

(defun agent-term--cli-available-p (&optional agent)
  "Return non-nil if the executable for AGENT can be found."
  (let ((program (agent-term--program agent)))
    (if (file-name-directory program)
        (file-executable-p (expand-file-name program))
      (executable-find program))))

;;; Sessions

(defun agent-term--default-buffer-name (directory agent)
  "Return the default buffer name for AGENT in DIRECTORY."
  (format "*%s[%s]*" (downcase (agent-term--agent-name agent))
          (file-name-nondirectory (directory-file-name directory))))

(defun agent-term--get-working-directory ()
  "Return the project root, or `default-directory' if outside any project."
  (if-let* ((project (project-current)))
      (expand-file-name (project-root project))
    (expand-file-name default-directory)))

(defun agent-term--live-session-p (session)
  "Return non-nil if SESSION's buffer is alive."
  (and session (buffer-live-p (agent-term--session-buffer session))))

(defun agent-term--session-for-directory (directory)
  "Return the live session for DIRECTORY, or nil."
  (let ((session (gethash directory agent-term--sessions)))
    (when (agent-term--live-session-p session) session)))

(defun agent-term--current-session ()
  "Return the session of the current buffer or of the current project."
  (or (and (agent-term--live-session-p agent-term--buffer-session)
           agent-term--buffer-session)
      (agent-term--session-for-directory (agent-term--get-working-directory))))

(defun agent-term--require-session ()
  "Return the current session or signal a `user-error'."
  (or (agent-term--current-session)
      (user-error "No agent session for this project.  Use M-x agent-term to start one")))

(defun agent-term--live-sessions ()
  "Return all live sessions."
  (let (sessions)
    (maphash (lambda (_dir session)
               (when (agent-term--live-session-p session)
                 (push session sessions)))
             agent-term--sessions)
    (nreverse sessions)))

(defun agent-term--session-label (session)
  "Return a short description of SESSION for messages."
  (format "%s in %s" (agent-term--agent-name (agent-term--session-agent session))
          (file-name-nondirectory
           (directory-file-name (agent-term--session-directory session)))))

;;; Active Buffer Tracking
;;
;; When the agent calls an MCP tool, the tools need to know which file
;; buffer the user last worked in.  A cheap `post-command-hook' records
;; it whenever the current buffer changes.

(defvar agent-term--last-tracked-buffer nil
  "The buffer seen by the last run of `agent-term--track-active-buffer'.")

(defun agent-term--track-active-buffer ()
  "Record the current file buffer as last active for its session."
  (unless (eq (current-buffer) agent-term--last-tracked-buffer)
    (setq agent-term--last-tracked-buffer (current-buffer))
    (when-let* ((file buffer-file-name)
                (file (expand-file-name file))
                (session (cl-find-if
                          (lambda (s)
                            (string-prefix-p (agent-term--session-directory s) file))
                          (sort (agent-term--live-sessions)
                                (lambda (a b)
                                  (> (length (agent-term--session-directory a))
                                     (length (agent-term--session-directory b))))))))
      (agent-term-mcp-server-update-last-active-buffer
       (agent-term--session-id session) (current-buffer)))))

;;; Window Display

(defun agent-term--display-buffer (buffer)
  "Display BUFFER according to the window options and return the window."
  (let ((window
         (if agent-term-use-side-window
             (let ((side agent-term-window-side))
               (display-buffer
                buffer
                `((display-buffer-in-side-window)
                  (side . ,side)
                  (slot . 0)
                  ,@(if (memq side '(left right))
                        `((window-width . ,agent-term-window-width))
                      `((window-height . ,agent-term-window-height)))
                  (dedicated . t)
                  (window-parameters . ((no-delete-other-windows . t))))))
           (pop-to-buffer-same-window buffer)
           (get-buffer-window buffer))))
    (setq agent-term--last-accessed-buffer buffer)
    (when (and window agent-term-focus-on-open)
      (select-window window))
    window))

(defun agent-term--hide-buffer (buffer)
  "Hide every window that shows BUFFER in the selected frame."
  (setq agent-term--last-accessed-buffer buffer)
  (dolist (window (get-buffer-window-list buffer nil))
    ;; `quit-restore-window' deletes a window that was made for BUFFER
    ;; (side windows, popups) and shows the previous buffer otherwise.
    (quit-restore-window window 'bury)))

(defun agent-term--toggle-buffer (buffer)
  "Hide BUFFER if it is visible, otherwise display it."
  (if (get-buffer-window buffer)
      (agent-term--hide-buffer buffer)
    (agent-term--display-buffer buffer)))

;;; Command Building

(defun agent-term--tool-flag-args (flag tools)
  "Return the argument list that passes TOOLS with FLAG, or nil."
  (when (and flag tools)
    (list (concat flag "=" (mapconcat #'identity tools ",")))))

(defun agent-term--build-args (agent session-id &optional continue resume)
  "Return the argument list for AGENT.
SESSION-ID selects the MCP endpoint.  CONTINUE adds --continue.
RESUME adds --resume, followed by RESUME itself when it is a string."
  (let ((get (lambda (prop) (agent-term--agent-get prop agent)))
        (args '()))
    (when continue (push "--continue" args))
    (when resume
      (push "--resume" args)
      (when (stringp resume) (push resume args)))
    (setq args (nreverse args))
    (when (and agent-term-cli-extra-flags
               (not (string-empty-p agent-term-cli-extra-flags)))
      (setq args (append args (split-string-shell-command agent-term-cli-extra-flags))))
    (when (and agent-term-mcp-available-tools
               (not (funcall get :available-tools-flag)))
      (display-warning 'agent-term
                       (format "`agent-term-mcp-available-tools' is not supported by %s; ignored"
                               (funcall get :name))))
    (let ((deny-flag (funcall get :deny-tools-flag))
          (excluded-flag (funcall get :excluded-tools-flag)))
      (setq args
            (append args
                    (agent-term--tool-flag-args (funcall get :available-tools-flag)
                                                 agent-term-mcp-available-tools)
                    (agent-term--tool-flag-args (funcall get :allow-tools-flag)
                                                 agent-term-mcp-allow-tools)
                    ;; Claude uses one flag for excluded and denied tools.
                    (if (equal deny-flag excluded-flag)
                        (agent-term--tool-flag-args
                         deny-flag (append agent-term-mcp-excluded-tools
                                           agent-term-mcp-deny-tools))
                      (append (agent-term--tool-flag-args excluded-flag
                                                           agent-term-mcp-excluded-tools)
                              (agent-term--tool-flag-args deny-flag
                                                           agent-term-mcp-deny-tools))))))
    (when (agent-term-mcp-server-ensure-server)
      (when-let* ((config (agent-term-mcp-server-get-config session-id)))
        (setq args (append args (list (concat (funcall get :mcp-config-flag) "="
                                              (json-encode config)))))))
    args))

;;; Keybindings

(defun agent-term--forward-c-underscore ()
  "Send C-_ to the terminal in its input modes, else run the global binding.
Global minor modes that bind C-_ (e.g. undo packages) would otherwise
shadow ghostel's own forwarding, because `minor-mode-map-alist' takes
precedence over ghostel's local keymap."
  (interactive)
  (if (memq ghostel--input-mode '(semi-char char))
      (ghostel-send-string (string ?\C-_))
    (when-let* ((binding (global-key-binding (kbd "C-_"))))
      (call-interactively binding))))

(defun agent-term--setup-keybindings ()
  "Install the session key overrides in the current buffer.
ghostel replaces the local keymap whenever the input mode changes, and
that keymap is shared by all ghostel buffers, so the overrides live in
a buffer-local `minor-mode-overriding-map-alist' entry instead."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "S-<return>") #'agent-term-insert-newline)
    (define-key map (kbd "C-<escape>") #'agent-term-send-escape)
    (define-key map (kbd "C-_") #'agent-term--forward-c-underscore)
    (dolist (key agent-term-emacs-keybindings)
      (when-let* ((binding (global-key-binding (kbd key))))
        (define-key map (kbd key) binding)))
    (setq-local agent-term--keybinding-override t)
    (setq-local minor-mode-overriding-map-alist
                (cons (cons 'agent-term--keybinding-override map)
                      (assq-delete-all 'agent-term--keybinding-override
                                       (copy-sequence minor-mode-overriding-map-alist))))))

;;; Session Start/Stop

(defun agent-term--unique-buffer-name (name)
  "Return NAME, or a variant of it when a live buffer already uses it."
  (if (get-buffer name) (generate-new-buffer-name name) name))

(defun agent-term--end-session (session)
  "Forget SESSION and release its resources.  Does not kill its buffer."
  (let ((directory (agent-term--session-directory session)))
    (when (eq (gethash directory agent-term--sessions) session)
      (remhash directory agent-term--sessions)
      (agent-term-mcp-server-session-ended (agent-term--session-id session))
      (when (zerop (hash-table-count agent-term--sessions))
        (remove-hook 'post-command-hook #'agent-term--track-active-buffer))
      (agent-term-debug "Session ended: %s" (agent-term--session-label session)))))

(defun agent-term--start-session (&optional continue resume)
  "Start an agent session for the current project, or toggle its window.
CONTINUE and RESUME are passed to `agent-term--build-args'."
  (let* ((directory (agent-term--get-working-directory))
         (existing (agent-term--session-for-directory directory)))
    (if existing
        (progn
          (when (or continue resume)
            (message "A session is already running in %s" (abbreviate-file-name directory)))
          (agent-term--toggle-buffer (agent-term--session-buffer existing)))
      (agent-term--create-session agent-term-agent directory continue resume))))

(defun agent-term--create-session (agent directory &optional continue resume)
  "Start AGENT in DIRECTORY and return the new session.
CONTINUE and RESUME are passed to `agent-term--build-args'."
  (unless (require 'ghostel nil t)
    (user-error "The ghostel package is required"))
  (unless (agent-term--cli-available-p agent)
    (user-error "%s CLI `%s' not found.  Install it or set `agent-term-cli-path'"
                (agent-term--agent-name agent) (agent-term--program agent)))
  (let* ((session-id (agent-term-mcp-server-new-session-id))
         (buffer (get-buffer-create
                  (agent-term--unique-buffer-name
                   (funcall agent-term-buffer-name-function directory agent))))
         (session (agent-term--session-create
                   :agent agent :directory directory :buffer buffer :id session-id))
         (program (agent-term--program agent)))
    (condition-case err
        (let ((args (agent-term--build-args agent session-id continue resume)))
          (agent-term-debug "Starting %s %S in %s" program args directory)
          ;; Register before the agent runs: it connects to the MCP
          ;; server right away.
          (agent-term-mcp-server-session-started session-id directory buffer)
          (puthash directory session agent-term--sessions)
          (with-current-buffer buffer
            (setq default-directory directory))
          ;; Display first, so ghostel sizes the terminal to the window
          ;; and the agent does not get a resize right after starting.
          (agent-term--display-buffer buffer)
          (setf (agent-term--session-process session)
                ;; `ghostel-exec' enables `ghostel-mode', which kills
                ;; local variables, so the environment is bound
                ;; dynamically and the buffer setup follows the call.
                (let ((ghostel-environment (append agent-term-environment
                                                   ghostel-environment)))
                  (ghostel-exec buffer program args)))
          (with-current-buffer buffer
            (setq agent-term--buffer-session session)
            (setq-local ghostel-kill-buffer-on-exit t)
            (add-hook 'ghostel-exit-functions
                      (lambda (&rest _) (agent-term--end-session session))
                      nil t)
            (add-hook 'kill-buffer-hook
                      (lambda () (agent-term--end-session session))
                      nil t)
            (agent-term--setup-keybindings)
            (when (and agent-term-show-modeline
                       (bound-and-true-p hide-mode-line-mode))
              (hide-mode-line-mode -1)))
          (add-hook 'post-command-hook #'agent-term--track-active-buffer)
          (agent-term-log "%s started%s" (agent-term--session-label session)
                           (if-let* ((port (agent-term-mcp-server-get-port)))
                               (format " with MCP tools on port %d" port)
                             ""))
          session)
      (error
       (agent-term--end-session session)
       (when (buffer-live-p buffer)
         (let ((kill-buffer-query-functions nil))
           (kill-buffer buffer)))
       (signal (car err) (cdr err))))))

(defun agent-term--cleanup-all-sessions ()
  "Stop all sessions (run from `kill-emacs-hook')."
  (dolist (session (agent-term--live-sessions))
    (agent-term--end-session session)))

(add-hook 'kill-emacs-hook #'agent-term--cleanup-all-sessions)

;;; Interactive Commands

;;;###autoload
(defun agent-term ()
  "Start the agent for the current project, or toggle its window.
The agent is `agent-term-agent'."
  (interactive)
  (agent-term--start-session))

;;;###autoload
(defun agent-term-start-agent (agent)
  "Start AGENT for the current project, regardless of `agent-term-agent'.
Interactively, read AGENT from the minibuffer."
  (interactive
   (list (intern (completing-read "Agent: "
                                  (mapcar (lambda (a) (symbol-name (car a)))
                                          agent-term-agents)
                                  nil t))))
  (let ((agent-term-agent agent))
    (agent-term--start-session)))

;;;###autoload
(defun agent-term-continue ()
  "Start the agent with --continue to resume the project's last conversation."
  (interactive)
  (agent-term--start-session t nil))

;;;###autoload
(defun agent-term-resume (&optional session-id)
  "Start the agent with --resume, optionally for SESSION-ID.
With a prefix argument, prompt for the session ID.  Without one,
the agent shows its session picker."
  (interactive
   (list (when current-prefix-arg
           (read-string "Session ID (leave empty for picker): "))))
  (agent-term--start-session nil (if (and session-id (not (string-empty-p session-id)))
                                      session-id
                                    t)))

;;;###autoload
(defun agent-term-stop ()
  "Stop the agent session for the current buffer or project."
  (interactive)
  (if-let* ((session (agent-term--current-session)))
      (let ((label (agent-term--session-label session)))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer (agent-term--session-buffer session)))
        (agent-term-log "Stopped %s" label))
    (agent-term-log "No agent session is running for this project")))

;;;###autoload
(defun agent-term-check-status ()
  "Show whether the agent CLI is installed, and its version."
  (interactive)
  (let ((program (agent-term--program)))
    (if (agent-term--cli-available-p)
        (agent-term-log "%s CLI version: %s" (agent-term--agent-name)
                         (with-temp-buffer
                           (call-process program nil t nil "--version")
                           (string-trim (buffer-string))))
      (agent-term-log "%s CLI `%s' is not installed or not in PATH"
                       (agent-term--agent-name) program))))

;;;###autoload
(defun agent-term-switch-to-buffer ()
  "Select the session window for the current project, displaying it if needed."
  (interactive)
  (let ((buffer (agent-term--session-buffer (agent-term--require-session))))
    (if-let* ((window (get-buffer-window buffer)))
        (select-window window)
      (let ((agent-term-focus-on-open t))
        (agent-term--display-buffer buffer)))))

;;;###autoload
(defun agent-term-list-sessions ()
  "Pick one of the running sessions and display it."
  (interactive)
  (let ((sessions (mapcar (lambda (s)
                            (cons (format "%s  (%s)"
                                          (abbreviate-file-name
                                           (agent-term--session-directory s))
                                          (agent-term--agent-name
                                           (agent-term--session-agent s)))
                                  s))
                          (agent-term--live-sessions))))
    (if (null sessions)
        (agent-term-log "No active agent sessions")
      (let ((choice (completing-read "Switch to session: " sessions nil t)))
        (agent-term--display-buffer
         (agent-term--session-buffer (cdr (assoc choice sessions))))))))

(defun agent-term--send (function &rest args)
  "Call FUNCTION with ARGS in the buffer of the current session."
  (with-current-buffer (agent-term--session-buffer (agent-term--require-session))
    (apply function args)))

;;;###autoload
(defun agent-term-send-escape ()
  "Send the escape key to the agent of the current buffer or project."
  (interactive)
  (agent-term--send #'ghostel-send-string "\e"))

;;;###autoload
(defun agent-term-insert-newline ()
  "Insert a newline into the agent prompt (backslash + return)."
  (interactive)
  (agent-term--send
   (lambda ()
     (ghostel-send-string "\\")
     (sit-for 0.1)
     (ghostel-send-string "\r"))))

;;;###autoload
(defun agent-term-send-prompt (&optional prompt)
  "Send PROMPT (or one read from the minibuffer) to the agent and submit it.
The text is sent as a bracketed paste, so line breaks stay in the
prompt instead of submitting it early."
  (interactive)
  (let ((session (agent-term--require-session)))
    (let ((text (or prompt (read-string (format "%s prompt: "
                                                (agent-term--agent-name
                                                 (agent-term--session-agent session)))))))
      (unless (string-empty-p text)
        (with-current-buffer (agent-term--session-buffer session)
          (ghostel-paste-string text)
          (sit-for 0.1)
          (ghostel-send-string "\r"))))))

;;;###autoload
(defun agent-term-toggle ()
  "Toggle the session window of the current project."
  (interactive)
  (agent-term--toggle-buffer (agent-term--session-buffer (agent-term--require-session))))

;;;###autoload
(defun agent-term-toggle-recent ()
  "Hide all visible session windows, or show the most recent session again."
  (interactive)
  (let ((visible (cl-remove-if-not
                  (lambda (s) (get-buffer-window (agent-term--session-buffer s)))
                  (agent-term--live-sessions))))
    (cond
     (visible
      (dolist (session visible)
        (agent-term--hide-buffer (agent-term--session-buffer session)))
      (message "Closed all agent windows"))
     ((and agent-term--last-accessed-buffer
           (buffer-live-p agent-term--last-accessed-buffer))
      (agent-term--display-buffer agent-term--last-accessed-buffer))
     (t
      (user-error "No recent agent session to toggle")))))

(provide 'agent-term)

;;; agent-term.el ends here
