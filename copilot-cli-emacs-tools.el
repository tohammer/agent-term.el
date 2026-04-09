;;; copilot-cli-emacs-tools.el --- Emacs MCP tools for Copilot CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, copilot, mcp, tools, xref, emacs

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

;; Emacs-specific MCP tools for Copilot CLI.  Exposes xref, imenu,
;; tree-sitter, and project information through the HTTP MCP server.
;;
;; Call `copilot-cli-emacs-tools-setup' in your init file to enable all tools.

;;; Code:

(require 'copilot-cli-mcp-server)
(require 'copilot-cli-diagnostics)
(require 'xref)
(require 'project)
(require 'cl-lib)
(require 'imenu)

;; Tree-sitter declarations
(declare-function treesit-node-at "treesit" (pos &optional parser-or-lang named))
(declare-function treesit-node-text "treesit" (node &optional no-property))
(declare-function treesit-node-field-name "treesit" (node))

;;; Tool Functions

(defun copilot-cli-mcp-xref-find-references (identifier file-path)
  "Find references to IDENTIFIER using the xref backend for FILE-PATH."
  (if (not file-path)
      (error "file_path parameter is required")
    (copilot-cli-mcp-server-with-session-context nil
      (let ((target-buffer (or (find-buffer-visiting file-path)
                               (find-file-noselect file-path)))
            (identifier-str (format "%s" identifier)))
        (with-current-buffer target-buffer
          (condition-case err
              (let ((backend (xref-find-backend)))
                (if (not backend)
                    (format "No xref backend available for %s" file-path)
                  (let ((xref-items (xref-backend-references backend identifier-str)))
                    (if xref-items
                        (mapcar (lambda (item)
                                  (let* ((location (xref-item-location item))
                                         (file (xref-location-group location))
                                         (marker (xref-location-marker location))
                                         (line (with-current-buffer (marker-buffer marker)
                                                 (save-excursion
                                                   (goto-char marker)
                                                   (line-number-at-pos))))
                                         (summary (xref-item-summary item)))
                                    (format "%s:%d: %s" file line summary)))
                                xref-items)
                      (format "No references found for '%s'" identifier-str)))))
            (error
             (format "Error searching for '%s' in %s: %s"
                     identifier-str file-path (error-message-string err)))))))))

(defun copilot-cli-mcp-xref-find-apropos (pattern file-path)
  "Find symbols matching PATTERN using the xref backend for FILE-PATH."
  (if (not file-path)
      (error "file_path parameter is required")
    (copilot-cli-mcp-server-with-session-context nil
      (let ((target-buffer (or (find-buffer-visiting file-path)
                               (find-file-noselect file-path)))
            (pattern-str (format "%s" pattern)))
        (with-current-buffer target-buffer
          (condition-case err
              (let ((backend (xref-find-backend)))
                (cond
                 ((not backend)
                  (format "No xref backend available for %s" file-path))
                 ((and (eq backend 'etags)
                       (not (or (and (boundp 'tags-file-name) tags-file-name
                                     (file-exists-p tags-file-name))
                                (and (boundp 'tags-table-list) tags-table-list
                                     (cl-some #'file-exists-p tags-table-list)))))
                  (format "No tags table available for %s" file-path))
                 (t
                  (let ((xref-items (xref-backend-apropos backend pattern-str)))
                    (if xref-items
                        (mapcar (lambda (item)
                                  (let* ((location (xref-item-location item))
                                         (file (xref-location-group location))
                                         (marker (xref-location-marker location))
                                         (line (with-current-buffer (marker-buffer marker)
                                                 (save-excursion
                                                   (goto-char marker)
                                                   (line-number-at-pos))))
                                         (summary (xref-item-summary item)))
                                    (format "%s:%d: %s" file line summary)))
                                xref-items)
                      (format "No symbols found matching '%s'" pattern-str))))))
            (error
             (format "Error searching for '%s' in %s: %s"
                     pattern-str file-path (error-message-string err)))))))))

(defun copilot-cli-mcp-project-info ()
  "Return a summary of the current session's project."
  (let ((context (copilot-cli-mcp-server-get-session-context)))
    (if context
        (let ((project-dir (plist-get context :project-dir))
              (buffer (plist-get context :buffer)))
          (format "Project: %s\nBuffer: %s\nFiles: %d"
                  project-dir
                  (if (and buffer (buffer-live-p buffer))
                      (buffer-name buffer)
                    "No active buffer")
                  (length (project-files (project-current nil project-dir)))))
      "No session context available")))

(defun copilot-cli-mcp-imenu-list-symbols (file-path)
  "List symbols in FILE-PATH using imenu."
  (if (not file-path)
      (error "file_path parameter is required")
    (copilot-cli-mcp-server-with-session-context nil
      (condition-case err
          (let ((target-buffer (or (find-buffer-visiting file-path)
                                   (find-file-noselect file-path))))
            (with-current-buffer target-buffer
              (imenu--make-index-alist)
              (if imenu--index-alist
                  (let ((results '()))
                    (dolist (item imenu--index-alist)
                      (cond
                       ((string-match-p "^\\*" (car item)) nil)
                       ((markerp (cdr item))
                        (push (format "%s:%d: %s"
                                      file-path
                                      (line-number-at-pos (marker-position (cdr item)))
                                      (car item))
                              results))
                       ((numberp (cdr item))
                        (push (format "%s:%d: %s"
                                      file-path
                                      (line-number-at-pos (cdr item))
                                      (car item))
                              results))
                       ((listp (cdr item))
                        (let ((category (car item)))
                          (dolist (subitem (cdr item))
                            (when (and (consp subitem)
                                       (or (markerp (cdr subitem)) (numberp (cdr subitem))))
                              (push (format "%s:%d: [%s] %s"
                                            file-path
                                            (line-number-at-pos
                                             (if (markerp (cdr subitem))
                                                 (marker-position (cdr subitem))
                                               (cdr subitem)))
                                            category
                                            (car subitem))
                                    results)))))))
                    (if results (nreverse results)
                      (format "No symbols found in %s" file-path)))
                (format "No imenu support or no symbols found in %s" file-path))))
        (error (format "Error listing symbols in %s: %s"
                       file-path (error-message-string err)))))))

(defun copilot-cli-mcp-treesit--format-tree (node level max-depth)
  "Format NODE as an indented tree string up to MAX-DEPTH levels."
  (if (or (not node) (>= level max-depth))
      ""
    (let* ((indent (make-string (* level 2) ?\s))
           (type (treesit-node-type node))
           (named (if (treesit-node-check node 'named) " (named)" ""))
           (start (treesit-node-start node))
           (end (treesit-node-end node))
           (field-name (treesit-node-field-name node))
           (field-str (if field-name (format " [%s]" field-name) ""))
           (text (treesit-node-text node t))
           (text-preview (if (and (< (length text) 40) (not (string-match-p "\n" text)))
                             (format " \"%s\"" text) ""))
           (result (format "%s%s%s%s (%d-%d)%s\n"
                           indent type named field-str start end text-preview))
           (child-count (treesit-node-child-count node)))
      (dotimes (i child-count)
        (when-let* ((child (treesit-node-child node i)))
          (setq result (concat result
                               (copilot-cli-mcp-treesit--format-tree
                                child (1+ level) max-depth)))))
      result)))

(defun copilot-cli-mcp--line-column-to-point (line column)
  "Convert 1-based LINE and 0-based COLUMN to a buffer position."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)
    (point)))

(defun copilot-cli-mcp-treesit-info (file-path &optional line column whole_file
                                               include_ancestors include_children)
  "Get tree-sitter information for FILE-PATH.
LINE (1-based) and COLUMN (0-based) specify a position.
WHOLE_FILE shows the full syntax tree.
INCLUDE_ANCESTORS and INCLUDE_CHILDREN expand the output."
  (if (not file-path)
      (error "file_path parameter is required")
    (copilot-cli-mcp-server-with-session-context nil
      (condition-case err
          (if (not (treesit-available-p))
              "Tree-sitter is not available in this Emacs build"
            (let ((target-buffer (or (find-buffer-visiting file-path)
                                     (find-file-noselect file-path))))
              (with-current-buffer target-buffer
                (let* ((parsers (treesit-parser-list))
                       (parser (car parsers)))
                  (if (not parser)
                      (format "No tree-sitter parser available for %s" file-path)
                    (let* ((root-node (treesit-parser-root-node parser))
                           (pos (cond (whole_file nil)
                                      (line (copilot-cli-mcp--line-column-to-point
                                             line (or column 0)))
                                      (t (point))))
                           (node (if whole_file root-node
                                   (treesit-node-at pos parser)))
                           (results '()))
                      (if (not node)
                          "No tree-sitter node found"
                        (if whole_file
                            (copilot-cli-mcp-treesit--format-tree root-node 0 20)
                          (push (format "Node Type: %s" (treesit-node-type node)) results)
                          (push (format "Range: %d-%d"
                                        (treesit-node-start node)
                                        (treesit-node-end node)) results)
                          (push (format "Text: %s"
                                        (truncate-string-to-width
                                         (treesit-node-text node t) 80 nil nil "...")) results)
                          (when (treesit-node-check node 'named)
                            (push "Named: yes" results))
                          (when-let* ((field-name (treesit-node-field-name node)))
                            (push (format "Field: %s" field-name) results))
                          (when include_ancestors
                            (push "\nAncestors:" results)
                            (let ((parent (treesit-node-parent node)) (level 1))
                              (while (and parent (< level 10))
                                (push (format "  %s[%d] %s (%d-%d)"
                                              (make-string level ?-)
                                              level
                                              (treesit-node-type parent)
                                              (treesit-node-start parent)
                                              (treesit-node-end parent))
                                      results)
                                (setq parent (treesit-node-parent parent))
                                (cl-incf level))))
                          (when include_children
                            (push "\nChildren:" results)
                            (let ((child-count (treesit-node-child-count node)) (i 0))
                              (if (= child-count 0)
                                  (push "  (no children)" results)
                                (while (< i (min child-count 20))
                                  (when-let* ((child (treesit-node-child node i)))
                                    (push (format "  [%d] %s%s (%d-%d)"
                                                  i
                                                  (treesit-node-type child)
                                                  (if (treesit-node-check child 'named)
                                                      " (named)" "")
                                                  (treesit-node-start child)
                                                  (treesit-node-end child))
                                          results))
                                  (cl-incf i))
                                (when (> child-count 20)
                                  (push (format "  ... and %d more children"
                                                (- child-count 20))
                                        results)))))
                          (string-join (nreverse results) "\n")))))))))
        (error (format "Error getting tree-sitter info for %s: %s"
                       file-path (error-message-string err)))))))

;;; Additional Tool Functions

(defun copilot-cli-mcp-xref-find-definitions (identifier file-path)
  "Find definitions of IDENTIFIER using the xref backend for FILE-PATH."
  (if (not file-path)
      (error "file_path parameter is required")
    (copilot-cli-mcp-server-with-session-context nil
      (let ((target-buffer (or (find-buffer-visiting file-path)
                               (find-file-noselect file-path)))
            (identifier-str (format "%s" identifier)))
        (with-current-buffer target-buffer
          (condition-case err
              (let ((backend (xref-find-backend)))
                (if (not backend)
                    (format "No xref backend available for %s" file-path)
                  (let ((xref-items (xref-backend-definitions backend identifier-str)))
                    (if xref-items
                        (mapcar (lambda (item)
                                  (let* ((location (xref-item-location item))
                                         (file (xref-location-group location))
                                         (marker (xref-location-marker location))
                                         (line (with-current-buffer (marker-buffer marker)
                                                 (save-excursion
                                                   (goto-char marker)
                                                   (line-number-at-pos))))
                                         (summary (xref-item-summary item)))
                                    (format "%s:%d: %s" file line summary)))
                                xref-items)
                      (format "No definition found for '%s'" identifier-str)))))
            (error
             (format "Error finding definition of '%s' in %s: %s"
                     identifier-str file-path (error-message-string err)))))))))

(defun copilot-cli-mcp-eval-elisp (expression)
  "Evaluate EXPRESSION as Emacs Lisp and return the result as a string."
  (condition-case err
      (let ((result (eval (read expression) t)))
        (format "%S" result))
    (error (format "Error: %s" (error-message-string err)))))

(defun copilot-cli-mcp-get-buffer-content (file-path)
  "Return the current in-memory content of the buffer visiting FILE-PATH.
Unlike reading the file from disk, this captures unsaved changes."
  (if (not file-path)
      (error "file_path parameter is required")
    (let ((buffer (find-buffer-visiting file-path)))
      (if buffer
          (with-current-buffer buffer
            (buffer-substring-no-properties (point-min) (point-max)))
        (format "No open buffer for %s" file-path)))))

(defun copilot-cli-mcp-list-open-buffers ()
  "Return a formatted list of open file-visiting buffers."
  (let ((context (copilot-cli-mcp-server-get-session-context))
        (lines '()))
    (let ((project-dir (and context (plist-get context :project-dir))))
      (dolist (buffer (buffer-list))
        (when-let* ((file (buffer-file-name buffer)))
          (push (format "%s%s%s"
                        (if (buffer-modified-p buffer) "* " "  ")
                        file
                        (if (and project-dir
                                 (string-prefix-p (expand-file-name project-dir)
                                                  (expand-file-name file)))
                            " [project]" ""))
                lines))))
    (if lines
        (string-join (nreverse lines) "\n")
      "No file-visiting buffers open")))

(defun copilot-cli-mcp-compilation-errors ()
  "Return errors and warnings from the most recent `*compilation*' buffer."
  (let ((comp-buffer (get-buffer "*compilation*")))
    (if (not comp-buffer)
        "No compilation buffer found.  Run M-x compile first."
      (with-current-buffer comp-buffer
        (let ((lines '())
              (count 0))
          (save-excursion
            (goto-char (point-min))
            (while (re-search-forward
                    (rx bol
                        (group (+? nonl))   ; file
                        ":"
                        (group (+ digit))   ; line
                        (? ":" (group (+ digit))) ; optional col
                        ":"
                        (+ space)
                        (group (+? nonl))   ; message
                        eol)
                    nil t)
              (push (format "%s:%s:%s: %s"
                            (match-string 1)
                            (match-string 2)
                            (or (match-string 3) "0")
                            (match-string 4))
                    lines)
              (cl-incf count)))
          (if lines
              (format "%d error(s)/warning(s):\n%s"
                      count (string-join (nreverse lines) "\n"))
            ;; Fall back to showing the buffer tail if pattern matched nothing
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (if (string-match-p "finished" content)
                  "Compilation finished with no errors."
                (let* ((trimmed (string-trim content))
                       (tail-start (max 0 (- (length trimmed) 2000))))
                  (substring trimmed tail-start))))))))))

