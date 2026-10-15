;;; agent-term-transient.el --- Transient menus for agent-term  -*- lexical-binding: t; -*-

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

;; Transient menus for agent-term.el.

;;; Code:

(require 'transient)
(require 'agent-term-debug)

(declare-function agent-term "agent-term" ())
(declare-function agent-term-continue "agent-term" ())
(declare-function agent-term-resume "agent-term" (&optional session-id))
(declare-function agent-term-start-agent "agent-term" (agent))
(declare-function agent-term-stop "agent-term" ())
(declare-function agent-term-list-sessions "agent-term" ())
(declare-function agent-term-switch-to-buffer "agent-term" ())
(declare-function agent-term-send-prompt "agent-term" (&optional prompt))
(declare-function agent-term-send-escape "agent-term" ())
(declare-function agent-term-insert-newline "agent-term" ())
(declare-function agent-term-toggle "agent-term" ())
(declare-function agent-term-toggle-recent "agent-term" ())
(declare-function agent-term-check-status "agent-term" ())
(declare-function agent-term--current-session "agent-term" ())
(declare-function agent-term--session-label "agent-term" (session))
(declare-function agent-term--agent-name "agent-term" (&optional agent))
(declare-function agent-term--program "agent-term" (&optional agent))
(declare-function agent-term--cli-available-p "agent-term" (&optional agent))

(defvar agent-term-agent)
(defvar agent-term-agents)
(defvar agent-term-cli-path)
(defvar agent-term-debug)
(defvar agent-term-window-side)
(defvar agent-term-window-width)
(defvar agent-term-window-height)
(defvar agent-term-focus-on-open)
(defvar agent-term-use-side-window)
(defvar agent-term-cli-extra-flags)

;;; Helper Functions

(defun agent-term--session-status ()
  "Return a string describing the session of the current project."
  (if-let* ((session (agent-term--current-session)))
      (propertize (format "Active session: %s" (agent-term--session-label session))
                  'face 'success)
    (propertize (format "No active session (agent: %s)" (agent-term--agent-name))
                'face 'transient-inactive-value)))

(defun agent-term--describe-start (label)
  "Return LABEL, dimmed when a session is already running."
  (if (agent-term--current-session)
      (propertize (concat label " (session already running)")
                  'face 'transient-inactive-value)
    label))

(defmacro agent-term--define-start-command (name command)
  "Define NAME, which runs COMMAND unless a session is running."
  `(defun ,name ()
     ,(format "Run `%s' unless the project already has a session." command)
     (interactive)
     (if-let* ((session (agent-term--current-session)))
         (message "Session already running: %s" (agent-term--session-label session))
       (call-interactively #',command))))

(agent-term--define-start-command agent-term--start-if-no-session agent-term)
(agent-term--define-start-command agent-term--continue-if-no-session agent-term-continue)
(agent-term--define-start-command agent-term--resume-if-no-session agent-term-resume)

(defun agent-term-show-version-info ()
  "Show version information for the agent CLI."
  (interactive)
  (if (agent-term--cli-available-p)
      (let ((output (with-temp-buffer
                      (call-process (agent-term--program) nil t nil "--version")
                      (buffer-string))))
        (with-output-to-temp-buffer "*agent-term version*"
          (princ (format "%s CLI version\n\n%s\nExecutable: %s\n"
                         (agent-term--agent-name) output
                         (executable-find (agent-term--program))))))
    (user-error "%s CLI not available" (agent-term--agent-name))))

(defun agent-term-toggle-debug-mode ()
  "Toggle Emacs-side debug logging."
  (interactive)
  (setq agent-term-debug (not agent-term-debug))
  (message "agent-term debug mode %s" (if agent-term-debug "enabled" "disabled")))

;;; Transient Suffix Definitions

(transient-define-suffix agent-term--set-agent (agent)
  "Set the agent that new sessions run."
  :description (lambda () (format "Agent (%s)" agent-term-agent))
  (interactive (list (intern (completing-read
                              "Agent: "
                              (mapcar (lambda (a) (symbol-name (car a))) agent-term-agents)
                              nil t nil nil (symbol-name agent-term-agent)))))
  (setq agent-term-agent agent)
  (message "Agent set to %s" agent))

(transient-define-suffix agent-term--set-window-side (side)
  "Set which side the session window appears on."
  :description "Set window side"
  (interactive (list (intern (completing-read "Window side: "
                                              '("left" "right" "top" "bottom")
                                              nil t nil nil
                                              (symbol-name agent-term-window-side)))))
  (setq agent-term-window-side side)
  (message "Window side set to %s" side))

(transient-define-suffix agent-term--set-window-width (width)
  "Set the session window width."
  :description "Set window width"
  (interactive (list (read-number "Window width: " agent-term-window-width)))
  (setq agent-term-window-width width)
  (message "Window width set to %d" width))

(transient-define-suffix agent-term--set-window-height (height)
  "Set the session window height."
  :description "Set window height"
  (interactive (list (read-number "Window height: " agent-term-window-height)))
  (setq agent-term-window-height height)
  (message "Window height set to %d" height))

(transient-define-suffix agent-term--set-cli-path (path)
  "Set the agent executable path (empty input resets to the default)."
  :description "Set CLI path"
  (interactive (list (let ((path (read-file-name "Agent CLI path (empty for default): "
                                                 nil "" nil)))
                       (unless (string-empty-p path) path))))
  (setq agent-term-cli-path path)
  (message "CLI path set to %s" (or path "the agent default")))

(transient-define-suffix agent-term--set-cli-extra-flags (flags)
  "Set additional CLI flags to pass to the agent."
  :description "Set extra CLI flags"
  (interactive (list (read-string "Additional CLI flags: " agent-term-cli-extra-flags)))
  (setq agent-term-cli-extra-flags flags)
  (message "CLI extra flags set to: %s" flags))

(transient-define-suffix agent-term--toggle-focus-on-open ()
  "Toggle whether the session window is focused when opened."
  (interactive)
  (setq agent-term-focus-on-open (not agent-term-focus-on-open))
  (message "Focus on open %s" (if agent-term-focus-on-open "enabled" "disabled")))

(transient-define-suffix agent-term--toggle-use-side-window ()
  "Toggle use of a dedicated side window."
  (interactive)
  (setq agent-term-use-side-window (not agent-term-use-side-window))
  (message "Use side window %s" (if agent-term-use-side-window "enabled" "disabled")))

(defun agent-term--save-config ()
  "Persist current configuration via customize."
  (interactive)
  (customize-save-variable 'agent-term-agent agent-term-agent)
  (customize-save-variable 'agent-term-window-side agent-term-window-side)
  (customize-save-variable 'agent-term-window-width agent-term-window-width)
  (customize-save-variable 'agent-term-window-height agent-term-window-height)
  (customize-save-variable 'agent-term-focus-on-open agent-term-focus-on-open)
  (customize-save-variable 'agent-term-use-side-window agent-term-use-side-window)
  (customize-save-variable 'agent-term-cli-path agent-term-cli-path)
  (customize-save-variable 'agent-term-cli-extra-flags agent-term-cli-extra-flags)
  (message "Configuration saved"))

;;; Transient Menus

;;;###autoload (autoload 'agent-term-menu "agent-term-transient" "Agent session menu." t)
(transient-define-prefix agent-term-menu ()
  "Agent session menu."
  [:description agent-term--session-status]
  ["Agent"
   ["Session"
    ("s" agent-term--start-if-no-session
     :description (lambda () (agent-term--describe-start "Start new session")))
    ("c" agent-term--continue-if-no-session
     :description (lambda () (agent-term--describe-start "Continue most recent session")))
    ("r" agent-term--resume-if-no-session
     :description (lambda () (agent-term--describe-start "Resume previous session")))
    ("a" "Start a specific agent" agent-term-start-agent)
    ("q" "Stop current session" agent-term-stop)
    ("l" "List all sessions" agent-term-list-sessions)]
   ["Navigation"
    ("b" "Switch to session buffer" agent-term-switch-to-buffer)
    ("w" "Toggle window" agent-term-toggle)
    ("W" "Toggle recent window" agent-term-toggle-recent)]
   ["Interaction"
    ("p" "Send prompt from minibuffer" agent-term-send-prompt)
    ("e" "Send escape key" agent-term-send-escape)
    ("n" "Insert newline" agent-term-insert-newline)]
   ["Submenus"
    ("C" "Configuration" agent-term-config-menu)
    ("d" "Debugging" agent-term-debug-menu)]])

(transient-define-prefix agent-term-config-menu ()
  "Configuration menu."
  ["Configuration"
   ["Window Settings"
    ("s" "Set window side" agent-term--set-window-side)
    ("w" "Set window width" agent-term--set-window-width)
    ("h" "Set window height" agent-term--set-window-height)
    ("f" "Toggle focus on open" agent-term--toggle-focus-on-open
     :description (lambda () (format "Focus on open (%s)"
                                     (if agent-term-focus-on-open "ON" "OFF"))))
    ("u" "Toggle side window" agent-term--toggle-use-side-window
     :description (lambda () (format "Use side window (%s)"
                                     (if agent-term-use-side-window "ON" "OFF"))))]
   ["CLI Settings"
    ("a" agent-term--set-agent)
    ("p" "Set CLI path" agent-term--set-cli-path)
    ("x" "Set extra CLI flags" agent-term--set-cli-extra-flags)]]
  ["Save"
   ("S" "Save configuration" agent-term--save-config)])

(transient-define-prefix agent-term-debug-menu ()
  "Debug menu."
  ["Debug"
   ["Status"
    ("S" "Check CLI status" agent-term-check-status)
    ("v" "Show version info" agent-term-show-version-info)]
   ["Debug Logging"
    ("d" "Toggle debug mode" agent-term-toggle-debug-mode
     :description (lambda () (format "Debug mode (%s)"
                                     (if agent-term-debug "ON" "OFF"))))
    ("l" "Show debug log" agent-term-show-debug)
    ("c" "Clear debug log" agent-term-clear-debug)]])

(provide 'agent-term-transient)

;;; agent-term-transient.el ends here
