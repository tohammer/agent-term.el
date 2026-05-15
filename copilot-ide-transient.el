;;; copilot-ide-transient.el --- Transient menus for Copilot CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Tobias Hammer
;; Copyright (C) 2025 Yoav Orot

;; Based on claude-code-ide.el by Yoav Orot (manzaltu)
;; https://github.com/manzaltu/claude-code-ide.el

;; Keywords: ai, copilot, transient, menu
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
(declare-function copilot-ide-stop "copilot-ide" ())
(declare-function copilot-ide-list-sessions "copilot-ide" ())
(declare-function copilot-ide-switch-to-buffer "copilot-ide" ())
(declare-function copilot-ide-send-prompt "copilot-ide" ())
(declare-function copilot-ide-send-escape "copilot-ide" ())
(declare-function copilot-ide-insert-newline "copilot-ide" ())
(declare-function copilot-ide-toggle "copilot-ide" ())
(declare-function copilot-ide-toggle-recent "copilot-ide" ())
(declare-function copilot-ide-check-status "copilot-ide" ())
(declare-function copilot-ide--ensure-cli "copilot-ide" ())
(declare-function copilot-ide--get-working-directory "copilot-ide" ())
(declare-function copilot-ide--get-process "copilot-ide" ())

(defvar copilot-ide-cli-path)
(defvar copilot-ide-debug)
(defvar copilot-ide-window-side)
(defvar copilot-ide-window-width)
(defvar copilot-ide-window-height)
(defvar copilot-ide-focus-on-open)
(defvar copilot-ide-use-side-window)
(defvar copilot-ide-cli-extra-flags)

;;; Helper Functions

(defun copilot-ide--has-active-session-p ()
  "Return non-nil if there is an active Copilot session for the current project."
  (when (copilot-ide--get-process) t))

(defun copilot-ide--start-description ()
  "Dynamic description for start command."
  (if (copilot-ide--has-active-session-p)
      (propertize "Start new Copilot session (session already running)"
                  'face 'transient-inactive-value)
    "Start new Copilot session"))

(defun copilot-ide--start-if-no-session ()
  "Start Copilot only if no session is active for the current project."
  (interactive)
  (if (copilot-ide--has-active-session-p)
      (message "[%s] Copilot session already running"
               (file-name-nondirectory
                (directory-file-name (copilot-ide--get-working-directory))))
    (copilot-ide)))

(defun copilot-ide--continue-description ()
  "Dynamic description for continue command."
  (if (copilot-ide--has-active-session-p)
      (propertize "Continue most recent session (session already running)"
                  'face 'transient-inactive-value)
    "Continue most recent session"))

(defun copilot-ide--continue-if-no-session ()
  "Continue most recent Copilot session only if no session is active."
  (interactive)
  (if (copilot-ide--has-active-session-p)
      (message "[%s] Copilot session already running"
               (file-name-nondirectory
                (directory-file-name (copilot-ide--get-working-directory))))
    (copilot-ide-continue)))

(defun copilot-ide--resume-description ()
  "Dynamic description for resume command."
  (if (copilot-ide--has-active-session-p)
      (propertize "Resume previous session (session already running)"
                  'face 'transient-inactive-value)
    "Resume previous session"))

(defun copilot-ide--resume-if-no-session ()
  "Resume a previous Copilot session only if no session is active."
  (interactive)
  (if (copilot-ide--has-active-session-p)
      (message "[%s] Copilot session already running"
               (file-name-nondirectory
                (directory-file-name (copilot-ide--get-working-directory))))
    (copilot-ide-resume)))

(defun copilot-ide--session-status ()
  "Return a string describing the current session status."
  (if (copilot-ide--has-active-session-p)
      (propertize (format "Active session in [%s]"
                          (file-name-nondirectory
                           (directory-file-name (copilot-ide--get-working-directory))))
                  'face 'success)
    (propertize "No active session" 'face 'transient-inactive-value)))

(defun copilot-ide-show-version-info ()
  "Show version information for the Copilot CLI."
  (interactive)
  (if (copilot-ide--ensure-cli)
      (let ((output (with-temp-buffer
                      (call-process copilot-ide-cli-path nil t nil "--version")
                      (buffer-string))))
        (with-output-to-temp-buffer "*Copilot CLI Version*"
          (princ "Copilot CLI Version Information\n")
          (princ "================================\n\n")
          (princ output)
          (princ "\n\nExecutable path: ")
          (princ (executable-find copilot-ide-cli-path))))
    (user-error "Copilot CLI not available")))

