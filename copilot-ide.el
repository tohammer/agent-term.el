;;; copilot-ide.el --- Run Copilot CLI or Claude Code in Emacs  -*- lexical-binding: t; -*-

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
;; URL: https://github.com/tohammer/copilot-ide.el

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
;;   M-x copilot-ide          Start (or toggle) the session for the project
;;   M-x copilot-ide-stop     Stop the session
;;   M-x copilot-ide-menu     Open the transient menu
;;
;; Choose the agent with `copilot-ide-agent'.  To enable the Emacs MCP
;; tools (xref, imenu, treesit, project info, diagnostics):
;;   (copilot-ide-emacs-tools-setup)

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'subr-x)
(require 'copilot-ide-debug)
(require 'copilot-ide-transient)
(require 'copilot-ide-mcp-server)
(require 'copilot-ide-diagnostics)
(require 'copilot-ide-emacs-tools)

(defvar ghostel-environment)
(defvar ghostel-exit-functions)
(defvar ghostel-kill-buffer-on-exit)
(defvar ghostel--input-mode)
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function ghostel-send-string "ghostel" (string))
(declare-function ghostel-paste-string "ghostel" (string))
(declare-function hide-mode-line-mode "hide-mode-line" (&optional arg))

;;; Customization

(defgroup copilot-ide nil
  "Run AI coding agent CLIs (Copilot, Claude) in Emacs."
  :group 'tools
  :prefix "copilot-ide-")

(defconst copilot-ide-agents
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
  :available-tools-flag  Flag for `copilot-ide-mcp-available-tools', or nil.
  :excluded-tools-flag   Flag for `copilot-ide-mcp-excluded-tools'.
  :allow-tools-flag      Flag for `copilot-ide-mcp-allow-tools'.
  :deny-tools-flag       Flag for `copilot-ide-mcp-deny-tools'.")

(defcustom copilot-ide-agent 'copilot
  "The agent CLI that new sessions run.
`copilot' runs the GitHub Copilot CLI, `claude' runs Claude Code."
  :type '(choice (const :tag "GitHub Copilot CLI" copilot)
                 (const :tag "Claude Code" claude))
  :group 'copilot-ide)

