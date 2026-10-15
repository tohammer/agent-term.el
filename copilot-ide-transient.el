;;; copilot-ide-transient.el --- Transient menus for copilot-ide  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Tobias Hammer
;; Copyright (C) 2025 Yoav Orot

;; Based on claude-code-ide.el by Yoav Orot (manzaltu)
;; https://github.com/manzaltu/claude-code-ide.el

;; Keywords: ai, transient, menu
;; SPDX-License-Identifier: GPL-3.0-or-later

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

;; Transient menus for copilot-ide.el.

;;; Code:

(require 'transient)
(require 'copilot-ide-debug)

(declare-function copilot-ide "copilot-ide" ())
(declare-function copilot-ide-continue "copilot-ide" ())
(declare-function copilot-ide-resume "copilot-ide" (&optional session-id))
(declare-function copilot-ide-start-agent "copilot-ide" (agent))
(declare-function copilot-ide-stop "copilot-ide" ())
(declare-function copilot-ide-list-sessions "copilot-ide" ())
(declare-function copilot-ide-switch-to-buffer "copilot-ide" ())
(declare-function copilot-ide-send-prompt "copilot-ide" (&optional prompt))
(declare-function copilot-ide-send-escape "copilot-ide" ())
(declare-function copilot-ide-insert-newline "copilot-ide" ())
(declare-function copilot-ide-toggle "copilot-ide" ())
(declare-function copilot-ide-toggle-recent "copilot-ide" ())
(declare-function copilot-ide-check-status "copilot-ide" ())
(declare-function copilot-ide--current-session "copilot-ide" ())
(declare-function copilot-ide--session-label "copilot-ide" (session))
(declare-function copilot-ide--agent-name "copilot-ide" (&optional agent))
(declare-function copilot-ide--program "copilot-ide" (&optional agent))
(declare-function copilot-ide--cli-available-p "copilot-ide" (&optional agent))

(defvar copilot-ide-agent)
(defvar copilot-ide-agents)
(defvar copilot-ide-cli-path)
(defvar copilot-ide-debug)
(defvar copilot-ide-window-side)
(defvar copilot-ide-window-width)
(defvar copilot-ide-window-height)
(defvar copilot-ide-focus-on-open)
(defvar copilot-ide-use-side-window)
(defvar copilot-ide-cli-extra-flags)

;;; Helper Functions

(defun copilot-ide--session-status ()
  "Return a string describing the session of the current project."
  (if-let* ((session (copilot-ide--current-session)))
      (propertize (format "Active session: %s" (copilot-ide--session-label session))
                  'face 'success)
    (propertize (format "No active session (agent: %s)" (copilot-ide--agent-name))
                'face 'transient-inactive-value)))

(defun copilot-ide--describe-start (label)
  "Return LABEL, dimmed when a session is already running."
  (if (copilot-ide--current-session)
      (propertize (concat label " (session already running)")
                  'face 'transient-inactive-value)
    label))

(defmacro copilot-ide--define-start-command (name command)
  "Define NAME, which runs COMMAND unless a session is running."
  `(defun ,name ()
     ,(format "Run `%s' unless the project already has a session." command)
     (interactive)
     (if-let* ((session (copilot-ide--current-session)))
         (message "Session already running: %s" (copilot-ide--session-label session))
       (call-interactively #',command))))

(copilot-ide--define-start-command copilot-ide--start-if-no-session copilot-ide)
(copilot-ide--define-start-command copilot-ide--continue-if-no-session copilot-ide-continue)
(copilot-ide--define-start-command copilot-ide--resume-if-no-session copilot-ide-resume)

(defun copilot-ide-show-version-info ()
  "Show version information for the agent CLI."
  (interactive)
  (if (copilot-ide--cli-available-p)
      (let ((output (with-temp-buffer
                      (call-process (copilot-ide--program) nil t nil "--version")
                      (buffer-string))))
        (with-output-to-temp-buffer "*copilot-ide version*"
          (princ (format "%s CLI version\n\n%s\nExecutable: %s\n"
                         (copilot-ide--agent-name) output
                         (executable-find (copilot-ide--program))))))
    (user-error "%s CLI not available" (copilot-ide--agent-name))))

(defun copilot-ide-toggle-debug-mode ()
  "Toggle Emacs-side debug logging."
  (interactive)
  (setq copilot-ide-debug (not copilot-ide-debug))
  (message "copilot-ide debug mode %s" (if copilot-ide-debug "enabled" "disabled")))

;;; Transient Suffix Definitions

(transient-define-suffix copilot-ide--set-agent (agent)
  "Set the agent that new sessions run."
  :description (lambda () (format "Agent (%s)" copilot-ide-agent))
  (interactive (list (intern (completing-read
                              "Agent: "
                              (mapcar (lambda (a) (symbol-name (car a))) copilot-ide-agents)
                              nil t nil nil (symbol-name copilot-ide-agent)))))
  (setq copilot-ide-agent agent)
  (message "Agent set to %s" agent))

(transient-define-suffix copilot-ide--set-window-side (side)
  "Set which side the session window appears on."
  :description "Set window side"
  (interactive (list (intern (completing-read "Window side: "
                                              '("left" "right" "top" "bottom")
                                              nil t nil nil
                                              (symbol-name copilot-ide-window-side)))))
  (setq copilot-ide-window-side side)
  (message "Window side set to %s" side))

(transient-define-suffix copilot-ide--set-window-width (width)
  "Set the session window width."
  :description "Set window width"
  (interactive (list (read-number "Window width: " copilot-ide-window-width)))
  (setq copilot-ide-window-width width)
  (message "Window width set to %d" width))

(transient-define-suffix copilot-ide--set-window-height (height)
  "Set the session window height."
  :description "Set window height"
  (interactive (list (read-number "Window height: " copilot-ide-window-height)))
  (setq copilot-ide-window-height height)
  (message "Window height set to %d" height))

(transient-define-suffix copilot-ide--set-cli-path (path)
  "Set the agent executable path (empty input resets to the default)."
  :description "Set CLI path"
  (interactive (list (let ((path (read-file-name "Agent CLI path (empty for default): "
                                                 nil "" nil)))
                       (unless (string-empty-p path) path))))
  (setq copilot-ide-cli-path path)
  (message "CLI path set to %s" (or path "the agent default")))

(transient-define-suffix copilot-ide--set-cli-extra-flags (flags)
  "Set additional CLI flags to pass to the agent."
  :description "Set extra CLI flags"
  (interactive (list (read-string "Additional CLI flags: " copilot-ide-cli-extra-flags)))
  (setq copilot-ide-cli-extra-flags flags)
  (message "CLI extra flags set to: %s" flags))

(transient-define-suffix copilot-ide--toggle-focus-on-open ()
  "Toggle whether the session window is focused when opened."
  (interactive)
  (setq copilot-ide-focus-on-open (not copilot-ide-focus-on-open))
  (message "Focus on open %s" (if copilot-ide-focus-on-open "enabled" "disabled")))

(transient-define-suffix copilot-ide--toggle-use-side-window ()
  "Toggle use of a dedicated side window."
  (interactive)
  (setq copilot-ide-use-side-window (not copilot-ide-use-side-window))
  (message "Use side window %s" (if copilot-ide-use-side-window "enabled" "disabled")))

(defun copilot-ide--save-config ()
  "Persist current configuration via customize."
  (interactive)
  (customize-save-variable 'copilot-ide-agent copilot-ide-agent)
  (customize-save-variable 'copilot-ide-window-side copilot-ide-window-side)
  (customize-save-variable 'copilot-ide-window-width copilot-ide-window-width)
  (customize-save-variable 'copilot-ide-window-height copilot-ide-window-height)
  (customize-save-variable 'copilot-ide-focus-on-open copilot-ide-focus-on-open)
  (customize-save-variable 'copilot-ide-use-side-window copilot-ide-use-side-window)
  (customize-save-variable 'copilot-ide-cli-path copilot-ide-cli-path)
  (customize-save-variable 'copilot-ide-cli-extra-flags copilot-ide-cli-extra-flags)
  (message "Configuration saved"))

;;; Transient Menus

;;;###autoload (autoload 'copilot-ide-menu "copilot-ide-transient" "Agent session menu." t)
(transient-define-prefix copilot-ide-menu ()
  "Agent session menu."
  [:description copilot-ide--session-status]
  ["Agent"
   ["Session"
    ("s" copilot-ide--start-if-no-session
     :description (lambda () (copilot-ide--describe-start "Start new session")))
    ("c" copilot-ide--continue-if-no-session
     :description (lambda () (copilot-ide--describe-start "Continue most recent session")))
    ("r" copilot-ide--resume-if-no-session
     :description (lambda () (copilot-ide--describe-start "Resume previous session")))
    ("a" "Start a specific agent" copilot-ide-start-agent)
    ("q" "Stop current session" copilot-ide-stop)
    ("l" "List all sessions" copilot-ide-list-sessions)]
   ["Navigation"
    ("b" "Switch to session buffer" copilot-ide-switch-to-buffer)
    ("w" "Toggle window" copilot-ide-toggle)
    ("W" "Toggle recent window" copilot-ide-toggle-recent)]
   ["Interaction"
    ("p" "Send prompt from minibuffer" copilot-ide-send-prompt)
    ("e" "Send escape key" copilot-ide-send-escape)
    ("n" "Insert newline" copilot-ide-insert-newline)]
   ["Submenus"
    ("C" "Configuration" copilot-ide-config-menu)
    ("d" "Debugging" copilot-ide-debug-menu)]])

(transient-define-prefix copilot-ide-config-menu ()
  "Configuration menu."
  ["Configuration"
   ["Window Settings"
    ("s" "Set window side" copilot-ide--set-window-side)
    ("w" "Set window width" copilot-ide--set-window-width)
    ("h" "Set window height" copilot-ide--set-window-height)
    ("f" "Toggle focus on open" copilot-ide--toggle-focus-on-open
     :description (lambda () (format "Focus on open (%s)"
                                     (if copilot-ide-focus-on-open "ON" "OFF"))))
    ("u" "Toggle side window" copilot-ide--toggle-use-side-window
     :description (lambda () (format "Use side window (%s)"
                                     (if copilot-ide-use-side-window "ON" "OFF"))))]
   ["CLI Settings"
    ("a" copilot-ide--set-agent)
    ("p" "Set CLI path" copilot-ide--set-cli-path)
    ("x" "Set extra CLI flags" copilot-ide--set-cli-extra-flags)]]
  ["Save"
   ("S" "Save configuration" copilot-ide--save-config)])

(transient-define-prefix copilot-ide-debug-menu ()
  "Debug menu."
  ["Debug"
   ["Status"
    ("S" "Check CLI status" copilot-ide-check-status)
    ("v" "Show version info" copilot-ide-show-version-info)]
   ["Debug Logging"
    ("d" "Toggle debug mode" copilot-ide-toggle-debug-mode
     :description (lambda () (format "Debug mode (%s)"
                                     (if copilot-ide-debug "ON" "OFF"))))
    ("l" "Show debug log" copilot-ide-show-debug)
    ("c" "Clear debug log" copilot-ide-clear-debug)]])

(provide 'copilot-ide-transient)

;;; copilot-ide-transient.el ends here
