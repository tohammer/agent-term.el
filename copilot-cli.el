;;; copilot-cli.el --- GitHub Copilot CLI integration for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.9.0") (web-server "0.1.2"))
;; Keywords: ai, copilot, mcp, assistant
;; URL: https://github.com/manzaltu/copilot-cli.el

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

;; Emacs integration for the GitHub Copilot CLI.
;;
;; Runs `copilot' in a terminal buffer (vterm or eat) inside a side window
;; and optionally connects an HTTP MCP server so Copilot can call Emacs
;; functions such as xref, imenu, and tree-sitter.
;;
;; Basic usage:
;;   M-x copilot-cli          Start a session for the current project
;;   M-x copilot-cli-stop     Stop the current session
;;   M-x copilot-cli-menu     Open the transient menu
;;
;; To enable Emacs MCP tools (xref, imenu, treesit, project info):
;;   (copilot-cli-emacs-tools-setup)
;;
;; The MCP server is exposed to Copilot via `--mcp-config' at startup.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'copilot-cli-debug)
(require 'copilot-cli-transient)
(require 'copilot-cli-mcp-server)
(require 'copilot-cli-diagnostics)
(require 'copilot-cli-emacs-tools)

;; External variable declarations
(defvar eat-terminal)
(defvar eat--synchronize-scroll-function)
(defvar vterm-shell)
(defvar vterm-environment)
(defvar eat-term-name)
(defvar vterm--process)

;; External function declarations for vterm
(declare-function vterm "vterm" (&optional arg))
(declare-function vterm-send-string "vterm" (string))
(declare-function vterm-send-escape "vterm" ())
(declare-function vterm-send-return "vterm" ())
(declare-function vterm--window-adjust-process-window-size "vterm" (&optional frame))

;; External function declarations for eat
(declare-function eat-mode "eat" ())
(declare-function eat-exec "eat" (buffer name command startfile &rest switches))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function eat-term-display-cursor "eat" (terminal))
(declare-function eat--adjust-process-window-size "eat" (process windows))

;;; Customization

(defgroup copilot-cli nil
  "GitHub Copilot CLI integration for Emacs."
  :group 'tools
  :prefix "copilot-cli-")

(defcustom copilot-cli-cli-path "copilot"
  "Path to the GitHub Copilot CLI executable."
  :type 'string
  :group 'copilot-cli)

(defcustom copilot-cli-buffer-name-function #'copilot-cli--default-buffer-name
  "Function to generate buffer names for Copilot sessions.
Called with one argument (the working directory string)."
  :type 'function
  :group 'copilot-cli)

(defcustom copilot-cli-cli-extra-flags ""
  "Additional flags to pass to the Copilot CLI (space-separated string)."
  :type 'string
  :group 'copilot-cli)

(defcustom copilot-cli-window-side 'right
  "Side of the frame where the Copilot window appears."
  :type '(choice (const left) (const right) (const top) (const bottom))
  :group 'copilot-cli)

(defcustom copilot-cli-window-width 100
  "Width of the Copilot side window (columns), for left/right placement."
  :type 'integer
  :group 'copilot-cli)

(defcustom copilot-cli-window-height 20
  "Height of the Copilot side window (lines), for top/bottom placement."
  :type 'integer
  :group 'copilot-cli)

(defcustom copilot-cli-focus-on-open t
  "When non-nil, focus the Copilot window when it is opened."
  :type 'boolean
  :group 'copilot-cli)

(defcustom copilot-cli-use-side-window t
  "When non-nil, display Copilot in a dedicated side window.
When nil, use a regular buffer display."
  :type 'boolean
  :group 'copilot-cli)

(defcustom copilot-cli-terminal-backend 'vterm
  "Terminal backend to use for running Copilot CLI.
Either `vterm' or `eat'."
  :type '(choice (const :tag "vterm" vterm)
                 (const :tag "eat" eat))
  :group 'copilot-cli)

(defcustom copilot-cli-terminal-initialization-delay 0.1
  "Seconds to wait after creating the terminal before displaying it."
  :type 'number
  :group 'copilot-cli)

(defcustom copilot-cli-eat-preserve-position t
  "When non-nil, preserve the terminal cursor position in eat buffers."
  :type 'boolean
  :group 'copilot-cli)

;;; State

(defvar copilot-cli--cli-available nil
  "Non-nil when the Copilot CLI executable has been detected.")

(defvar copilot-cli--processes (make-hash-table :test 'equal)
  "Hash table mapping project directories to Copilot process objects.")

(defvar copilot-cli--session-ids (make-hash-table :test 'equal)
  "Hash table mapping project directories to MCP session IDs.")

(defvar copilot-cli--last-accessed-buffer nil
  "Most recently displayed Copilot terminal buffer.")

;;; Terminal Backend: vterm helpers

(defvar-local copilot-cli--saved-cursor-type nil
  "Saved cursor-type when entering vterm copy mode.")

(defun copilot-cli--vterm-copy-mode-hook ()
  "Preserve cursor visibility when entering/leaving vterm copy mode."
  (if vterm-copy-mode
      (progn
        (setq copilot-cli--saved-cursor-type cursor-type)
        (when (null cursor-type) (setq cursor-type t)))
    (setq cursor-type copilot-cli--saved-cursor-type)))

(defun copilot-cli--configure-vterm-buffer ()
  "Configure vterm buffer settings for a Copilot session."
  (setq-local vterm-scroll-to-bottom-on-output nil)
  (when (boundp 'vterm--redraw-immididately)
    (setq-local vterm--redraw-immididately nil))
  (setq-local cursor-in-non-selected-windows nil)
  (setq-local blink-cursor-mode nil)
  (setq-local cursor-type nil)
  (setq-local global-hl-line-mode nil)
  (when (featurep 'hl-line) (hl-line-mode -1))
  (face-remap-add-relative 'nobreak-space :inherit 'default)
  (add-hook 'vterm-copy-mode-hook #'copilot-cli--vterm-copy-mode-hook nil t)
  (when-let* ((proc (get-buffer-process (current-buffer))))
    (set-process-query-on-exit-flag proc nil)))

;;; Terminal Backend Abstraction

(defun copilot-cli--terminal-ensure-backend ()
  "Signal an error if the configured terminal backend is not available."
  (cond
   ((eq copilot-cli-terminal-backend 'vterm)
    (unless (featurep 'vterm) (require 'vterm nil t))
    (unless (featurep 'vterm)
      (user-error "vterm is not installed.  Install it or set `copilot-cli-terminal-backend' to 'eat")))
   ((eq copilot-cli-terminal-backend 'eat)
    (unless (featurep 'eat) (require 'eat nil t))
    (unless (featurep 'eat)
      (user-error "eat is not installed.  Install it or set `copilot-cli-terminal-backend' to 'vterm")))
   (t
    (user-error "Invalid terminal backend: %s.  Use 'vterm or 'eat" copilot-cli-terminal-backend))))

(defun copilot-cli--terminal-send-string (string)
  "Send STRING to the terminal in the current buffer."
  (cond
   ((eq copilot-cli-terminal-backend 'vterm) (vterm-send-string string))
   ((eq copilot-cli-terminal-backend 'eat)
    (when eat-terminal (eat-term-send-string eat-terminal string)))
   (t (error "Unknown terminal backend: %s" copilot-cli-terminal-backend))))

(defun copilot-cli--terminal-send-escape ()
  "Send the escape key to the terminal in the current buffer."
  (cond
   ((eq copilot-cli-terminal-backend 'vterm) (vterm-send-escape))
   ((eq copilot-cli-terminal-backend 'eat)
    (when eat-terminal (eat-term-send-string eat-terminal "\e")))
   (t (error "Unknown terminal backend: %s" copilot-cli-terminal-backend))))

(defun copilot-cli--terminal-send-return ()
  "Send return to the terminal in the current buffer."
  (cond
   ((eq copilot-cli-terminal-backend 'vterm) (vterm-send-return))
   ((eq copilot-cli-terminal-backend 'eat)
    (when eat-terminal (eat-term-send-string eat-terminal "\r")))
   (t (error "Unknown terminal backend: %s" copilot-cli-terminal-backend))))

(defun copilot-cli--sync-terminal-dimensions (buffer window)
  "Sync the terminal process dimensions in BUFFER to match WINDOW."
  (when (and buffer window (buffer-live-p buffer) (window-live-p window))
    (with-current-buffer buffer
      (when-let* ((proc (get-buffer-process buffer)))
        (set-process-window-size proc
                                 (window-body-height window)
                                 (window-body-width window))))))

(defun copilot-cli--setup-terminal-keybindings ()
  "Bind Copilot-specific keys in the current terminal buffer."
  (local-set-key (kbd "S-<return>") #'copilot-cli-insert-newline)
  (local-set-key (kbd "C-<escape>") #'copilot-cli-send-escape))

;;; Reflow Glitch Prevention
;;
;; Suppresses spurious terminal reflows caused by height-only resize events,
;; which can trigger unwanted scrolling in terminal AI applications.

(defun copilot-cli--terminal-resize-handler ()
  "Return the terminal resize function for the active backend."
  (pcase copilot-cli-terminal-backend
    ('vterm #'vterm--window-adjust-process-window-size)
    ('eat #'eat--adjust-process-window-size)
    (_ (error "Unsupported terminal backend: %s" copilot-cli-terminal-backend))))

(defun copilot-cli--terminal-scroll-mode-active-p ()
  "Return non-nil when the terminal is in scroll/copy mode."
  (pcase copilot-cli-terminal-backend
    ('vterm (bound-and-true-p vterm-copy-mode))
    ('eat (not (bound-and-true-p eat--semi-char-mode)))
    (_ nil)))

(defun copilot-cli--session-buffer-p (buffer)
  "Return non-nil if BUFFER belongs to a Copilot session."
  (when-let* ((name (if (stringp buffer) buffer (buffer-name buffer))))
    (string-prefix-p "*copilot-cli[" name)))

(defun copilot-cli--terminal-reflow-filter (original-fn &rest args)
  "Wrap ORIGINAL-FN to suppress height-only terminal reflows."
  (let* ((base-result (apply original-fn args))
         (dimensions-stable t))
    (dolist (win (window-list))
      (when-let* ((buf (window-buffer win))
                  ((copilot-cli--session-buffer-p buf)))
        (let* ((new-width (window-width win))
               (cached-width (window-parameter win 'copilot-cli-cached-width)))
          (unless (eql new-width cached-width)
            (setq dimensions-stable nil)
            (set-window-parameter win 'copilot-cli-cached-width new-width)))))
    (cond
     ((not (copilot-cli--session-buffer-p (current-buffer))) base-result)
     ((copilot-cli--terminal-scroll-mode-active-p) nil)
     ((not dimensions-stable) base-result)
     (t nil))))

;;; eat position keeper

(defun copilot-cli--terminal-position-keeper (window-list)
  "Maintain stable eat terminal position across window switches."
  (dolist (win window-list)
    (if (eq win 'buffer)
        (goto-char (eat-term-display-cursor eat-terminal))
      (unless buffer-read-only
        (let ((terminal-point (eat-term-display-cursor eat-terminal)))
          (set-window-point win terminal-point)
          (cond
           ((>= terminal-point (- (point-max) 2))
            (with-selected-window win
              (goto-char terminal-point)
              (recenter -1)))
           ((not (pos-visible-in-window-p terminal-point win))
            (with-selected-window win
              (goto-char terminal-point)
              (recenter)))))))))

;;; Session Helpers

(defun copilot-cli--default-buffer-name (directory)
  "Return the default buffer name for a session in DIRECTORY."
  (format "*copilot-cli[%s]*"
          (file-name-nondirectory (directory-file-name directory))))

(defun copilot-cli--get-working-directory ()
  "Return the project root, or `default-directory' if outside any project."
  (if-let* ((project (project-current)))
      (expand-file-name (project-root project))
    (expand-file-name default-directory)))

(defun copilot-cli--get-buffer-name (&optional directory)
  "Return the buffer name for the session in DIRECTORY (or current project)."
  (funcall copilot-cli-buffer-name-function
           (or directory (copilot-cli--get-working-directory))))

(defun copilot-cli--get-process (&optional directory)
  "Return the Copilot process for DIRECTORY (or current project), or nil."
  (gethash (or directory (copilot-cli--get-working-directory))
           copilot-cli--processes))

(defun copilot-cli--set-process (process &optional directory)
  "Record PROCESS as the Copilot process for DIRECTORY (or current project)."
  (when (= (hash-table-count copilot-cli--processes) 0)
    (advice-add (copilot-cli--terminal-resize-handler)
                :around #'copilot-cli--terminal-reflow-filter))
  (puthash (or directory (copilot-cli--get-working-directory))
           process copilot-cli--processes))

(defun copilot-cli--cleanup-dead-processes ()
  "Remove stale entries from the process table."
  (maphash (lambda (directory process)
             (unless (process-live-p process)
               (remhash directory copilot-cli--processes)))
           copilot-cli--processes))

(defun copilot-cli--cleanup-all-sessions ()
  "Clean up all active Copilot sessions (called on Emacs exit)."
  (maphash (lambda (directory _process)
             (copilot-cli--cleanup-on-exit directory))
           copilot-cli--processes))

(add-hook 'kill-emacs-hook #'copilot-cli--cleanup-all-sessions)

;;; Active Buffer Tracking
;;
;; When Copilot invokes an MCP tool, the HTTP server needs to know which
;; Emacs buffer was most recently active so tools like xref operate in the
;; right context.  We track this via post-command-hook.

(defun copilot-cli--track-active-buffer ()
  "Update the MCP session's last-active-buffer when the user changes buffers."
  (when-let* ((file-path (buffer-file-name))
              (project (project-current))
              (project-dir (expand-file-name (project-root project)))
              (session-id (gethash project-dir copilot-cli--session-ids)))
    (copilot-cli-mcp-server-update-last-active-buffer session-id (current-buffer))))

;;; Window Display

(defun copilot-cli--display-buffer-in-side-window (buffer)
  "Display BUFFER in a Copilot side window and return the window."
  (let ((window
         (if copilot-cli-use-side-window
             (let* ((side copilot-cli-window-side)
                    (display-buffer-alist
                     `((,(regexp-quote (buffer-name buffer))
                        (display-buffer-in-side-window)
                        (side . ,side)
                        (slot . 0)
                        ,@(when (memq side '(left right))
                            `((window-width
                               . ,(lambda (win)
                                    (let ((delta (- copilot-cli-window-width
                                                    (window-body-width win))))
                                      (unless (zerop delta)
                                        (window-resize win delta t)))))))
                        ,@(when (memq side '(top bottom))
                            `((window-height . ,copilot-cli-window-height)))
                        (window-parameters . ((no-delete-other-windows . t)))))))
               (display-buffer buffer))
           (display-buffer buffer))))
    (setq copilot-cli--last-accessed-buffer buffer)
    (when (and window copilot-cli-focus-on-open) (select-window window))
    (when (and window copilot-cli-use-side-window
               (memq copilot-cli-window-side '(top bottom)))
      (set-window-text-height window copilot-cli-window-height)
      (set-window-dedicated-p window t))
    (when window (copilot-cli--sync-terminal-dimensions buffer window))
    window))

;;; Cleanup

(defvar copilot-cli--cleanup-in-progress nil
  "Guard against recursive cleanup.")

(defun copilot-cli--cleanup-on-exit (directory)
  "Clean up the Copilot session for DIRECTORY."
  (unless copilot-cli--cleanup-in-progress
    (setq copilot-cli--cleanup-in-progress t)
    (unwind-protect
        (progn
          (remhash directory copilot-cli--processes)
          (when (= (hash-table-count copilot-cli--processes) 0)
            (advice-remove (copilot-cli--terminal-resize-handler)
                           #'copilot-cli--terminal-reflow-filter)
            (remove-hook 'post-command-hook #'copilot-cli--track-active-buffer))
          ;; Notify MCP tools server
          (let ((session-id (gethash directory copilot-cli--session-ids)))
            (copilot-cli-mcp-server-session-ended session-id)
            (when session-id (remhash directory copilot-cli--session-ids)))
          ;; Kill the terminal buffer
          (let ((buffer-name (copilot-cli--get-buffer-name directory)))
            (when-let* ((buffer (get-buffer buffer-name)))
              (when (buffer-live-p buffer)
                (let ((kill-buffer-hook nil)
                      (kill-buffer-query-functions nil))
                  (kill-buffer buffer)))))
          (copilot-cli-debug "Cleaned up session for %s"
                             (file-name-nondirectory (directory-file-name directory))))
      (setq copilot-cli--cleanup-in-progress nil))))

;;; CLI Detection

(defun copilot-cli--detect-cli ()
  "Detect whether the Copilot CLI executable is available."
  (setq copilot-cli--cli-available
        (condition-case nil
            (eq (call-process copilot-cli-cli-path nil nil nil "--version") 0)
          (error nil))))

(defun copilot-cli--ensure-cli ()
  "Return non-nil if the CLI is available (detecting it if necessary)."
  (unless copilot-cli--cli-available (copilot-cli--detect-cli))
  copilot-cli--cli-available)

;;; Command Building

(defun copilot-cli--parse-command-string (command-string)
  "Parse COMMAND-STRING into a (program . args) cons for eat-exec."
  (let ((parts (split-string-shell-command command-string)))
    (cons (car parts) (cdr parts))))

(defun copilot-cli--build-command (&optional session-id)
  "Build the shell command string for launching Copilot CLI.
SESSION-ID is embedded in the MCP config URL so the HTTP server can
route tool calls to the correct Emacs session context."
  (let ((cmd copilot-cli-cli-path))
    ;; Extra user-supplied flags
    (when (and copilot-cli-cli-extra-flags
               (not (string-empty-p copilot-cli-cli-extra-flags)))
      (setq cmd (concat cmd " " copilot-cli-cli-extra-flags)))
    ;; MCP config injection
    (when (copilot-cli-mcp-server-ensure-server)
      (when-let* ((config (copilot-cli-mcp-server-get-config session-id)))
        (let ((json-str (json-encode config)))
          (copilot-cli-debug "MCP config: %s" json-str)
          ;; Escape for embedding inside a double-quoted shell argument (vterm uses sh -c)
          (setq json-str (replace-regexp-in-string "\\\\" "\\\\\\\\" json-str))
          (setq json-str (replace-regexp-in-string "\"" "\\\\\"" json-str))
          (setq cmd (concat cmd " --mcp-config \"" json-str "\"")))))
    cmd))

;;; Terminal Session Creation

(defun copilot-cli--create-terminal-session (buffer-name working-dir session-id)
  "Create a terminal buffer running Copilot in WORKING-DIR.
Returns a cons cell (buffer . process) on success."
  (copilot-cli--terminal-ensure-backend)
  (let* ((cmd (copilot-cli--build-command session-id))
         (default-directory working-dir)
         (env-vars '("TERM_PROGRAM=emacs" "FORCE_CODE_TERMINAL=true")))
    (copilot-cli-debug "Starting Copilot: %s" cmd)
    (copilot-cli-debug "Working directory: %s" working-dir)
    (copilot-cli-debug "Session ID: %s" session-id)
    (cond
     ((eq copilot-cli-terminal-backend 'vterm)
      (let* ((vterm-buffer-name buffer-name)
             (vterm-shell cmd)
             (vterm-environment (append env-vars vterm-environment)))
        (let ((buffer (save-window-excursion (vterm vterm-buffer-name))))
          (unless buffer
            (error "Failed to create vterm buffer"))
          (with-current-buffer buffer
            (copilot-cli--configure-vterm-buffer))
          (let ((process (get-buffer-process buffer)))
            (unless process (error "Failed to get vterm process"))
            (cons buffer process)))))

     ((eq copilot-cli-terminal-backend 'eat)
      (let* ((buffer (get-buffer-create buffer-name))
             (eat-term-name "xterm-256color")
             (cmd-parts (copilot-cli--parse-command-string cmd))
             (program (car cmd-parts))
             (args (cdr cmd-parts)))
        (with-current-buffer buffer
          (unless (eq major-mode 'eat-mode) (eat-mode))
          (when copilot-cli-eat-preserve-position
            (setq-local eat--synchronize-scroll-function
                        #'copilot-cli--terminal-position-keeper))
          (setq-local process-environment
                      (append env-vars process-environment))
          (eat-exec buffer buffer-name program nil args)
          (let ((process (get-buffer-process buffer)))
            (unless process (error "Failed to create eat process"))
            (cons buffer process)))))

     (t (error "Unknown terminal backend: %s" copilot-cli-terminal-backend)))))

;;; Session Start/Stop

(defun copilot-cli--toggle-existing-window (existing-buffer working-dir)
  "Toggle visibility of EXISTING-BUFFER for the session in WORKING-DIR."
  (let ((window (get-buffer-window existing-buffer)))
    (if window
        (progn
          (setq copilot-cli--last-accessed-buffer existing-buffer)
          (delete-window window)
          (copilot-cli-debug "Copilot window hidden"))
      (copilot-cli--display-buffer-in-side-window existing-buffer)
      (copilot-cli-debug "Copilot window shown"))))

(defun copilot-cli--start-session ()
  "Start a Copilot CLI session for the current project.
If a session is already running, toggle its window visibility instead."
  (unless (copilot-cli--ensure-cli)
    (user-error "Copilot CLI not available.  Install it and ensure it is in PATH"))
  (copilot-cli--cleanup-dead-processes)
  (let* ((working-dir (copilot-cli--get-working-directory))
         (buffer-name (copilot-cli--get-buffer-name))
         (existing-buffer (get-buffer buffer-name))
         (existing-process (copilot-cli--get-process working-dir)))
    (if (and existing-buffer (buffer-live-p existing-buffer) existing-process)
        (copilot-cli--toggle-existing-window existing-buffer working-dir)
      (copilot-cli--terminal-ensure-backend)
      (let ((session-id (format "copilot-%s-%s"
                                (file-name-nondirectory (directory-file-name working-dir))
                                (format-time-string "%Y%m%d-%H%M%S"))))
        (condition-case err
            (let* ((result (copilot-cli--create-terminal-session
                            buffer-name working-dir session-id))
                   (buffer (car result))
                   (process (cdr result)))
              ;; Register the session
              (copilot-cli-mcp-server-session-started session-id working-dir buffer)
              (copilot-cli--set-process process working-dir)
              (puthash working-dir session-id copilot-cli--session-ids)
              ;; Enable active-buffer tracking
              (add-hook 'post-command-hook #'copilot-cli--track-active-buffer)
              ;; Sentinel: clean up when Copilot exits
              (set-process-sentinel
               process
               (lambda (_proc event)
                 (when (string-match-p "\\(finished\\|exited\\|killed\\|terminated\\)" event)
                   (copilot-cli--cleanup-on-exit working-dir))))
              (with-current-buffer buffer
                (add-hook 'kill-buffer-hook
                          (lambda () (copilot-cli--cleanup-on-exit working-dir))
                          nil t)
                (copilot-cli--setup-terminal-keybindings)
                (cond
                 ((eq copilot-cli-terminal-backend 'vterm)
                  (add-hook 'vterm-exit-functions
                            (lambda (&rest _)
                              (when (buffer-live-p buffer) (kill-buffer buffer)))
                            nil t))
                 ((eq copilot-cli-terminal-backend 'eat)
                  (setq-local eat-kill-buffer-on-exit t))))
              (sleep-for copilot-cli-terminal-initialization-delay)
              (copilot-cli--display-buffer-in-side-window buffer)
              (copilot-cli-log "Copilot started in %s%s"
                               (file-name-nondirectory (directory-file-name working-dir))
                               (if (copilot-cli-mcp-server-get-port)
                                   (format " with MCP tools on port %d"
                                           (copilot-cli-mcp-server-get-port))
                                 "")))
          (error
           (signal (car err) (cdr err))))))))

;;; Interactive Commands

;;;###autoload
(defun copilot-cli ()
  "Start GitHub Copilot CLI for the current project in a side window.
If a session is already running, toggle the window instead."
  (interactive)
  (copilot-cli--start-session))

;;;###autoload
(defun copilot-cli-stop ()
  "Stop the Copilot CLI session for the current project."
  (interactive)
  (let ((buffer-name (copilot-cli--get-buffer-name))
        (working-dir (copilot-cli--get-working-directory)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (progn
          (kill-buffer buffer)
          (copilot-cli-log "Stopping Copilot in %s..."
                           (file-name-nondirectory (directory-file-name working-dir))))
      (copilot-cli-log "No Copilot session is running in this directory"))))

;;;###autoload
(defun copilot-cli-check-status ()
  "Check GitHub Copilot CLI availability and version."
  (interactive)
  (copilot-cli--detect-cli)
  (if copilot-cli--cli-available
      (let ((version (with-temp-buffer
                       (call-process copilot-cli-cli-path nil t nil "--version")
                       (string-trim (buffer-string)))))
        (copilot-cli-log "Copilot CLI version: %s" version))
    (copilot-cli-log "Copilot CLI is not installed or not in PATH.")))

;;;###autoload
(defun copilot-cli-switch-to-buffer ()
  "Switch focus to the Copilot buffer for the current project."
  (interactive)
  (let ((buffer-name (copilot-cli--get-buffer-name)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (if-let* ((window (get-buffer-window buffer)))
            (select-window window)
          (copilot-cli--display-buffer-in-side-window buffer))
      (user-error "No Copilot session for this project.  Use M-x copilot-cli to start one"))))

;;;###autoload
(defun copilot-cli-list-sessions ()
  "List active Copilot sessions and switch to the selected one."
  (interactive)
  (copilot-cli--cleanup-dead-processes)
  (let ((sessions '()))
    (maphash (lambda (directory _)
               (push (cons (abbreviate-file-name directory) directory) sessions))
             copilot-cli--processes)
    (if sessions
        (let ((choice (completing-read "Switch to Copilot session: " sessions nil t)))
          (when choice
            (let* ((directory (alist-get choice sessions nil nil #'string=))
                   (buffer-name (funcall copilot-cli-buffer-name-function directory)))
              (if-let* ((buffer (get-buffer buffer-name)))
                  (copilot-cli--display-buffer-in-side-window buffer)
                (user-error "Buffer for session %s no longer exists" choice)))))
      (copilot-cli-log "No active Copilot sessions"))))

;;;###autoload
(defun copilot-cli-send-escape ()
  "Send the escape key to the Copilot terminal for the current project."
  (interactive)
  (let ((buffer-name (copilot-cli--get-buffer-name)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (with-current-buffer buffer (copilot-cli--terminal-send-escape))
      (user-error "No Copilot session for this project"))))

;;;###autoload
(defun copilot-cli-insert-newline ()
  "Insert a newline into the Copilot prompt (backslash + return)."
  (interactive)
  (let ((buffer-name (copilot-cli--get-buffer-name)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (with-current-buffer buffer
          (copilot-cli--terminal-send-string "\\")
          (sit-for 0.1)
          (copilot-cli--terminal-send-return))
      (user-error "No Copilot session for this project"))))

;;;###autoload
(defun copilot-cli-send-prompt (&optional prompt)
  "Send PROMPT (or read one interactively) to the Copilot terminal."
  (interactive)
  (let ((buffer-name (copilot-cli--get-buffer-name)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (let ((text (or prompt (read-string "Copilot prompt: "))))
          (unless (string-empty-p text)
            (with-current-buffer buffer
              (copilot-cli--terminal-send-string text)
              (sit-for 0.1)
              (copilot-cli--terminal-send-return))))
      (user-error "No Copilot session for this project"))))

;;;###autoload
(defun copilot-cli-toggle ()
  "Toggle visibility of the Copilot window for the current project."
  (interactive)
  (let* ((working-dir (copilot-cli--get-working-directory))
         (buffer (get-buffer (copilot-cli--get-buffer-name))))
    (if buffer
        (copilot-cli--toggle-existing-window buffer working-dir)
      (user-error "No Copilot session for this project"))))

;;;###autoload
(defun copilot-cli-toggle-recent ()
  "Toggle the most recently accessed Copilot window.
Closes all visible Copilot windows, or re-opens the most recent one."
  (interactive)
  (let ((found-visible nil))
    (maphash (lambda (directory _process)
               (let* ((buffer-name (funcall copilot-cli-buffer-name-function directory))
                      (buffer (get-buffer buffer-name)))
                 (when (and buffer (buffer-live-p buffer) (get-buffer-window buffer))
                   (copilot-cli--toggle-existing-window buffer directory)
                   (setq found-visible t))))
             copilot-cli--processes)
    (cond
     (found-visible
      (message "Closed all Copilot windows"))
     ((and copilot-cli--last-accessed-buffer
           (buffer-live-p copilot-cli--last-accessed-buffer))
      (copilot-cli--display-buffer-in-side-window copilot-cli--last-accessed-buffer)
      (message "Opened most recent Copilot session"))
     (t
      (user-error "No recent Copilot session to toggle")))))

(provide 'copilot-cli)

;;; copilot-cli.el ends here