(defcustom copilot-ide-cli-path nil
  "Path to the agent executable.
When nil, the agent's default program (\"copilot\" or \"claude\") is
looked up on the variable `exec-path'."
  :type '(choice (const :tag "Agent default" nil) string)
  :group 'copilot-ide)

(defcustom copilot-ide-cli-extra-flags ""
  "Additional flags passed to the agent, as a shell-like string.
The string is split with `split-string-shell-command', so quoting works
as in a shell, but nothing is expanded."
  :type 'string
  :group 'copilot-ide)

(defcustom copilot-ide-environment nil
  "Extra environment variables for the agent process.
A list of \"NAME=VALUE\" strings; they take precedence over the
variables ghostel sets."
  :type '(repeat string)
  :group 'copilot-ide)

(defcustom copilot-ide-buffer-name-function #'copilot-ide--default-buffer-name
  "Function that returns the buffer name for a session.
Called with two arguments: the project directory and the agent symbol.
When another buffer already has that name, a unique name is derived
from it."
  :type 'function
  :group 'copilot-ide)

(defcustom copilot-ide-window-side 'right
  "Side of the frame where the session window appears."
  :type '(choice (const left) (const right) (const top) (const bottom))
  :group 'copilot-ide)

(defcustom copilot-ide-window-width 100
  "Width of the session side window (columns), for left/right placement."
  :type 'integer
  :group 'copilot-ide)

(defcustom copilot-ide-window-height 20
  "Height of the session side window (lines), for top/bottom placement."
  :type 'integer
  :group 'copilot-ide)

(defcustom copilot-ide-focus-on-open t
  "When non-nil, select the session window when it is displayed."
  :type 'boolean
  :group 'copilot-ide)

(defcustom copilot-ide-use-side-window t
  "When non-nil, display sessions in a dedicated side window.
When nil, display them with `pop-to-buffer-same-window', which
honors `display-buffer-alist' (and thus popup rules)."
  :type 'boolean
  :group 'copilot-ide)

(defcustom copilot-ide-show-modeline t
  "When non-nil, ensure the mode line is visible in the session buffer.
Some configurations (e.g. Doom Emacs) hide the mode line in terminal
buffers; this option turns `hide-mode-line-mode' off again."
  :type 'boolean
  :group 'copilot-ide)

(defcustom copilot-ide-emacs-keybindings '()
  "Keys handled by their global Emacs binding instead of the terminal.
Each entry is a key string accepted by `kbd'.  The global binding at
the time the session starts is used."
  :type '(repeat string)
  :group 'copilot-ide)

(defcustom copilot-ide-mcp-available-tools nil
  "Tools the agent may use at all (an allow list for the model).
Entries use the agent's own syntax.  Copilot only (`--available-tools'):
\"ServerName\" or \"ServerName(tool_name)\".  Claude Code has no
equivalent; the option is ignored with a warning there."
  :type '(repeat string)
  :group 'copilot-ide)

(defcustom copilot-ide-mcp-excluded-tools nil
  "Tools the agent may not use at all.
Entries use the agent's own syntax.  Copilot (`--excluded-tools'):
\"ServerName\" or \"ServerName(tool_name)\".  Claude
\(`--disallowedTools'): e.g. \"mcp__server\" or \"mcp__server__tool\"."
  :type '(repeat string)
  :group 'copilot-ide)

(defcustom copilot-ide-mcp-allow-tools nil
  "Tools the agent may run without asking for permission.
Entries use the agent's own syntax.  Copilot (`--allow-tool'):
\"ServerName\", \"ServerName(tool_name)\" or e.g. \"shell(git)\".
Claude (`--allowedTools'): e.g. \"mcp__emacs-tools\",
\"mcp__emacs-tools__imenu_list_symbols\" or \"Bash(git log:*)\"."
  :type '(repeat string)
  :group 'copilot-ide)

(defcustom copilot-ide-mcp-deny-tools nil
  "Tools the agent must never run.
Entries use the agent's own syntax.  Copilot (`--deny-tool', takes
precedence over `--allow-tool').  Claude (`--disallowedTools')."
  :type '(repeat string)
  :group 'copilot-ide)

;;; State

(cl-defstruct (copilot-ide--session (:constructor copilot-ide--session-create)
                                    (:copier nil))
  "A running agent session."
  agent directory buffer process id)

(defvar copilot-ide--sessions (make-hash-table :test 'equal)
  "Hash table mapping project directories to `copilot-ide--session's.")

(defvar copilot-ide--last-accessed-buffer nil
  "Most recently displayed session buffer.")

(defvar-local copilot-ide--buffer-session nil
  "The session shown in this buffer, or nil.")

(defvar-local copilot-ide--keybinding-override nil
  "Non-nil enables the session key overrides in this buffer.
Used as the key of an entry in `minor-mode-overriding-map-alist'.")

;;; Agents

(defun copilot-ide--agent-get (property &optional agent)
  "Return PROPERTY of AGENT (default `copilot-ide-agent')."
  (let ((agent (or agent copilot-ide-agent)))
    (plist-get (or (alist-get agent copilot-ide-agents)
                   (user-error "Unknown agent: %s" agent))
               property)))

(defun copilot-ide--agent-name (&optional agent)
  "Return the display name of AGENT (default `copilot-ide-agent')."
  (copilot-ide--agent-get :name agent))

(defun copilot-ide--program (&optional agent)
  "Return the executable for AGENT (default `copilot-ide-agent')."
  (or copilot-ide-cli-path (copilot-ide--agent-get :program agent)))

(defun copilot-ide--cli-available-p (&optional agent)
  "Return non-nil if the executable for AGENT can be found."
  (let ((program (copilot-ide--program agent)))
    (if (file-name-directory program)
        (file-executable-p (expand-file-name program))
      (executable-find program))))

;;; Sessions

(defun copilot-ide--default-buffer-name (directory agent)
  "Return the default buffer name for AGENT in DIRECTORY."
  (format "*%s[%s]*" (downcase (copilot-ide--agent-name agent))
          (file-name-nondirectory (directory-file-name directory))))

(defun copilot-ide--get-working-directory ()
  "Return the project root, or `default-directory' if outside any project."
  (if-let* ((project (project-current)))
      (expand-file-name (project-root project))
    (expand-file-name default-directory)))

(defun copilot-ide--live-session-p (session)
  "Return non-nil if SESSION's buffer is alive."
  (and session (buffer-live-p (copilot-ide--session-buffer session))))

(defun copilot-ide--session-for-directory (directory)
  "Return the live session for DIRECTORY, or nil."
  (let ((session (gethash directory copilot-ide--sessions)))
    (when (copilot-ide--live-session-p session) session)))

(defun copilot-ide--current-session ()
  "Return the session of the current buffer or of the current project."
  (or (and (copilot-ide--live-session-p copilot-ide--buffer-session)
           copilot-ide--buffer-session)
      (copilot-ide--session-for-directory (copilot-ide--get-working-directory))))

(defun copilot-ide--require-session ()
  "Return the current session or signal a `user-error'."
  (or (copilot-ide--current-session)
      (user-error "No agent session for this project.  Use M-x copilot-ide to start one")))

(defun copilot-ide--live-sessions ()
  "Return all live sessions."
  (let (sessions)
    (maphash (lambda (_dir session)
               (when (copilot-ide--live-session-p session)
                 (push session sessions)))
             copilot-ide--sessions)
    (nreverse sessions)))

(defun copilot-ide--session-label (session)
  "Return a short description of SESSION for messages."
  (format "%s in %s" (copilot-ide--agent-name (copilot-ide--session-agent session))
          (file-name-nondirectory
           (directory-file-name (copilot-ide--session-directory session)))))

;;; Active Buffer Tracking
;;
;; When the agent calls an MCP tool, the tools need to know which file
;; buffer the user last worked in.  A cheap `post-command-hook' records
;; it whenever the current buffer changes.

(defvar copilot-ide--last-tracked-buffer nil
  "The buffer seen by the last run of `copilot-ide--track-active-buffer'.")

(defun copilot-ide--track-active-buffer ()
  "Record the current file buffer as last active for its session."
  (unless (eq (current-buffer) copilot-ide--last-tracked-buffer)
    (setq copilot-ide--last-tracked-buffer (current-buffer))
    (when-let* ((file buffer-file-name)
                (file (expand-file-name file))
                (session (cl-find-if
                          (lambda (s)
                            (string-prefix-p (copilot-ide--session-directory s) file))
                          (sort (copilot-ide--live-sessions)
                                (lambda (a b)
                                  (> (length (copilot-ide--session-directory a))
                                     (length (copilot-ide--session-directory b))))))))
      (copilot-ide-mcp-server-update-last-active-buffer
       (copilot-ide--session-id session) (current-buffer)))))

;;; Window Display

(defun copilot-ide--display-buffer (buffer)
  "Display BUFFER according to the window options and return the window."
  (let ((window
         (if copilot-ide-use-side-window
             (let ((side copilot-ide-window-side))
               (display-buffer
                buffer
                `((display-buffer-in-side-window)
                  (side . ,side)
                  (slot . 0)
                  ,@(if (memq side '(left right))
                        `((window-width . ,copilot-ide-window-width))
                      `((window-height . ,copilot-ide-window-height)))
                  (dedicated . t)
                  (window-parameters . ((no-delete-other-windows . t))))))
           (pop-to-buffer-same-window buffer)
           (get-buffer-window buffer))))
    (setq copilot-ide--last-accessed-buffer buffer)
    (when (and window copilot-ide-focus-on-open)
      (select-window window))
    window))

(defun copilot-ide--hide-buffer (buffer)
  "Hide every window that shows BUFFER in the selected frame."
  (setq copilot-ide--last-accessed-buffer buffer)
  (dolist (window (get-buffer-window-list buffer nil))
    ;; `quit-restore-window' deletes a window that was made for BUFFER
    ;; (side windows, popups) and shows the previous buffer otherwise.
    (quit-restore-window window 'bury)))

(defun copilot-ide--toggle-buffer (buffer)
  "Hide BUFFER if it is visible, otherwise display it."
  (if (get-buffer-window buffer)
      (copilot-ide--hide-buffer buffer)
    (copilot-ide--display-buffer buffer)))

;;; Command Building

(defun copilot-ide--tool-flag-args (flag tools)
  "Return the argument list that passes TOOLS with FLAG, or nil."
  (when (and flag tools)
    (list (concat flag "=" (mapconcat #'identity tools ",")))))

(defun copilot-ide--build-args (agent session-id &optional continue resume)
  "Return the argument list for AGENT.
SESSION-ID selects the MCP endpoint.  CONTINUE adds --continue.
RESUME adds --resume, followed by RESUME itself when it is a string."
  (let ((get (lambda (prop) (copilot-ide--agent-get prop agent)))
        (args '()))
    (when continue (push "--continue" args))
    (when resume
      (push "--resume" args)
      (when (stringp resume) (push resume args)))
    (setq args (nreverse args))
    (when (and copilot-ide-cli-extra-flags
               (not (string-empty-p copilot-ide-cli-extra-flags)))
      (setq args (append args (split-string-shell-command copilot-ide-cli-extra-flags))))
    (when (and copilot-ide-mcp-available-tools
               (not (funcall get :available-tools-flag)))
      (display-warning 'copilot-ide
                       (format "`copilot-ide-mcp-available-tools' is not supported by %s; ignored"
                               (funcall get :name))))
    (let ((deny-flag (funcall get :deny-tools-flag))
          (excluded-flag (funcall get :excluded-tools-flag)))
      (setq args
            (append args
                    (copilot-ide--tool-flag-args (funcall get :available-tools-flag)
                                                 copilot-ide-mcp-available-tools)
                    (copilot-ide--tool-flag-args (funcall get :allow-tools-flag)
                                                 copilot-ide-mcp-allow-tools)
                    ;; Claude uses one flag for excluded and denied tools.
                    (if (equal deny-flag excluded-flag)
                        (copilot-ide--tool-flag-args
                         deny-flag (append copilot-ide-mcp-excluded-tools
                                           copilot-ide-mcp-deny-tools))
                      (append (copilot-ide--tool-flag-args excluded-flag
                                                           copilot-ide-mcp-excluded-tools)
                              (copilot-ide--tool-flag-args deny-flag
                                                           copilot-ide-mcp-deny-tools))))))
    (when (copilot-ide-mcp-server-ensure-server)
      (when-let* ((config (copilot-ide-mcp-server-get-config session-id)))
        (setq args (append args (list (concat (funcall get :mcp-config-flag) "="
                                              (json-encode config)))))))
    args))

;;; Keybindings

(defun copilot-ide--forward-c-underscore ()
  "Send C-_ to the terminal in its input modes, else run the global binding.
Global minor modes that bind C-_ (e.g. undo packages) would otherwise
shadow ghostel's own forwarding, because `minor-mode-map-alist' takes
precedence over ghostel's local keymap."
  (interactive)
  (if (memq ghostel--input-mode '(semi-char char))
      (ghostel-send-string (string ?\C-_))
    (when-let* ((binding (global-key-binding (kbd "C-_"))))
      (call-interactively binding))))

(defun copilot-ide--setup-keybindings ()
  "Install the session key overrides in the current buffer.
ghostel replaces the local keymap whenever the input mode changes, and
that keymap is shared by all ghostel buffers, so the overrides live in
a buffer-local `minor-mode-overriding-map-alist' entry instead."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "S-<return>") #'copilot-ide-insert-newline)
    (define-key map (kbd "C-<escape>") #'copilot-ide-send-escape)
    (define-key map (kbd "C-_") #'copilot-ide--forward-c-underscore)
    (dolist (key copilot-ide-emacs-keybindings)
      (when-let* ((binding (global-key-binding (kbd key))))
        (define-key map (kbd key) binding)))
    (setq-local copilot-ide--keybinding-override t)
    (setq-local minor-mode-overriding-map-alist
                (cons (cons 'copilot-ide--keybinding-override map)
                      (assq-delete-all 'copilot-ide--keybinding-override
                                       (copy-sequence minor-mode-overriding-map-alist))))))

;;; Session Start/Stop

(defun copilot-ide--unique-buffer-name (name)
  "Return NAME, or a variant of it when a live buffer already uses it."
  (if (get-buffer name) (generate-new-buffer-name name) name))

(defun copilot-ide--end-session (session)
  "Forget SESSION and release its resources.  Does not kill its buffer."
  (let ((directory (copilot-ide--session-directory session)))
    (when (eq (gethash directory copilot-ide--sessions) session)
      (remhash directory copilot-ide--sessions)
      (copilot-ide-mcp-server-session-ended (copilot-ide--session-id session))
      (when (zerop (hash-table-count copilot-ide--sessions))
        (remove-hook 'post-command-hook #'copilot-ide--track-active-buffer))
      (copilot-ide-debug "Session ended: %s" (copilot-ide--session-label session)))))

(defun copilot-ide--start-session (&optional continue resume)
  "Start an agent session for the current project, or toggle its window.
CONTINUE and RESUME are passed to `copilot-ide--build-args'."
  (let* ((directory (copilot-ide--get-working-directory))
         (existing (copilot-ide--session-for-directory directory)))
    (if existing
        (progn
          (when (or continue resume)
            (message "A session is already running in %s" (abbreviate-file-name directory)))
          (copilot-ide--toggle-buffer (copilot-ide--session-buffer existing)))
      (copilot-ide--create-session copilot-ide-agent directory continue resume))))

(defun copilot-ide--create-session (agent directory &optional continue resume)
  "Start AGENT in DIRECTORY and return the new session.
CONTINUE and RESUME are passed to `copilot-ide--build-args'."
  (unless (require 'ghostel nil t)
    (user-error "The ghostel package is required"))
  (unless (copilot-ide--cli-available-p agent)
    (user-error "%s CLI `%s' not found.  Install it or set `copilot-ide-cli-path'"
                (copilot-ide--agent-name agent) (copilot-ide--program agent)))
  (let* ((session-id (copilot-ide-mcp-server-new-session-id))
         (buffer (get-buffer-create
                  (copilot-ide--unique-buffer-name
                   (funcall copilot-ide-buffer-name-function directory agent))))
         (session (copilot-ide--session-create
                   :agent agent :directory directory :buffer buffer :id session-id))
         (program (copilot-ide--program agent)))
    (condition-case err
        (let ((args (copilot-ide--build-args agent session-id continue resume)))
          (copilot-ide-debug "Starting %s %S in %s" program args directory)
          ;; Register before the agent runs: it connects to the MCP
          ;; server right away.
          (copilot-ide-mcp-server-session-started session-id directory buffer)
          (puthash directory session copilot-ide--sessions)
          (with-current-buffer buffer
            (setq default-directory directory))
          ;; Display first, so ghostel sizes the terminal to the window
          ;; and the agent does not get a resize right after starting.
          (copilot-ide--display-buffer buffer)
          (setf (copilot-ide--session-process session)
                ;; `ghostel-exec' enables `ghostel-mode', which kills
                ;; local variables, so the environment is bound
                ;; dynamically and the buffer setup follows the call.
                (let ((ghostel-environment (append copilot-ide-environment
                                                   ghostel-environment)))
                  (ghostel-exec buffer program args)))
          (with-current-buffer buffer
            (setq copilot-ide--buffer-session session)
            (setq-local ghostel-kill-buffer-on-exit t)
            (add-hook 'ghostel-exit-functions
                      (lambda (&rest _) (copilot-ide--end-session session))
                      nil t)
            (add-hook 'kill-buffer-hook
                      (lambda () (copilot-ide--end-session session))
                      nil t)
            (copilot-ide--setup-keybindings)
            (when (and copilot-ide-show-modeline
                       (bound-and-true-p hide-mode-line-mode))
              (hide-mode-line-mode -1)))
          (add-hook 'post-command-hook #'copilot-ide--track-active-buffer)
          (copilot-ide-log "%s started%s" (copilot-ide--session-label session)
                           (if-let* ((port (copilot-ide-mcp-server-get-port)))
                               (format " with MCP tools on port %d" port)
                             ""))
          session)
      (error
       (copilot-ide--end-session session)
       (when (buffer-live-p buffer)
         (let ((kill-buffer-query-functions nil))
           (kill-buffer buffer)))
       (signal (car err) (cdr err))))))

(defun copilot-ide--cleanup-all-sessions ()
  "Stop all sessions (run from `kill-emacs-hook')."
  (dolist (session (copilot-ide--live-sessions))
    (copilot-ide--end-session session)))

(add-hook 'kill-emacs-hook #'copilot-ide--cleanup-all-sessions)

;;; Interactive Commands

;;;###autoload
(defun copilot-ide ()
  "Start the agent for the current project, or toggle its window.
The agent is `copilot-ide-agent'."
  (interactive)
  (copilot-ide--start-session))

;;;###autoload
(defun copilot-ide-start-agent (agent)
  "Start AGENT for the current project, regardless of `copilot-ide-agent'.
Interactively, read AGENT from the minibuffer."
  (interactive
   (list (intern (completing-read "Agent: "
                                  (mapcar (lambda (a) (symbol-name (car a)))
                                          copilot-ide-agents)
                                  nil t))))
  (let ((copilot-ide-agent agent))
    (copilot-ide--start-session)))

;;;###autoload
(defun copilot-ide-continue ()
  "Start the agent with --continue to resume the project's last conversation."
  (interactive)
  (copilot-ide--start-session t nil))

;;;###autoload
(defun copilot-ide-resume (&optional session-id)
  "Start the agent with --resume, optionally for SESSION-ID.
With a prefix argument, prompt for the session ID.  Without one,
the agent shows its session picker."
  (interactive
   (list (when current-prefix-arg
           (read-string "Session ID (leave empty for picker): "))))
  (copilot-ide--start-session nil (if (and session-id (not (string-empty-p session-id)))
                                      session-id
                                    t)))

;;;###autoload
(defun copilot-ide-stop ()
  "Stop the agent session for the current buffer or project."
  (interactive)
  (if-let* ((session (copilot-ide--current-session)))
      (let ((label (copilot-ide--session-label session)))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer (copilot-ide--session-buffer session)))
        (copilot-ide-log "Stopped %s" label))
    (copilot-ide-log "No agent session is running for this project")))

;;;###autoload
(defun copilot-ide-check-status ()
  "Show whether the agent CLI is installed, and its version."
  (interactive)
  (let ((program (copilot-ide--program)))
    (if (copilot-ide--cli-available-p)
        (copilot-ide-log "%s CLI version: %s" (copilot-ide--agent-name)
                         (with-temp-buffer
                           (call-process program nil t nil "--version")
                           (string-trim (buffer-string))))
      (copilot-ide-log "%s CLI `%s' is not installed or not in PATH"
                       (copilot-ide--agent-name) program))))

;;;###autoload
(defun copilot-ide-switch-to-buffer ()
  "Select the session window for the current project, displaying it if needed."
  (interactive)
  (let ((buffer (copilot-ide--session-buffer (copilot-ide--require-session))))
    (if-let* ((window (get-buffer-window buffer)))
        (select-window window)
      (let ((copilot-ide-focus-on-open t))
        (copilot-ide--display-buffer buffer)))))

;;;###autoload
(defun copilot-ide-list-sessions ()
  "Pick one of the running sessions and display it."
  (interactive)
  (let ((sessions (mapcar (lambda (s)
                            (cons (format "%s  (%s)"
                                          (abbreviate-file-name
                                           (copilot-ide--session-directory s))
                                          (copilot-ide--agent-name
                                           (copilot-ide--session-agent s)))
                                  s))
                          (copilot-ide--live-sessions))))
    (if (null sessions)
        (copilot-ide-log "No active agent sessions")
      (let ((choice (completing-read "Switch to session: " sessions nil t)))
        (copilot-ide--display-buffer
         (copilot-ide--session-buffer (cdr (assoc choice sessions))))))))

(defun copilot-ide--send (function &rest args)
  "Call FUNCTION with ARGS in the buffer of the current session."
  (with-current-buffer (copilot-ide--session-buffer (copilot-ide--require-session))
    (apply function args)))

;;;###autoload
(defun copilot-ide-send-escape ()
  "Send the escape key to the agent of the current buffer or project."
  (interactive)
  (copilot-ide--send #'ghostel-send-string "\e"))

;;;###autoload
(defun copilot-ide-insert-newline ()
  "Insert a newline into the agent prompt (backslash + return)."
  (interactive)
  (copilot-ide--send
   (lambda ()
     (ghostel-send-string "\\")
     (sit-for 0.1)
     (ghostel-send-string "\r"))))

;;;###autoload
(defun copilot-ide-send-prompt (&optional prompt)
  "Send PROMPT (or one read from the minibuffer) to the agent and submit it.
The text is sent as a bracketed paste, so line breaks stay in the
prompt instead of submitting it early."
  (interactive)
  (let ((session (copilot-ide--require-session)))
    (let ((text (or prompt (read-string (format "%s prompt: "
                                                (copilot-ide--agent-name
                                                 (copilot-ide--session-agent session)))))))
      (unless (string-empty-p text)
        (with-current-buffer (copilot-ide--session-buffer session)
          (ghostel-paste-string text)
          (sit-for 0.1)
          (ghostel-send-string "\r"))))))

;;;###autoload
(defun copilot-ide-toggle ()
  "Toggle the session window of the current project."
  (interactive)
  (copilot-ide--toggle-buffer (copilot-ide--session-buffer (copilot-ide--require-session))))

;;;###autoload
(defun copilot-ide-toggle-recent ()
  "Hide all visible session windows, or show the most recent session again."
  (interactive)
  (let ((visible (cl-remove-if-not
                  (lambda (s) (get-buffer-window (copilot-ide--session-buffer s)))
                  (copilot-ide--live-sessions))))
    (cond
     (visible
      (dolist (session visible)
        (copilot-ide--hide-buffer (copilot-ide--session-buffer session)))
      (message "Closed all agent windows"))
     ((and copilot-ide--last-accessed-buffer
           (buffer-live-p copilot-ide--last-accessed-buffer))
      (copilot-ide--display-buffer copilot-ide--last-accessed-buffer))
     (t
      (user-error "No recent agent session to toggle")))))

(provide 'copilot-ide)

;;; copilot-ide.el ends here
