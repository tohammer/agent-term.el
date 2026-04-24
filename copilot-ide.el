;;; copilot-ide.el --- GitHub Copilot CLI integration for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.9.0") (web-server "0.1.2"))
;; Keywords: ai, copilot, mcp, assistant
;; URL: https://github.com/manzaltu/copilot-ide.el

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
;;   M-x copilot-ide          Start a session for the current project
;;   M-x copilot-ide-stop     Stop the current session
;;   M-x copilot-ide-menu     Open the transient menu
;;
;; To enable Emacs MCP tools (xref, imenu, treesit, project info):
;;   (copilot-ide-emacs-tools-setup)
;;
;; The MCP server is exposed to Copilot via `--mcp-config' at startup.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'copilot-ide-debug)
(require 'copilot-ide-transient)
(require 'copilot-ide-mcp-server)
(require 'copilot-ide-diagnostics)
(require 'copilot-ide-emacs-tools)

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
(declare-function eat-term-display-beginning "eat" (terminal))
(declare-function eat-term-size "eat" (terminal))
(declare-function eat-term-resize "eat" (terminal width height))
(declare-function eat-term-redisplay "eat" (terminal))
(declare-function eat--adjust-process-window-size "eat" (process windows))

;;; Customization

(defgroup copilot-ide nil
  "GitHub Copilot CLI integration for Emacs."
  :group 'tools
  :prefix "copilot-ide-")

(defcustom copilot-ide-cli-path "copilot"
  "Path to the GitHub Copilot CLI executable."
  :type 'string
  :group 'copilot-ide)

(defcustom copilot-ide-buffer-name-function #'copilot-ide--default-buffer-name
  "Function to generate buffer names for Copilot sessions.
Called with one argument (the working directory string)."
  :type 'function
  :group 'copilot-ide)

(defcustom copilot-ide-cli-extra-flags ""
  "Additional flags to pass to the Copilot CLI (space-separated string)."
  :type 'string
  :group 'copilot-ide)

(defcustom copilot-ide-window-side 'right
  "Side of the frame where the Copilot window appears."
  :type '(choice (const left) (const right) (const top) (const bottom))
  :group 'copilot-ide)

(defcustom copilot-ide-window-width 100
  "Width of the Copilot side window (columns), for left/right placement."
  :type 'integer
  :group 'copilot-ide)

(defcustom copilot-ide-window-height 20
  "Height of the Copilot side window (lines), for top/bottom placement."
  :type 'integer
  :group 'copilot-ide)

(defcustom copilot-ide-focus-on-open t
  "When non-nil, focus the Copilot window when it is opened."
  :type 'boolean
  :group 'copilot-ide)

(defcustom copilot-ide-use-side-window t
  "When non-nil, display Copilot in a dedicated side window.
When nil, use a regular buffer display."
  :type 'boolean
  :group 'copilot-ide)

(defcustom copilot-ide-show-modeline t
  "When non-nil, ensure the modeline is visible in the Copilot buffer.
Some terminal modes (e.g. vterm via Doom Emacs) hide the modeline by default;
this option overrides that behaviour."
  :type 'boolean
  :group 'copilot-ide)

(defcustom copilot-ide-terminal-backend 'vterm
  "Terminal backend to use for running Copilot CLI.
Either `vterm' or `eat'."
  :type '(choice (const :tag "vterm" vterm)
                 (const :tag "eat" eat))
  :group 'copilot-ide)

