;;; copilot-cli-debug.el --- Debug logging for Copilot CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, copilot, mcp, debug

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

;; Debug logging functionality for copilot-cli.el.

;;; Code:

(require 'project)

;;; Customization

(defcustom copilot-cli-debug nil
  "When non-nil, enable debug logging for Copilot CLI."
  :type 'boolean
  :group 'copilot-cli)

(defcustom copilot-cli-log-with-context t
  "When non-nil, include project context in log messages."
  :type 'boolean
  :group 'copilot-cli)

(defcustom copilot-cli-debug-buffer "*copilot-cli-debug*"
  "Buffer name for debug output."
  :type 'string
  :group 'copilot-cli)

;;; Debug Functions

(defun copilot-cli--get-session-context ()
  "Get current session context for logging."
  (if copilot-cli-log-with-context
      (format "[%s]" (or (ignore-errors
                           (file-name-nondirectory
                            (directory-file-name
                             (project-root (project-current)))))
                         "no-project"))
    ""))

(defmacro copilot-cli-debug (format-string &rest args)
  "Log debug message with FORMAT-STRING and ARGS if debug is enabled."
  `(when copilot-cli-debug
     (let ((message (format ,format-string ,@args))
           (timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
           (context (copilot-cli--get-session-context)))
       (with-current-buffer (get-buffer-create copilot-cli-debug-buffer)
         (goto-char (point-max))
         (insert (format "%s %s%s\n" timestamp context message))))))

(defun copilot-cli-log (format-string &rest args)
  "Log message with FORMAT-STRING and ARGS."
  (let ((message (apply #'format format-string args)))
    (message "%s %s" (copilot-cli--get-session-context) message)))

;;;###autoload
(defun copilot-cli-show-debug ()
  "Show the debug buffer."
  (interactive)
  (display-buffer (get-buffer-create copilot-cli-debug-buffer)))

;;;###autoload
(defun copilot-cli-clear-debug ()
  "Clear the debug buffer."
  (interactive)
  (with-current-buffer (get-buffer-create copilot-cli-debug-buffer)
    (erase-buffer)
    (message "Debug buffer cleared")))

(provide 'copilot-cli-debug)

;;; copilot-cli-debug.el ends here