;;; Setup Function

;;;###autoload
(defun copilot-cli-emacs-tools-setup ()
  "Enable all Emacs MCP tools and activate the MCP server.
Add this to your init file to expose xref, imenu, tree-sitter, and
project information to Copilot CLI via the HTTP MCP server."
  (interactive)
  (setq copilot-cli-enable-mcp-server t)

  (copilot-cli-make-tool
   :function #'copilot-cli-mcp-xref-find-references
   :name "copilot_cli_xref_find_references"
   :description "Find where a function, variable, or class is used throughout the codebase"
   :args '((:name "identifier"
                  :type string
                  :description "The identifier to find references for")
           (:name "file_path"
                  :type string
                  :description "File path to use as context for the search")))

  (copilot-cli-make-tool
   :function #'copilot-cli-mcp-xref-find-definitions
   :name "copilot_cli_xref_find_definitions"
   :description "Find where a function, variable, or class is defined"
   :args '((:name "identifier"
                  :type string
                  :description "The identifier to find the definition for")
           (:name "file_path"
                  :type string
                  :description "File path to use as context for the search")))

  (copilot-cli-make-tool
   :function #'copilot-cli-mcp-xref-find-apropos
   :name "copilot_cli_xref_find_apropos"
   :description "Search for symbols by name pattern across the project"
   :args '((:name "pattern"
                  :type string
                  :description "Pattern to search for symbols")
           (:name "file_path"
                  :type string
                  :description "File path to use as context for the search")))

  (copilot-cli-make-tool
   :function #'copilot-cli-mcp-project-info
   :name "copilot_cli_project_info"
   :description "Get an overview of the current project: directory, active buffer, file count"
   :args nil)

  (copilot-cli-make-tool
   :function #'copilot-cli-mcp-imenu-list-symbols
   :name "copilot_cli_imenu_list_symbols"
   :description "List all functions, classes, and variables in a file with their locations"
   :args '((:name "file_path"
                  :type string
                  :description "Path to the file to analyze")))

  (copilot-cli-make-tool
   :function #'copilot-cli-mcp-treesit-info
   :name "copilot_cli_treesit_info"
   :description "Get tree-sitter syntax tree information for a file or position"
   :args '((:name "file_path"
                  :type string
                  :description "Path to the file to analyze")
           (:name "line"
                  :type number
                  :description "Line number (1-based)"
                  :optional t)
           (:name "column"
                  :type number
                  :description "Column number (0-based)"
                  :optional t)
           (:name "whole_file"
                  :type boolean
                  :description "Show the entire file syntax tree"
                  :optional t)
           (:name "include_ancestors"
                  :type boolean
                  :description "Include parent node hierarchy"
                  :optional t)
           (:name "include_children"
                  :type boolean
                  :description "Include child nodes"
                  :optional t)))

  (copilot-cli-diagnostics-setup)

  (copilot-cli-make-tool
   :function #'copilot-cli-mcp-eval-elisp
   :name "copilot_cli_eval_elisp"
   :description (concat "Evaluate an Emacs Lisp expression and return the result. "
                         "Useful for inspecting Emacs state, running commands, or "
                         "checking configuration values.")
   :args '((:name "expression"
                  :type string
                  :description "Emacs Lisp expression to evaluate")))

  (copilot-cli-make-tool
   :function #'copilot-cli-mcp-get-buffer-content
   :name "copilot_cli_get_buffer_content"
   :description (concat "Return the current in-memory content of an open buffer, "
                         "including unsaved changes not yet written to disk.")
   :args '((:name "file_path"
                  :type string
                  :description "Absolute path to the file whose buffer to read")))

  (copilot-cli-make-tool
   :function #'copilot-cli-mcp-list-open-buffers
   :name "copilot_cli_list_open_buffers"
   :description (concat "List all open file-visiting buffers.  "
                         "Modified (unsaved) buffers are marked with *.  "
                         "Buffers inside the current project are marked with [project].")
   :args nil)

  (copilot-cli-make-tool
   :function #'copilot-cli-mcp-compilation-errors
   :name "copilot_cli_compilation_errors"
   :description (concat "Return errors and warnings from the most recent compilation "
                         "run (M-x compile).  Complements flycheck/flymake diagnostics "
                         "with build-time errors.")
   :args nil))

(provide 'copilot-cli-emacs-tools)

;;; copilot-cli-emacs-tools.el ends here
