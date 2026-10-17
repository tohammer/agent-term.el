;;; agent-term-debug.el --- Debug logging for agent-term  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Tobias Hammer
;; Copyright (C) 2025 Yoav Orot

;; Based on claude-code-ide.el by Yoav Orot (manzaltu)
;; https://github.com/manzaltu/claude-code-ide.el

;; Keywords: tools, ai, mcp, debug
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

;; Debug logging functionality for agent-term.el.

;;; Code:

(require 'project)

;;; Customization

(defcustom agent-term-debug nil
  "When non-nil, enable debug logging."
  :type 'boolean
  :group 'agent-term)

(defcustom agent-term-log-with-context t
  "When non-nil, include project context in log messages."
  :type 'boolean
  :group 'agent-term)

(defcustom agent-term-debug-buffer "*agent-term-debug*"
  "Buffer name for debug output."
  :type 'string
  :group 'agent-term)

;;; Debug Functions

(defun agent-term--get-session-context ()
  "Get current session context for logging."
  (if agent-term-log-with-context
      (format "[%s]" (or (ignore-errors
                           (file-name-nondirectory
                            (directory-file-name
                             (project-root (project-current)))))
                         "no-project"))
    ""))

(defmacro agent-term-debug (format-string &rest args)
  "Log debug message with FORMAT-STRING and ARGS if debug is enabled."
  `(when agent-term-debug
     (let ((message (format ,format-string ,@args))
           (timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
           (context (agent-term--get-session-context)))
       (with-current-buffer (get-buffer-create agent-term-debug-buffer)
         (goto-char (point-max))
         (insert (format "%s %s%s\n" timestamp context message))))))

(defun agent-term-log (format-string &rest args)
  "Log message with FORMAT-STRING and ARGS."
  (let ((message (apply #'format format-string args)))
    (message "%s %s" (agent-term--get-session-context) message)))

;;;###autoload
(defun agent-term-show-debug ()
  "Show the debug buffer."
  (interactive)
  (display-buffer (get-buffer-create agent-term-debug-buffer)))

;;;###autoload
(defun agent-term-clear-debug ()
  "Clear the debug buffer."
  (interactive)
  (with-current-buffer (get-buffer-create agent-term-debug-buffer)
    (erase-buffer)
    (message "Debug buffer cleared")))

(provide 'agent-term-debug)

;;; agent-term-debug.el ends here