(defun copilot-ide-toggle-debug-mode ()
  "Toggle Emacs-side debug logging."
  (interactive)
  (setq copilot-ide-debug (not copilot-ide-debug))
  (message "Copilot CLI debug mode %s" (if copilot-ide-debug "enabled" "disabled")))

;;; Transient Suffix Definitions

(transient-define-suffix copilot-ide--set-window-side (side)
  "Set which side the Copilot window appears on."
  :description "Set window side"
  (interactive (list (intern (completing-read "Window side: "
                                              '("left" "right" "top" "bottom")
                                              nil t nil nil
                                              (symbol-name copilot-ide-window-side)))))
  (setq copilot-ide-window-side side)
  (message "Window side set to %s" side))

(transient-define-suffix copilot-ide--set-window-width (width)
  "Set Copilot window width."
  :description "Set window width"
  (interactive (list (read-number "Window width: " copilot-ide-window-width)))
  (setq copilot-ide-window-width width)
  (message "Window width set to %d" width))

(transient-define-suffix copilot-ide--set-window-height (height)
  "Set Copilot window height."
  :description "Set window height"
  (interactive (list (read-number "Window height: " copilot-ide-window-height)))
  (setq copilot-ide-window-height height)
  (message "Window height set to %d" height))

(transient-define-suffix copilot-ide--set-cli-path (path)
  "Set the Copilot CLI executable path."
  :description "Set CLI path"
  (interactive (list (read-file-name "Copilot CLI path: " nil copilot-ide-cli-path t)))
  (setq copilot-ide-cli-path path)
  (message "CLI path set to %s" path))

(transient-define-suffix copilot-ide--set-cli-extra-flags (flags)
  "Set additional CLI flags to pass to Copilot."
  :description "Set extra CLI flags"
  (interactive (list (read-string "Additional CLI flags: " copilot-ide-cli-extra-flags)))
  (setq copilot-ide-cli-extra-flags flags)
  (message "CLI extra flags set to: %s" flags))

(transient-define-suffix copilot-ide--toggle-focus-on-open ()
  "Toggle whether the Copilot window is focused when opened."
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
  (customize-save-variable 'copilot-ide-window-side copilot-ide-window-side)
  (customize-save-variable 'copilot-ide-window-width copilot-ide-window-width)
  (customize-save-variable 'copilot-ide-window-height copilot-ide-window-height)
  (customize-save-variable 'copilot-ide-focus-on-open copilot-ide-focus-on-open)
  (customize-save-variable 'copilot-ide-use-side-window copilot-ide-use-side-window)
  (customize-save-variable 'copilot-ide-cli-path copilot-ide-cli-path)
  (customize-save-variable 'copilot-ide-cli-extra-flags copilot-ide-cli-extra-flags)
  (message "Configuration saved"))

;;; Transient Menus

;;;###autoload (autoload 'copilot-ide-menu "copilot-ide-transient" "Copilot CLI main menu." t)
(transient-define-prefix copilot-ide-menu ()
  "Copilot CLI main menu."
  [:description copilot-ide--session-status]
  ["Copilot CLI"
   ["Session"
    ("s" copilot-ide--start-if-no-session :description copilot-ide--start-description)
    ("c" copilot-ide--continue-if-no-session :description copilot-ide--continue-description)
    ("r" copilot-ide--resume-if-no-session :description copilot-ide--resume-description)
    ("q" "Stop current session" copilot-ide-stop)
    ("l" "List all sessions" copilot-ide-list-sessions)]
   ["Navigation"
    ("b" "Switch to Copilot buffer" copilot-ide-switch-to-buffer)
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
  "Copilot CLI configuration menu."
  ["Copilot CLI Configuration"
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
    ("p" "Set CLI path" copilot-ide--set-cli-path)
    ("x" "Set extra CLI flags" copilot-ide--set-cli-extra-flags)]]
  ["Save"
   ("S" "Save configuration" copilot-ide--save-config)])

(transient-define-prefix copilot-ide-debug-menu ()
  "Copilot CLI debug menu."
  ["Copilot CLI Debug"
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
