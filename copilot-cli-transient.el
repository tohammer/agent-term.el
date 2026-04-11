;;; copilot-cli-transient.el --- Transient menus for Copilot CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, copilot, transient, menu

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

;; Transient menus for copilot-cli.el.

;;; Code:

(require 'transient)
(require 'copilot-cli-debug)

(declare-function copilot-cli "copilot-cli" ())
(declare-function copilot-cli-continue "copilot-cli" ())
(declare-function copilot-cli-resume "copilot-cli" (&optional session-id))
(declare-function copilot-cli-stop "copilot-cli" ())
(declare-function copilot-cli-list-sessions "copilot-cli" ())
(declare-function copilot-cli-switch-to-buffer "copilot-cli" ())
(declare-function copilot-cli-send-prompt "copilot-cli" ())
(declare-function copilot-cli-send-escape "copilot-cli" ())
(declare-function copilot-cli-insert-newline "copilot-cli" ())
(declare-function copilot-cli-toggle "copilot-cli" ())
(declare-function copilot-cli-toggle-recent "copilot-cli" ())
(declare-function copilot-cli-check-status "copilot-cli" ())
(declare-function copilot-cli--ensure-cli "copilot-cli" ())
(declare-function copilot-cli--get-working-directory "copilot-cli" ())
(declare-function copilot-cli--get-process "copilot-cli" ())

(defvar copilot-cli-cli-path)
(defvar copilot-cli-debug)
(defvar copilot-cli-window-side)
(defvar copilot-cli-window-width)
(defvar copilot-cli-window-height)
(defvar copilot-cli-focus-on-open)
(defvar copilot-cli-use-side-window)
(defvar copilot-cli-cli-extra-flags)

;;; Helper Functions

(defun copilot-cli--has-active-session-p ()
  "Return non-nil if there is an active Copilot session for the current project."
  (when (copilot-cli--get-process) t))

(defun copilot-cli--start-description ()
  "Dynamic description for start command."
  (if (copilot-cli--has-active-session-p)
      (propertize "Start new Copilot session (session already running)"
                  'face 'transient-inactive-value)
    "Start new Copilot session"))

(defun copilot-cli--start-if-no-session ()
  "Start Copilot only if no session is active for the current project."
  (interactive)
  (if (copilot-cli--has-active-session-p)
      (message "[%s] Copilot session already running"
               (file-name-nondirectory
                (directory-file-name (copilot-cli--get-working-directory))))
    (copilot-cli)))

(defun copilot-cli--continue-description ()
  "Dynamic description for continue command."
  (if (copilot-cli--has-active-session-p)
      (propertize "Continue most recent session (session already running)"
                  'face 'transient-inactive-value)
    "Continue most recent session"))

(defun copilot-cli--continue-if-no-session ()
  "Continue most recent Copilot session only if no session is active."
  (interactive)
  (if (copilot-cli--has-active-session-p)
      (message "[%s] Copilot session already running"
               (file-name-nondirectory
                (directory-file-name (copilot-cli--get-working-directory))))
    (copilot-cli-continue)))

(defun copilot-cli--resume-description ()
  "Dynamic description for resume command."
  (if (copilot-cli--has-active-session-p)
      (propertize "Resume previous session (session already running)"
                  'face 'transient-inactive-value)
    "Resume previous session"))

(defun copilot-cli--resume-if-no-session ()
  "Resume a previous Copilot session only if no session is active."
  (interactive)
  (if (copilot-cli--has-active-session-p)
      (message "[%s] Copilot session already running"
               (file-name-nondirectory
                (directory-file-name (copilot-cli--get-working-directory))))
    (copilot-cli-resume)))

  "Return a string describing the current session status."
  (if (copilot-cli--has-active-session-p)
      (propertize (format "Active session in [%s]"
                          (file-name-nondirectory
                           (directory-file-name (copilot-cli--get-working-directory))))
                  'face 'success)
    (propertize "No active session" 'face 'transient-inactive-value)))

(defun copilot-cli-show-version-info ()
  "Show version information for the Copilot CLI."
  (interactive)
  (if (copilot-cli--ensure-cli)
      (let ((output (with-temp-buffer
                      (call-process copilot-cli-cli-path nil t nil "--version")
                      (buffer-string))))
        (with-output-to-temp-buffer "*Copilot CLI Version*"
          (princ "Copilot CLI Version Information\n")
          (princ "================================\n\n")
          (princ output)
          (princ "\n\nExecutable path: ")
          (princ (executable-find copilot-cli-cli-path))))
    (user-error "Copilot CLI not available")))

(defun copilot-cli-toggle-debug-mode ()
  "Toggle Emacs-side debug logging."
  (interactive)
  (setq copilot-cli-debug (not copilot-cli-debug))
  (message "Copilot CLI debug mode %s" (if copilot-cli-debug "enabled" "disabled")))

;;; Transient Suffix Definitions

(transient-define-suffix copilot-cli--set-window-side (side)
  "Set which side the Copilot window appears on."
  :description "Set window side"
  (interactive (list (intern (completing-read "Window side: "
                                              '("left" "right" "top" "bottom")
                                              nil t nil nil
                                              (symbol-name copilot-cli-window-side)))))
  (setq copilot-cli-window-side side)
  (message "Window side set to %s" side))

(transient-define-suffix copilot-cli--set-window-width (width)
  "Set Copilot window width."
  :description "Set window width"
  (interactive (list (read-number "Window width: " copilot-cli-window-width)))
  (setq copilot-cli-window-width width)
  (message "Window width set to %d" width))

(transient-define-suffix copilot-cli--set-window-height (height)
  "Set Copilot window height."
  :description "Set window height"
  (interactive (list (read-number "Window height: " copilot-cli-window-height)))
  (setq copilot-cli-window-height height)
  (message "Window height set to %d" height))

(transient-define-suffix copilot-cli--set-cli-path (path)
  "Set the Copilot CLI executable path."
  :description "Set CLI path"
  (interactive (list (read-file-name "Copilot CLI path: " nil copilot-cli-cli-path t)))
  (setq copilot-cli-cli-path path)
  (message "CLI path set to %s" path))

(transient-define-suffix copilot-cli--set-cli-extra-flags (flags)
  "Set additional CLI flags to pass to Copilot."
  :description "Set extra CLI flags"
  (interactive (list (read-string "Additional CLI flags: " copilot-cli-cli-extra-flags)))
  (setq copilot-cli-cli-extra-flags flags)
  (message "CLI extra flags set to: %s" flags))

(transient-define-suffix copilot-cli--toggle-focus-on-open ()
  "Toggle whether the Copilot window is focused when opened."
  (interactive)
  (setq copilot-cli-focus-on-open (not copilot-cli-focus-on-open))
  (message "Focus on open %s" (if copilot-cli-focus-on-open "enabled" "disabled")))

(transient-define-suffix copilot-cli--toggle-use-side-window ()
  "Toggle use of a dedicated side window."
  (interactive)
  (setq copilot-cli-use-side-window (not copilot-cli-use-side-window))
  (message "Use side window %s" (if copilot-cli-use-side-window "enabled" "disabled")))

(defun copilot-cli--save-config ()
  "Persist current configuration via customize."
  (interactive)
  (customize-save-variable 'copilot-cli-window-side copilot-cli-window-side)
  (customize-save-variable 'copilot-cli-window-width copilot-cli-window-width)
  (customize-save-variable 'copilot-cli-window-height copilot-cli-window-height)
  (customize-save-variable 'copilot-cli-focus-on-open copilot-cli-focus-on-open)
  (customize-save-variable 'copilot-cli-use-side-window copilot-cli-use-side-window)
  (customize-save-variable 'copilot-cli-cli-path copilot-cli-cli-path)
  (customize-save-variable 'copilot-cli-cli-extra-flags copilot-cli-cli-extra-flags)
  (message "Configuration saved"))

;;; Transient Menus

;;;###autoload (autoload 'copilot-cli-menu "copilot-cli-transient" "Copilot CLI main menu." t)
(transient-define-prefix copilot-cli-menu ()
  "Copilot CLI main menu."
  [:description copilot-cli--session-status]
  ["Copilot CLI"
   ["Session"
    ("s" copilot-cli--start-if-no-session :description copilot-cli--start-description)
    ("c" copilot-cli--continue-if-no-session :description copilot-cli--continue-description)
    ("r" copilot-cli--resume-if-no-session :description copilot-cli--resume-description)
    ("q" "Stop current session" copilot-cli-stop)
    ("l" "List all sessions" copilot-cli-list-sessions)]
   ["Navigation"
    ("b" "Switch to Copilot buffer" copilot-cli-switch-to-buffer)
    ("w" "Toggle window" copilot-cli-toggle)
    ("W" "Toggle recent window" copilot-cli-toggle-recent)]
   ["Interaction"
    ("p" "Send prompt from minibuffer" copilot-cli-send-prompt)
    ("e" "Send escape key" copilot-cli-send-escape)
    ("n" "Insert newline" copilot-cli-insert-newline)]
   ["Submenus"
    ("C" "Configuration" copilot-cli-config-menu)
    ("d" "Debugging" copilot-cli-debug-menu)]])

(transient-define-prefix copilot-cli-config-menu ()
  "Copilot CLI configuration menu."
  ["Copilot CLI Configuration"
   ["Window Settings"
    ("s" "Set window side" copilot-cli--set-window-side)
    ("w" "Set window width" copilot-cli--set-window-width)
    ("h" "Set window height" copilot-cli--set-window-height)
    ("f" "Toggle focus on open" copilot-cli--toggle-focus-on-open
     :description (lambda () (format "Focus on open (%s)"
                                     (if copilot-cli-focus-on-open "ON" "OFF"))))
    ("u" "Toggle side window" copilot-cli--toggle-use-side-window
     :description (lambda () (format "Use side window (%s)"
                                     (if copilot-cli-use-side-window "ON" "OFF"))))]
   ["CLI Settings"
    ("p" "Set CLI path" copilot-cli--set-cli-path)
    ("x" "Set extra CLI flags" copilot-cli--set-cli-extra-flags)]]
  ["Save"
   ("S" "Save configuration" copilot-cli--save-config)])

(transient-define-prefix copilot-cli-debug-menu ()
  "Copilot CLI debug menu."
  ["Copilot CLI Debug"
   ["Status"
    ("S" "Check CLI status" copilot-cli-check-status)
    ("v" "Show version info" copilot-cli-show-version-info)]
   ["Debug Logging"
    ("d" "Toggle debug mode" copilot-cli-toggle-debug-mode
     :description (lambda () (format "Debug mode (%s)"
                                     (if copilot-cli-debug "ON" "OFF"))))
    ("l" "Show debug log" copilot-cli-show-debug)
    ("c" "Clear debug log" copilot-cli-clear-debug)]])

(provide 'copilot-cli-transient)

;;; copilot-cli-transient.el ends here
