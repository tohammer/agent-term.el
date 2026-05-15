;;; copilot-ide-diagnostics.el --- Flycheck/Flymake diagnostics MCP tool  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Tobias Hammer
;; Copyright (C) 2025 Yoav Orot

;; Based on claude-code-ide.el by Yoav Orot (manzaltu)
;; https://github.com/manzaltu/claude-code-ide.el

;; Keywords: ai, copilot, diagnostics, flycheck, flymake
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

;; Flycheck and Flymake diagnostic collection for copilot-ide.el.
;;
;; Exposes a `get_diagnostics' MCP tool that Copilot can call to retrieve
;; current errors and warnings from open buffers.  Supports both Flycheck
;; and Flymake, with automatic backend detection.
;;
;; Unlike the original claude-code-ide.el, where getDiagnostics was pushed
;; over a WebSocket IDE channel, here it is a plain pull-based MCP tool
;; served over the HTTP MCP server — semantically identical, simpler transport.

;;; Code:

(require 'cl-lib)
(require 'copilot-ide-debug)
(require 'copilot-ide-mcp-server)

(require 'flycheck nil t)
(require 'flymake nil t)

;; Flycheck declarations
(defvar flycheck-current-errors)
(declare-function flycheck-error-line "flycheck" (err))
(declare-function flycheck-error-column "flycheck" (err))
(declare-function flycheck-error-end-line "flycheck" (err))
(declare-function flycheck-error-end-column "flycheck" (err))
(declare-function flycheck-error-level "flycheck" (err))
(declare-function flycheck-error-checker "flycheck" (err))
(declare-function flycheck-error-message "flycheck" (err))

;;; Customization

(defcustom copilot-ide-diagnostics-backend 'auto
  "Backend to use for collecting diagnostics.
- `auto'     Prefer flycheck if active, fall back to flymake.
- `flycheck' Always use flycheck.
- `flymake'  Always use flymake."
  :type '(choice (const :tag "Automatic" auto)
                 (const :tag "Flycheck" flycheck)
                 (const :tag "Flymake" flymake))
  :group 'copilot-ide)

;;; Internal: Severity Conversion