(defcustom copilot-ide-terminal-initialization-delay 0.1
  "Seconds to wait after creating the terminal before displaying it."
  :type 'number
  :group 'copilot-ide)

(defcustom copilot-ide-eat-preserve-position t
  "When non-nil, preserve the terminal cursor position in eat buffers."
  :type 'boolean
  :group 'copilot-ide)

(defcustom copilot-ide-emacs-keybindings '()
  "Keys to handle with their normal Emacs bindings instead of forwarding to the terminal.
Each entry is a key string accepted by `kbd'.  The key's global binding
at the time the session starts will be used.  Add any key here that you
want Emacs to handle rather than the terminal process."
  :type '(repeat string)
  :group 'copilot-ide)

;;; State

(defvar copilot-ide--cli-available nil
  "Non-nil when the Copilot CLI executable has been detected.")

(defvar copilot-ide--processes (make-hash-table :test 'equal)
  "Hash table mapping project directories to Copilot process objects.")

(defvar copilot-ide--session-ids (make-hash-table :test 'equal)
  "Hash table mapping project directories to MCP session IDs.")

(defvar copilot-ide--last-accessed-buffer nil
  "Most recently displayed Copilot terminal buffer.")

;;; Terminal Backend: vterm helpers

(defcustom copilot-ide-vterm-anti-flicker t
  "Batch rapid vterm output sequences to reduce terminal flicker.
When enabled, detects high-density escape sequences (TUI redraws) and
batches them into a single redisplay update."
  :type 'boolean
  :group 'copilot-ide)

(defcustom copilot-ide-vterm-render-delay 0.005
  "Delay in seconds for batched vterm rendering when anti-flicker is active."
  :type 'number
  :group 'copilot-ide)

(defvar-local copilot-ide--vterm-render-queue nil
  "Pending output strings for batched vterm rendering (reverse order).")

(defvar-local copilot-ide--vterm-render-timer nil
  "Timer for flushing the vterm render queue.")

(defvar-local copilot-ide--saved-cursor-type nil
  "Saved cursor-type when entering vterm copy mode.")

(defun copilot-ide--count-escape-sequence (sequence input)
  "Count occurrences of SEQUENCE in INPUT efficiently."
  (let ((count 0) (start 0))
    (while (setq start (string-search sequence input start))
      (cl-incf count)
      (cl-incf start (length sequence)))
    count))

(defun copilot-ide--vterm-smart-renderer (orig-fun process input)
  "Batch rapid vterm output to reduce TUI flicker.
Wraps ORIG-FUN; detects high-density escape sequences and defers
rendering until a quiet moment.  PROCESS and INPUT are passed through."
  (if (not copilot-ide-vterm-anti-flicker)
      (funcall orig-fun process input)
    (with-current-buffer (process-buffer process)
      ;; Fast path: no escapes and no active queue → pass through immediately
      (if (and (not copilot-ide--vterm-render-queue)
               (not (string-search "\033" input)))
          (funcall orig-fun process input)
        (let* ((complex-redraw
                (string-match-p "\033\\[[0-9]*A.*\033\\[K.*\033\\[[0-9]*A.*\033\\[K" input))
               (clear-count (copilot-ide--count-escape-sequence "\033[K" input))
               (escape-count (cl-count ?\033 input))
               (escape-density (if (> (length input) 0)
                                   (/ (float escape-count) (length input)) 0)))
          (if (or complex-redraw
                  (and (> escape-density 0.3) (>= clear-count 2))
                  copilot-ide--vterm-render-queue)
              (progn
                (push input copilot-ide--vterm-render-queue)
                (when copilot-ide--vterm-render-timer
                  (cancel-timer copilot-ide--vterm-render-timer))
                (setq copilot-ide--vterm-render-timer
                      (run-at-time copilot-ide-vterm-render-delay nil
                                   (lambda (buf)
                                     (when (buffer-live-p buf)
                                       (with-current-buffer buf
                                         (when copilot-ide--vterm-render-queue
                                           (let* ((inhibit-redisplay t)
                                                  (data (apply #'concat
                                                               (nreverse copilot-ide--vterm-render-queue))))
                                             (setq copilot-ide--vterm-render-queue nil
                                                   copilot-ide--vterm-render-timer nil)
                                             (funcall orig-fun
                                                      (get-buffer-process buf)
                                                      data))))))
                                   (current-buffer))))
            (funcall orig-fun process input)))))))

(defun copilot-ide--vterm-copy-mode-hook ()
  "Preserve cursor visibility when entering/leaving vterm copy mode."
  (if vterm-copy-mode
      (progn
        (setq copilot-ide--saved-cursor-type cursor-type)
        (when (null cursor-type) (setq cursor-type t)))
    (setq cursor-type copilot-ide--saved-cursor-type)))

(defun copilot-ide--eat-emacs-mode-cursor-fix (&rest _)
  "Ensure cursor is visible when switching to eat emacs mode."
  (when (and (copilot-ide--session-buffer-p (current-buffer))
             (null cursor-type))
    (setq-local cursor-type t)))

(defun copilot-ide--eat-terminal-mode-cursor-fix (&rest _)
  "Restore invisible cursor when leaving eat emacs mode in a Copilot buffer."
  (when (copilot-ide--session-buffer-p (current-buffer))
    (setq-local cursor-type nil)))

(defun copilot-ide--configure-vterm-buffer ()
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
  (add-hook 'vterm-copy-mode-hook #'copilot-ide--vterm-copy-mode-hook nil t)
  (when-let* ((proc (get-buffer-process (current-buffer))))
    (set-process-query-on-exit-flag proc nil))
  (when copilot-ide-vterm-anti-flicker
    (advice-add 'vterm--filter :around #'copilot-ide--vterm-smart-renderer)))

;;; Terminal Backend Abstraction

(defun copilot-ide--terminal-ensure-backend ()
  "Signal an error if the configured terminal backend is not available."
  (cond
   ((eq copilot-ide-terminal-backend 'vterm)
    (unless (featurep 'vterm) (require 'vterm nil t))
    (unless (featurep 'vterm)
      (user-error "vterm is not installed.  Install it or set `copilot-ide-terminal-backend' to 'eat")))
   ((eq copilot-ide-terminal-backend 'eat)
    (unless (featurep 'eat) (require 'eat nil t))
    (unless (featurep 'eat)
      (user-error "eat is not installed.  Install it or set `copilot-ide-terminal-backend' to 'vterm")))
   (t
    (user-error "Invalid terminal backend: %s.  Use 'vterm or 'eat" copilot-ide-terminal-backend))))

(defun copilot-ide--terminal-send-string (string)
  "Send STRING to the terminal in the current buffer."
  (cond
   ((eq copilot-ide-terminal-backend 'vterm) (vterm-send-string string))
   ((eq copilot-ide-terminal-backend 'eat)
    (when eat-terminal (eat-term-send-string eat-terminal string)))
   (t (error "Unknown terminal backend: %s" copilot-ide-terminal-backend))))

(defun copilot-ide--terminal-send-escape ()
  "Send the escape key to the terminal in the current buffer."
  (cond
   ((eq copilot-ide-terminal-backend 'vterm) (vterm-send-escape))
   ((eq copilot-ide-terminal-backend 'eat)
    (when eat-terminal (eat-term-send-string eat-terminal "\e")))
   (t (error "Unknown terminal backend: %s" copilot-ide-terminal-backend))))

(defun copilot-ide--terminal-send-return ()
  "Send return to the terminal in the current buffer."
  (cond
   ((eq copilot-ide-terminal-backend 'vterm) (vterm-send-return))
   ((eq copilot-ide-terminal-backend 'eat)
    (when eat-terminal (eat-term-send-string eat-terminal "\r")))
   (t (error "Unknown terminal backend: %s" copilot-ide-terminal-backend))))

(defun copilot-ide--sync-terminal-dimensions (buffer window)
  "Sync the terminal process dimensions in BUFFER to match WINDOW."
  (when (and buffer window (buffer-live-p buffer) (window-live-p window))
    (with-current-buffer buffer
      (when-let* ((proc (get-buffer-process buffer)))
        (cond
         ((and (eq copilot-ide-terminal-backend 'eat)
               (bound-and-true-p eat-terminal))
          (with-selected-window window
            (let ((width (max (window-max-chars-per-line) 1))
                  (height (max (floor (window-screen-lines)) 1))
                  (inhibit-read-only t))
              (eat-term-resize eat-terminal width height)
              (eat-term-redisplay eat-terminal))))
         (t
          (set-process-window-size proc
                                   (window-body-height window)
                                   (window-body-width window))))))))

(defun copilot-ide--setup-terminal-keybindings ()
  "Bind Copilot-specific keys in the current terminal buffer.
Keys in `copilot-ide-emacs-keybindings' are intercepted and handled
by their normal Emacs global binding instead of forwarding to the terminal."
  (local-set-key (kbd "S-<return>") #'copilot-ide-insert-newline)
  (local-set-key (kbd "C-<escape>") #'copilot-ide-send-escape)
  (dolist (key copilot-ide-emacs-keybindings)
    (when-let* ((binding (global-key-binding (kbd key))))
      (local-set-key (kbd key) binding)))
  ;; For eat, minor mode keymaps (eat-semi-char-mode-map) take precedence over
  ;; the buffer-local keymap, so local-set-key alone is insufficient.
  ;; Use minor-mode-overriding-map-alist (buffer-local) to override eat's
  ;; semi-char keymap for the intercepted keys.  The parent is set to
  ;; eat-semi-char-mode-map so that all other keys still fall through to eat's
  ;; normal handling — minor-mode-overriding-map-alist fully replaces the
  ;; minor mode's map, so without a parent all unbound keys would bypass
  ;; eat-self-input and hit self-insert-command on read-only terminal text.
  (when (eq copilot-ide-terminal-backend 'eat)
    (let ((override-map (make-sparse-keymap)))
      (set-keymap-parent override-map eat-semi-char-mode-map)
      (define-key override-map (kbd "S-<return>") #'copilot-ide-insert-newline)
      (define-key override-map (kbd "C-<escape>") #'copilot-ide-send-escape)
      (dolist (key copilot-ide-emacs-keybindings)
        (when-let* ((binding (global-key-binding (kbd key))))
          (define-key override-map (kbd key) binding)))
      (setq-local minor-mode-overriding-map-alist
                  (cons (cons 'eat--semi-char-mode override-map)
                        minor-mode-overriding-map-alist)))))

;;; Reflow Glitch Prevention
;;
;; Suppresses spurious terminal reflows caused by height-only resize events,
;; which can trigger unwanted scrolling in terminal AI applications.

(defun copilot-ide--terminal-resize-handler ()
  "Return the terminal resize function for the active backend."
  (pcase copilot-ide-terminal-backend
    ('vterm #'vterm--window-adjust-process-window-size)
    ('eat #'eat--adjust-process-window-size)
    (_ (error "Unsupported terminal backend: %s" copilot-ide-terminal-backend))))

(defun copilot-ide--terminal-scroll-mode-active-p ()
  "Return non-nil when the terminal is in scroll/copy mode."
  (pcase copilot-ide-terminal-backend
    ('vterm (bound-and-true-p vterm-copy-mode))
    ('eat (not (bound-and-true-p eat--semi-char-mode)))
    (_ nil)))

(defun copilot-ide--session-buffer-p (buffer)
  "Return non-nil if BUFFER belongs to a Copilot session."
  (when-let* ((name (if (stringp buffer) buffer (buffer-name buffer))))
    (string-prefix-p "*copilot-ide[" name)))

(defun copilot-ide--terminal-reflow-filter (original-fn &rest args)
  "Wrap ORIGINAL-FN to suppress height-only terminal reflows.
For eat, skip entirely when only height changed to keep the eat
terminal model and process dimensions in sync."
  (cond
   ((not (copilot-ide--session-buffer-p (current-buffer)))
    (apply original-fn args))
   ((copilot-ide--terminal-scroll-mode-active-p)
    nil)
   (t
    (let ((dimensions-stable t)
          (current-buf (current-buffer)))
      ;; Only check windows showing THIS buffer, not all session windows.
      ;; Otherwise resizing one session's window updates another session's
      ;; cache, causing the second session's resize to be suppressed.
      (dolist (win (get-buffer-window-list current-buf nil t))
        (let* ((new-width (window-width win))
               (cached-width (window-parameter win 'copilot-ide-cached-width)))
          (unless (eql new-width cached-width)
            (setq dimensions-stable nil)
            (set-window-parameter win 'copilot-ide-cached-width new-width))))
      (if dimensions-stable
          ;; Height-only change: skip the original function entirely so that
          ;; eat-term-resize is NOT called either, keeping eat's model and
          ;; the process in agreement on the terminal dimensions.
          nil
        (apply original-fn args))))))

;;; eat position keeper

(defun copilot-ide--terminal-position-keeper (window-list)
  "Maintain stable eat terminal position across window switches.
Uses eat's native recenter calculation to ensure the terminal display
area is properly aligned within each window."
  (dolist (win window-list)
    (if (eq win 'buffer)
        (goto-char (eat-term-display-cursor eat-terminal))
      (let ((terminal-point (eat-term-display-cursor eat-terminal)))
        (set-window-point win terminal-point)
        (with-selected-window win
          (goto-char terminal-point)
          (recenter
           (- (how-many "\n" (eat-term-display-beginning eat-terminal)
                        terminal-point)
              (cdr (eat-term-size eat-terminal))
              (max 0 (- (floor (window-screen-lines))
                        (cdr (eat-term-size eat-terminal)))))))))))

;;; Session Helpers

(defun copilot-ide--default-buffer-name (directory)
  "Return the default buffer name for a session in DIRECTORY."
  (format "*copilot-ide[%s]*"
          (file-name-nondirectory (directory-file-name directory))))

(defun copilot-ide--get-working-directory ()
  "Return the project root, or `default-directory' if outside any project."
  (if-let* ((project (project-current)))
      (expand-file-name (project-root project))
    (expand-file-name default-directory)))

(defun copilot-ide--get-buffer-name (&optional directory)
  "Return the buffer name for the session in DIRECTORY (or current project)."
  (funcall copilot-ide-buffer-name-function
           (or directory (copilot-ide--get-working-directory))))

(defun copilot-ide--get-process (&optional directory)
  "Return the Copilot process for DIRECTORY (or current project), or nil."
  (gethash (or directory (copilot-ide--get-working-directory))
           copilot-ide--processes))

(defun copilot-ide--set-process (process &optional directory)
  "Record PROCESS as the Copilot process for DIRECTORY (or current project)."
  (when (= (hash-table-count copilot-ide--processes) 0)
    (advice-add (copilot-ide--terminal-resize-handler)
                :around #'copilot-ide--terminal-reflow-filter))
  (puthash (or directory (copilot-ide--get-working-directory))
           process copilot-ide--processes))

(defun copilot-ide--cleanup-dead-processes ()
  "Remove stale entries from the process table."
  (maphash (lambda (directory process)
             (unless (process-live-p process)
               (remhash directory copilot-ide--processes)))
           copilot-ide--processes))

(defun copilot-ide--cleanup-all-sessions ()
  "Clean up all active Copilot sessions (called on Emacs exit)."
  (maphash (lambda (directory _process)
             (copilot-ide--cleanup-on-exit directory))
           copilot-ide--processes))

(add-hook 'kill-emacs-hook #'copilot-ide--cleanup-all-sessions)

;;; Active Buffer Tracking
;;
;; When Copilot invokes an MCP tool, the HTTP server needs to know which
;; Emacs buffer was most recently active so tools like xref operate in the
;; right context.  We track this via post-command-hook.

(defun copilot-ide--track-active-buffer ()
  "Update the MCP session's last-active-buffer when the user changes buffers."
  (when-let* ((file-path (buffer-file-name))
              (project (project-current))
              (project-dir (expand-file-name (project-root project)))
              (session-id (gethash project-dir copilot-ide--session-ids)))
    (copilot-ide-mcp-server-update-last-active-buffer session-id (current-buffer))))

;;; Window Display

(defun copilot-ide--display-buffer-in-side-window (buffer)
  "Display BUFFER in a Copilot side window and return the window."
  (let ((window
         (if copilot-ide-use-side-window
             (let* ((side copilot-ide-window-side)
                    (display-buffer-alist
                     `((,(regexp-quote (buffer-name buffer))
                        (display-buffer-in-side-window)
                        (side . ,side)
                        (slot . 0)
                        ,@(when (memq side '(left right))
                            `((window-width
                               . ,(lambda (win)
                                    (let ((delta (- copilot-ide-window-width
                                                    (window-body-width win))))
                                      (unless (zerop delta)
                                        (window-resize win delta t)))))))
                        ,@(when (memq side '(top bottom))
                            `((window-height . ,copilot-ide-window-height)))
                        (window-parameters . ((no-delete-other-windows . t)))))))
               (display-buffer buffer))
           (progn (switch-to-buffer buffer) (selected-window)))))
    (setq copilot-ide--last-accessed-buffer buffer)
    (when (and window copilot-ide-focus-on-open) (select-window window))
    (when (and window copilot-ide-use-side-window
               (memq copilot-ide-window-side '(top bottom)))
      (set-window-text-height window copilot-ide-window-height)
      (set-window-dedicated-p window t))
    (when window (copilot-ide--sync-terminal-dimensions buffer window))
    window))

;;; Cleanup

(defvar copilot-ide--cleanup-in-progress nil
  "Guard against recursive cleanup.")

(defun copilot-ide--cleanup-on-exit (directory)
  "Clean up the Copilot session for DIRECTORY."
  (unless copilot-ide--cleanup-in-progress
    (setq copilot-ide--cleanup-in-progress t)
    (unwind-protect
        (progn
          (remhash directory copilot-ide--processes)
          (when (= (hash-table-count copilot-ide--processes) 0)
            (advice-remove (copilot-ide--terminal-resize-handler)
                           #'copilot-ide--terminal-reflow-filter)
            (remove-hook 'post-command-hook #'copilot-ide--track-active-buffer))
          ;; Notify MCP tools server
          (let ((session-id (gethash directory copilot-ide--session-ids)))
            (copilot-ide-mcp-server-session-ended session-id)
            (when session-id (remhash directory copilot-ide--session-ids)))
          ;; Kill the terminal buffer
          (let ((buffer-name (copilot-ide--get-buffer-name directory)))
            (when-let* ((buffer (get-buffer buffer-name)))
              (when (buffer-live-p buffer)
                (let ((kill-buffer-hook nil)
                      (kill-buffer-query-functions nil))
                  (kill-buffer buffer)))))
          (copilot-ide-debug "Cleaned up session for %s"
                             (file-name-nondirectory (directory-file-name directory))))
      (setq copilot-ide--cleanup-in-progress nil))))

;;; CLI Detection

(defun copilot-ide--detect-cli ()
  "Detect whether the Copilot CLI executable is available."
  (setq copilot-ide--cli-available
        (condition-case nil
            (eq (call-process copilot-ide-cli-path nil nil nil "--version") 0)
          (error nil))))

(defun copilot-ide--ensure-cli ()
  "Return non-nil if the CLI is available (detecting it if necessary)."
  (unless copilot-ide--cli-available (copilot-ide--detect-cli))
  copilot-ide--cli-available)

;;; Command Building

(defun copilot-ide--parse-command-string (command-string)
  "Parse COMMAND-STRING into a (program . args) cons for eat-exec."
  (let ((parts (split-string-shell-command command-string)))
    (cons (car parts) (cdr parts))))

(defun copilot-ide--build-command (&optional session-id continue resume)
  "Build the shell command string for launching Copilot CLI.
SESSION-ID is embedded in the MCP config URL so the HTTP server can
route tool calls to the correct Emacs session context.
CONTINUE, if non-nil, adds --continue to resume the most recent session.
RESUME, if non-nil, adds --resume (optionally with a session ID string)."
  (let ((cmd copilot-ide-cli-path))
    ;; Session resume flags
    (when continue
      (setq cmd (concat cmd " --continue")))
    (when resume
      (setq cmd (concat cmd " --resume"
                        (if (stringp resume) (concat " " resume) ""))))
    ;; Extra user-supplied flags
    (when (and copilot-ide-cli-extra-flags
               (not (string-empty-p copilot-ide-cli-extra-flags)))
      (setq cmd (concat cmd " " copilot-ide-cli-extra-flags)))
    ;; MCP config injection
    (when (copilot-ide-mcp-server-ensure-server)
      (when-let* ((config (copilot-ide-mcp-server-get-config session-id)))
        (let ((json-str (json-encode config)))
          (copilot-ide-debug "MCP config: %s" json-str)
          ;; Escape for embedding inside a double-quoted shell argument (vterm uses sh -c)
          (setq json-str (replace-regexp-in-string "\\\\" "\\\\\\\\" json-str))
          (setq json-str (replace-regexp-in-string "\"" "\\\\\"" json-str))
          (setq cmd (concat cmd " --additional-mcp-config \"" json-str "\"")))))
    cmd))

;;; Terminal Session Creation

(defun copilot-ide--create-terminal-session (buffer-name working-dir session-id
                                              &optional continue resume)
  "Create a terminal buffer running Copilot in WORKING-DIR.
CONTINUE and RESUME are passed to `copilot-ide--build-command'.
Returns a cons cell (buffer . process) on success."
  (copilot-ide--terminal-ensure-backend)
  (let* ((cmd (copilot-ide--build-command session-id continue resume))
         (default-directory working-dir)
         (env-vars '("TERM_PROGRAM=emacs" "FORCE_CODE_TERMINAL=true")))
    (copilot-ide-debug "Starting Copilot: %s" cmd)
    (copilot-ide-debug "Working directory: %s" working-dir)
    (copilot-ide-debug "Session ID: %s" session-id)
    (cond
     ((eq copilot-ide-terminal-backend 'vterm)
      (let* ((vterm-buffer-name buffer-name)
             (vterm-shell cmd)
             (vterm-environment (append env-vars vterm-environment)))
        (let ((buffer (save-window-excursion (vterm vterm-buffer-name))))
          (unless buffer
            (error "Failed to create vterm buffer"))
          (with-current-buffer buffer
            (copilot-ide--configure-vterm-buffer))
          (let ((process (get-buffer-process buffer)))
            (unless process (error "Failed to get vterm process"))
            (cons buffer process)))))

     ((eq copilot-ide-terminal-backend 'eat)
      (let* ((buffer (get-buffer-create buffer-name))
             (eat-term-name "xterm-256color")
             (cmd-parts (copilot-ide--parse-command-string cmd))
             (program (car cmd-parts))
             (args (cdr cmd-parts)))
        (with-current-buffer buffer
          (unless (eq major-mode 'eat-mode) (eat-mode))
          (when copilot-ide-eat-preserve-position
            (setq-local eat--synchronize-scroll-function
                        #'copilot-ide--terminal-position-keeper))
          (setq-local process-environment
                      (append env-vars process-environment))
          (setq-local eat-kill-buffer-on-exit t)
          (advice-add 'eat-emacs-mode :after
                      #'copilot-ide--eat-emacs-mode-cursor-fix)
          (dolist (fn '(eat-semi-char-mode eat-char-mode))
            (advice-add fn :after
                        #'copilot-ide--eat-terminal-mode-cursor-fix))
          (eat-exec buffer buffer-name program nil args)
          (let ((process (get-buffer-process buffer)))
            (unless process (error "Failed to create eat process"))
            (cons buffer process)))))

     (t (error "Unknown terminal backend: %s" copilot-ide-terminal-backend)))))

;;; Session Start/Stop

(defun copilot-ide--toggle-existing-window (existing-buffer working-dir)
  "Toggle visibility of EXISTING-BUFFER for the session in WORKING-DIR."
  (let ((window (get-buffer-window existing-buffer)))
    (if window
        (progn
          (setq copilot-ide--last-accessed-buffer existing-buffer)
          (delete-window window)
          (copilot-ide-debug "Copilot window hidden"))
      (copilot-ide--display-buffer-in-side-window existing-buffer)
      (copilot-ide-debug "Copilot window shown"))))

(defun copilot-ide--start-session (&optional continue resume)
  "Start a Copilot CLI session for the current project.
If a session is already running, toggle its window visibility instead.
CONTINUE, if non-nil, passes --continue to resume the most recent session.
RESUME, if non-nil, passes --resume (with optional session-id string)."
  (unless (copilot-ide--ensure-cli)
    (user-error "Copilot CLI not available.  Install it and ensure it is in PATH"))
  (copilot-ide--cleanup-dead-processes)
  (let* ((working-dir (copilot-ide--get-working-directory))
         (buffer-name (copilot-ide--get-buffer-name))
         (existing-buffer (get-buffer buffer-name))
         (existing-process (copilot-ide--get-process working-dir)))
    (if (and existing-buffer (buffer-live-p existing-buffer) existing-process)
        (copilot-ide--toggle-existing-window existing-buffer working-dir)
      (copilot-ide--terminal-ensure-backend)
      (let ((session-id (format "copilot-%s-%s"
                                (file-name-nondirectory (directory-file-name working-dir))
                                (format-time-string "%Y%m%d-%H%M%S"))))
        (condition-case err
            (let* ((result (copilot-ide--create-terminal-session
                            buffer-name working-dir session-id continue resume))
                   (buffer (car result))
                   (process (cdr result)))
              ;; Register the session
              (copilot-ide-mcp-server-session-started session-id working-dir buffer)
              (copilot-ide--set-process process working-dir)
              (puthash working-dir session-id copilot-ide--session-ids)
              ;; Enable active-buffer tracking
              (add-hook 'post-command-hook #'copilot-ide--track-active-buffer)
              ;; Sentinel: clean up when Copilot exits
              (set-process-sentinel
               process
               (lambda (_proc event)
                 (when (string-match-p "\\(finished\\|exited\\|killed\\|terminated\\)" event)
                   (copilot-ide--cleanup-on-exit working-dir))))
              (with-current-buffer buffer
                (add-hook 'kill-buffer-hook
                          (lambda () (copilot-ide--cleanup-on-exit working-dir))
                          nil t)
                (copilot-ide--setup-terminal-keybindings)
                (when (and copilot-ide-show-modeline
                           (bound-and-true-p hide-mode-line-mode))
                  (hide-mode-line-mode -1))
                (cond
                 ((eq copilot-ide-terminal-backend 'vterm)
                  (add-hook 'vterm-exit-functions
                            (lambda (&rest _)
                              (when (buffer-live-p buffer) (kill-buffer buffer)))
                            nil t))
                 ((eq copilot-ide-terminal-backend 'eat) nil)))
              (sleep-for copilot-ide-terminal-initialization-delay)
              (copilot-ide--display-buffer-in-side-window buffer)
              (copilot-ide-log "Copilot started in %s%s"
                               (file-name-nondirectory (directory-file-name working-dir))
                               (if (copilot-ide-mcp-server-get-port)
                                   (format " with MCP tools on port %d"
                                           (copilot-ide-mcp-server-get-port))
                                 "")))
          (error
           (signal (car err) (cdr err))))))))

;;; Interactive Commands

;;;###autoload
(defun copilot-ide ()
  "Start GitHub Copilot CLI for the current project in a side window.
If a session is already running, toggle the window instead."
  (interactive)
  (copilot-ide--start-session))

;;;###autoload
(defun copilot-ide-continue ()
  "Continue the most recent Copilot session for the current project.
Starts Copilot with --continue to resume the last conversation."
  (interactive)
  (copilot-ide--start-session t nil))

;;;###autoload
(defun copilot-ide-resume (&optional session-id)
  "Resume a previous Copilot session, optionally specifying SESSION-ID.
With a prefix argument, prompts for a session ID.
Without a session ID, Copilot presents a session picker."
  (interactive
   (list (when current-prefix-arg
           (read-string "Session ID (leave empty for picker): "))))
  (copilot-ide--start-session nil (if (and session-id (not (string-empty-p session-id)))
                                      session-id
                                    t)))

;;;###autoload
(defun copilot-ide-stop ()
  "Stop the Copilot CLI session for the current project."
  (interactive)
  (let ((buffer-name (copilot-ide--get-buffer-name))
        (working-dir (copilot-ide--get-working-directory)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (progn
          (kill-buffer buffer)
          (copilot-ide-log "Stopping Copilot in %s..."
                           (file-name-nondirectory (directory-file-name working-dir))))
      (copilot-ide-log "No Copilot session is running in this directory"))))

;;;###autoload
(defun copilot-ide-check-status ()
  "Check GitHub Copilot CLI availability and version."
  (interactive)
  (copilot-ide--detect-cli)
  (if copilot-ide--cli-available
      (let ((version (with-temp-buffer
                       (call-process copilot-ide-cli-path nil t nil "--version")
                       (string-trim (buffer-string)))))
        (copilot-ide-log "Copilot CLI version: %s" version))
    (copilot-ide-log "Copilot CLI is not installed or not in PATH.")))

;;;###autoload
(defun copilot-ide-switch-to-buffer ()
  "Switch focus to the Copilot buffer for the current project."
  (interactive)
  (let ((buffer-name (copilot-ide--get-buffer-name)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (if-let* ((window (get-buffer-window buffer)))
            (select-window window)
          (copilot-ide--display-buffer-in-side-window buffer))
      (user-error "No Copilot session for this project.  Use M-x copilot-ide to start one"))))

;;;###autoload
(defun copilot-ide-list-sessions ()
  "List active Copilot sessions and switch to the selected one."
  (interactive)
  (copilot-ide--cleanup-dead-processes)
  (let ((sessions '()))
    (maphash (lambda (directory _)
               (push (cons (abbreviate-file-name directory) directory) sessions))
             copilot-ide--processes)
    (if sessions
        (let ((choice (completing-read "Switch to Copilot session: " sessions nil t)))
          (when choice
            (let* ((directory (alist-get choice sessions nil nil #'string=))
                   (buffer-name (funcall copilot-ide-buffer-name-function directory)))
              (if-let* ((buffer (get-buffer buffer-name)))
                  (copilot-ide--display-buffer-in-side-window buffer)
                (user-error "Buffer for session %s no longer exists" choice)))))
      (copilot-ide-log "No active Copilot sessions"))))

;;;###autoload
(defun copilot-ide-send-escape ()
  "Send the escape key to the Copilot terminal for the current project."
  (interactive)
  (let ((buffer-name (copilot-ide--get-buffer-name)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (with-current-buffer buffer (copilot-ide--terminal-send-escape))
      (user-error "No Copilot session for this project"))))

;;;###autoload
(defun copilot-ide-insert-newline ()
  "Insert a newline into the Copilot prompt (backslash + return)."
  (interactive)
  (let ((buffer-name (copilot-ide--get-buffer-name)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (with-current-buffer buffer
          (copilot-ide--terminal-send-string "\\")
          (sit-for 0.1)
          (copilot-ide--terminal-send-return))
      (user-error "No Copilot session for this project"))))

;;;###autoload
(defun copilot-ide-send-prompt (&optional prompt)
  "Send PROMPT (or read one interactively) to the Copilot terminal."
  (interactive)
  (let ((buffer-name (copilot-ide--get-buffer-name)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (let ((text (or prompt (read-string "Copilot prompt: "))))
          (unless (string-empty-p text)
            (with-current-buffer buffer
              (copilot-ide--terminal-send-string text)
              (sit-for 0.1)
              (copilot-ide--terminal-send-return))))
      (user-error "No Copilot session for this project"))))

;;;###autoload
(defun copilot-ide-toggle ()
  "Toggle visibility of the Copilot window for the current project."
  (interactive)
  (let* ((working-dir (copilot-ide--get-working-directory))
         (buffer (get-buffer (copilot-ide--get-buffer-name))))
    (if buffer
        (copilot-ide--toggle-existing-window buffer working-dir)
      (user-error "No Copilot session for this project"))))

;;;###autoload
(defun copilot-ide-toggle-recent ()
  "Toggle the most recently accessed Copilot window.
Closes all visible Copilot windows, or re-opens the most recent one."
  (interactive)
  (let ((found-visible nil))
    (maphash (lambda (directory _process)
               (let* ((buffer-name (funcall copilot-ide-buffer-name-function directory))
                      (buffer (get-buffer buffer-name)))
                 (when (and buffer (buffer-live-p buffer) (get-buffer-window buffer))
                   (copilot-ide--toggle-existing-window buffer directory)
                   (setq found-visible t))))
             copilot-ide--processes)
    (cond
     (found-visible
      (message "Closed all Copilot windows"))
     ((and copilot-ide--last-accessed-buffer
           (buffer-live-p copilot-ide--last-accessed-buffer))
      (copilot-ide--display-buffer-in-side-window copilot-ide--last-accessed-buffer)
      (message "Opened most recent Copilot session"))
     (t
      (user-error "No recent Copilot session to toggle")))))

(provide 'copilot-ide)

;;; copilot-ide.el ends here