(defun copilot-ide-diagnostics--severity-string (severity)
  "Convert diagnostic SEVERITY symbol to a human-readable string."
  (pcase severity
    ((or 'error ':error 'flymake-error) "Error")
    ((or 'warning ':warning 'flymake-warning) "Warning")
    ((or 'info ':note 'flymake-note) "Information")
    ('hint "Hint")
    (_ "Information")))

;;; Internal: Backend Collection

(defun copilot-ide-diagnostics--flycheck (buffer)
  "Return Flycheck diagnostics for BUFFER as a list of plists, or nil."
  (when (featurep 'flycheck)
    (with-current-buffer buffer
      (when (bound-and-true-p flycheck-mode)
        (mapcar (lambda (err)
                  (list :line (flycheck-error-line err)
                        :column (or (flycheck-error-column err) 1)
                        :end-line (or (flycheck-error-end-line err)
                                      (flycheck-error-line err))
                        :end-column (or (flycheck-error-end-column err)
                                        (flycheck-error-column err) 1)
                        :severity (copilot-ide-diagnostics--severity-string
                                   (flycheck-error-level err))
                        :source (format "%s" (or (flycheck-error-checker err) 'flycheck))
                        :message (flycheck-error-message err)))
                flycheck-current-errors)))))

(defun copilot-ide-diagnostics--flymake (buffer)
  "Return Flymake diagnostics for BUFFER as a list of plists, or nil."
  (when (featurep 'flymake)
    (with-current-buffer buffer
      (when (bound-and-true-p flymake-mode)
        (mapcar (lambda (diag)
                  (save-excursion
                    (let* ((beg (flymake-diagnostic-beg diag))
                           (end (flymake-diagnostic-end diag))
                           (beg-line (progn (goto-char beg) (line-number-at-pos)))
                           (beg-col  (current-column))
                           (end-line (progn (goto-char end) (line-number-at-pos)))
                           (end-col  (current-column)))
                      (list :line beg-line
                            :column beg-col
                            :end-line end-line
                            :end-column end-col
                            :severity (copilot-ide-diagnostics--severity-string
                                       (flymake-diagnostic-type diag))
                            :source (format "%s" (or (flymake-diagnostic-backend diag)
                                                     'flymake))
                            :message (flymake-diagnostic-text diag)))))
                (flymake-diagnostics))))))

(defun copilot-ide-diagnostics--collect (buffer)
  "Return diagnostics for BUFFER using the configured backend."
  (let ((backend copilot-ide-diagnostics-backend))
    (when (eq backend 'auto)
      (setq backend
            (with-current-buffer buffer
              (cond
               ((and (featurep 'flycheck) (bound-and-true-p flycheck-mode)) 'flycheck)
               ((and (featurep 'flymake)  (bound-and-true-p flymake-mode))  'flymake)
               (t nil)))))
    (pcase backend
      ('flycheck (copilot-ide-diagnostics--flycheck buffer))
      ('flymake  (copilot-ide-diagnostics--flymake  buffer))
      (_ nil))))

;;; Internal: Formatting

(defun copilot-ide-diagnostics--format-one (file-path diags)
  "Format DIAGS for FILE-PATH as a readable string block."
  (let ((lines (list (format "=== %s ===" file-path))))
    (dolist (d diags)
      (push (format "  [%s] line %d col %d: %s (%s)"
                    (plist-get d :severity)
                    (plist-get d :line)
                    (plist-get d :column)
                    (plist-get d :message)
                    (plist-get d :source))
            lines))
    (string-join (nreverse lines) "\n")))

;;; Public: MCP Tool Function

(defun copilot-ide-get-diagnostics (&optional file-path)
  "Return diagnostics from Flycheck/Flymake for FILE-PATH (or all project files).
When FILE-PATH is nil or empty, all open buffers that belong to the current
MCP session's project are checked.
Returns a formatted string suitable for Copilot's context window."
  (copilot-ide-mcp-server-with-session-context nil
    (let* ((context (copilot-ide-mcp-server-get-session-context))
           (project-dir (plist-get context :project-dir))
           (results '()))
      (if (and file-path (not (string-empty-p file-path)))
          ;; Single file
          (let ((buffer (or (find-buffer-visiting file-path)
                            (find-file-noselect file-path))))
            (when buffer
              (let ((diags (copilot-ide-diagnostics--collect buffer)))
                (if diags
                    (push (copilot-ide-diagnostics--format-one file-path diags) results)
                  (push (format "No diagnostics for %s" file-path) results)))))
        ;; All open project buffers
        (dolist (buffer (buffer-list))
          (when-let* ((file (buffer-file-name buffer))
                      ;; Only include buffers in the current project
                      ((or (not project-dir)
                           (string-prefix-p (expand-file-name project-dir)
                                            (expand-file-name file)))))
            (let ((diags (copilot-ide-diagnostics--collect buffer)))
              (when diags
                (push (copilot-ide-diagnostics--format-one file diags) results)))))
        (unless results
          (push (format "No diagnostics found%s"
                        (if project-dir (format " in project %s" project-dir) ""))
                results)))
      (string-join (nreverse results) "\n\n"))))

;;; Tool Registration

;;;###autoload
(defun copilot-ide-diagnostics-setup ()
  "Register the get_diagnostics MCP tool.
This is called automatically by `copilot-ide-emacs-tools-setup'."
  (copilot-ide-make-tool
   :function #'copilot-ide-get-diagnostics
   :name "copilot_cli_get_diagnostics"
   :description (concat "Get current errors and warnings from Flycheck or Flymake "
                         "for a specific file or all open project files. "
                         "Returns severity, line/column, message, and checker source.")
   :args '((:name "file_path"
                  :type string
                  :description "File to get diagnostics for.  Omit to check all open project files."
                  :optional t))))

(provide 'copilot-ide-diagnostics)

;;; copilot-ide-diagnostics.el ends here
