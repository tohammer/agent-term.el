;;; copilot-ide-emacs-tools.el --- Emacs MCP tools for Copilot CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Tobias Hammer
;; Copyright (C) 2025 Yoav Orot

;; Based on claude-code-ide.el by Yoav Orot (manzaltu)
;; https://github.com/manzaltu/claude-code-ide.el

;; Keywords: ai, copilot, mcp, tools, xref, emacs
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

;; Emacs-specific MCP tools for Copilot CLI.  Exposes xref, imenu,
;; tree-sitter, and project information through the HTTP MCP server.
;;
;; Call `copilot-ide-emacs-tools-setup' in your init file to enable all tools.

;;; Code:

(require 'copilot-ide-mcp-server)
(require 'copilot-ide-diagnostics)
(require 'xref)
(require 'project)
(require 'cl-lib)
(require 'imenu)

;; Tree-sitter declarations
(declare-function treesit-node-at "treesit" (pos &optional parser-or-lang named))
(declare-function treesit-node-text "treesit" (node &optional no-property))
(declare-function treesit-node-field-name "treesit" (node))

;;; Tool Functions

(defun copilot-ide-mcp--lsp-connected-p ()
  "Return non-nil if the current buffer has an active LSP connection.
Checks for eglot and lsp-mode."
  (or (and (fboundp 'eglot-current-server) (eglot-current-server))
      (and (fboundp 'lsp-workspaces) (lsp-workspaces))))

(defun copilot-ide-mcp--grep-symbol-in-project (identifier project-dir &optional definitions-only)
  "Search for IDENTIFIER across all files in PROJECT-DIR using grep.
When DEFINITIONS-ONLY is non-nil, restrict to likely definition patterns
(assignments, def/class/const declarations).
Returns a list of \"file:line: text\" strings."
  (let* ((id-str (format "%s" identifier))
         (pattern (if definitions-only
                      ;; Match common definition patterns across languages
                      (format "^[[:space:]]*(def |class |const |let |var |%s[[:space:]]*[=:(])"
                              (regexp-quote id-str))
                    ;; Match any occurrence as a whole word
                    (format "\\b%s\\b" (regexp-quote id-str))))
         (default-directory project-dir)
         (results '()))
    (condition-case err
        (let* ((cmd (if (executable-find "rg")
                        (list "rg" "--no-heading" "--line-number" "--with-filename"
                              (if definitions-only
                                  ;; For definitions: look for assignment/def patterns
                                  (format "^[[:space:]]*(%s[[:space:]]*[=:(]|def |class )"
                                          (regexp-quote id-str))
                                (format "\\b%s\\b" (regexp-quote id-str)))
                              project-dir)
                      (list "grep" "-rn" "--include=*"
                            (format "\\b%s\\b" (regexp-quote id-str))
                            project-dir)))
               (output (with-temp-buffer
                         (apply #'call-process (car cmd) nil t nil (cdr cmd))
                         (buffer-string))))
          (dolist (line (split-string output "\n" t))
            (push line results))
          (nreverse results))
      (error
       (list (format "grep failed: %s" (error-message-string err)))))))

(defun copilot-ide-mcp--xref-items-to-strings (xref-items)
  "Format a list of XREF-ITEMS as \"file:line: summary\" strings."
  (mapcar (lambda (item)
            (let* ((location (xref-item-location item))
                   (file (xref-location-group location))
                   (marker (xref-location-marker location))
                   (line (with-current-buffer (marker-buffer marker)
                           (save-excursion (goto-char marker)
                                           (line-number-at-pos))))
                   (summary (xref-item-summary item)))
              (format "%s:%d: %s" file line summary)))
          xref-items))

(defun copilot-ide-mcp--get-xref-buffer (file-path)
  "Return the best buffer to use as context for xref operations on FILE-PATH.
Prefers an already-open buffer visiting FILE-PATH (which will have LSP active).
Only opens FILE-PATH as a last resort (which may lack an LSP connection)."
  (or (find-buffer-visiting file-path)
      (find-file-noselect file-path)))

(defun copilot-ide-mcp--call-xref-at-identifier (identifier fn)
  "Position point at IDENTIFIER in the current buffer, then call FN.
FN is called with no arguments while point is at the start of the first
occurrence of IDENTIFIER.  Uses symbol-boundary search so partial matches
are skipped.  If IDENTIFIER is not found, calls FN from the current point
\(LSP may still resolve it via the overall buffer context).
Returns whatever FN returns."
  (save-excursion
    (goto-char (point-min))
    (let* ((id-str (format "%s" identifier))
           (pattern (format "\\_<%s\\_>" (regexp-quote id-str)))
           (found (or (re-search-forward pattern nil t)
                      ;; Fall back to plain substring if boundary search fails
                      (search-forward id-str nil t))))
      (when found (goto-char (match-beginning 0)))
      (funcall fn))))

(defun copilot-ide-mcp-xref-find-references (identifier file-path)
  "Find references to IDENTIFIER using the xref backend for FILE-PATH.
Positions point at IDENTIFIER in the buffer before querying LSP, since
LSP backends (eglot, lsp-mode) use the cursor position for the request.
Falls back to a grep-based project search when LSP is not connected."
  (if (not file-path)
      (error "file_path parameter is required")
    (copilot-ide-mcp-server-with-session-context nil
      (let ((target-buffer (copilot-ide-mcp--get-xref-buffer file-path))
            (identifier-str (format "%s" identifier)))
        (with-current-buffer target-buffer
          (if (and (xref-find-backend) (copilot-ide-mcp--lsp-connected-p))
              (condition-case _err
                  (let ((xref-items
                         (copilot-ide-mcp--call-xref-at-identifier
                          identifier-str
                          (lambda () (xref-backend-references
                                      (xref-find-backend) identifier-str)))))
                    (if xref-items
                        (copilot-ide-mcp--xref-items-to-strings xref-items)
                      (format "No references found for '%s'" identifier-str)))
                (error
                 ;; LSP connected but request failed — fall through to grep
                 (copilot-ide-mcp--grep-symbol-in-project
                  identifier-str (or (plist-get (copilot-ide-mcp-server-get-session-context) :project-dir)
                                     default-directory))))
            ;; No LSP — use grep
            (let ((results (copilot-ide-mcp--grep-symbol-in-project
                            identifier-str (or (plist-get (copilot-ide-mcp-server-get-session-context) :project-dir)
                                               default-directory))))
              (or results (format "No references found for '%s'" identifier-str)))))))))

(defun copilot-ide-mcp-xref-find-apropos (pattern file-path)
  "Find symbols matching PATTERN using the xref backend for FILE-PATH."
  (if (not file-path)
      (error "file_path parameter is required")
    (copilot-ide-mcp-server-with-session-context nil
      (let ((target-buffer (copilot-ide-mcp--get-xref-buffer file-path))
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

(defun copilot-ide-mcp-project-info ()
  "Return a summary of the current session's project."
  (let ((context (copilot-ide-mcp-server-get-session-context)))
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

(defun copilot-ide-mcp-imenu-list-symbols (file-path)
  "List symbols in FILE-PATH using imenu."
  (if (not file-path)
      (error "file_path parameter is required")
    (copilot-ide-mcp-server-with-session-context nil
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

(defun copilot-ide-mcp-treesit--format-tree (node level max-depth)
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
                               (copilot-ide-mcp-treesit--format-tree
                                child (1+ level) max-depth)))))
      result)))

(defun copilot-ide-mcp--line-column-to-point (line column)
  "Convert 1-based LINE and 0-based COLUMN to a buffer position."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)
    (point)))

(defun copilot-ide-mcp-treesit-info (file-path &optional line column whole_file
                                               include_ancestors include_children)
  "Get tree-sitter information for FILE-PATH.
LINE (1-based) and COLUMN (0-based) specify a position.
WHOLE_FILE shows the full syntax tree.
INCLUDE_ANCESTORS and INCLUDE_CHILDREN expand the output."
  (if (not file-path)
      (error "file_path parameter is required")
    (copilot-ide-mcp-server-with-session-context nil
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
                                      (line (copilot-ide-mcp--line-column-to-point
                                             line (or column 0)))
                                      (t (point))))
                           (node (if whole_file root-node
                                   (treesit-node-at pos parser)))
                           (results '()))
                      (if (not node)
                          "No tree-sitter node found"
                        (if whole_file
                            (copilot-ide-mcp-treesit--format-tree root-node 0 20)
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

(defun copilot-ide-mcp-xref-find-definitions (identifier file-path)
  "Find definitions of IDENTIFIER using the xref backend for FILE-PATH.
Positions point at IDENTIFIER in the buffer before querying LSP, since
LSP backends (eglot, lsp-mode) use the cursor position for the request.
Falls back to a grep-based project search when LSP is not connected."
  (if (not file-path)
      (error "file_path parameter is required")
    (copilot-ide-mcp-server-with-session-context nil
      (let ((target-buffer (copilot-ide-mcp--get-xref-buffer file-path))
            (identifier-str (format "%s" identifier)))
        (with-current-buffer target-buffer
          (if (and (xref-find-backend) (copilot-ide-mcp--lsp-connected-p))
              (condition-case _err
                  (let ((xref-items
                         (copilot-ide-mcp--call-xref-at-identifier
                          identifier-str
                          (lambda () (xref-backend-definitions
                                      (xref-find-backend) identifier-str)))))
                    (if xref-items
                        (copilot-ide-mcp--xref-items-to-strings xref-items)
                      (format "No definition found for '%s'" identifier-str)))
                (error
                 ;; LSP connected but request failed — fall through to grep
                 (copilot-ide-mcp--grep-symbol-in-project
                  identifier-str (or (plist-get (copilot-ide-mcp-server-get-session-context) :project-dir)
                                     default-directory)
                  'definitions-only)))
            ;; No LSP — use grep
            (let ((results (copilot-ide-mcp--grep-symbol-in-project
                            identifier-str (or (plist-get (copilot-ide-mcp-server-get-session-context) :project-dir)
                                               default-directory)
                            'definitions-only)))
              (or results (format "No definition found for '%s'" identifier-str)))))))))

(defun copilot-ide-mcp-eval-elisp (expression)
  "Evaluate EXPRESSION as Emacs Lisp and return the result as a string."
  (condition-case err
      (let ((result (eval (read expression) t)))
        (format "%S" result))
    (error (format "Error: %s" (error-message-string err)))))

(defun copilot-ide-mcp-get-buffer-content (file-path)
  "Return the current in-memory content of the buffer visiting FILE-PATH.
Unlike reading the file from disk, this captures unsaved changes."
  (if (not file-path)
      (error "file_path parameter is required")
    (let ((buffer (find-buffer-visiting file-path)))
      (if buffer
          (with-current-buffer buffer
            (buffer-substring-no-properties (point-min) (point-max)))
        (format "No open buffer for %s" file-path)))))

(defun copilot-ide-mcp-list-open-buffers ()
  "Return a formatted list of open file-visiting buffers."
  (let ((context (copilot-ide-mcp-server-get-session-context))
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

(defun copilot-ide-mcp-compilation-errors ()
  "Return errors and warnings from the most recent compilation buffer.
Scopes to the current MCP session's project directory when available,
so multi-project setups return the correct compilation buffer."
  (let* ((context (copilot-ide-mcp-server-get-session-context))
         (project-dir (and context (expand-file-name
                                    (plist-get context :project-dir))))
         (comp-buffer
          (cl-find-if (lambda (buf)
                        (with-current-buffer buf
                          (and (derived-mode-p 'compilation-mode)
                               (or (null project-dir)
                                   (string-prefix-p project-dir
                                                    (expand-file-name default-directory))))))
                      (buffer-list))))
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

(defun copilot-ide-mcp-get-visible-buffers ()
  "Return information about all buffers currently visible in Emacs windows.
Each entry shows the file path (or buffer name), the visible line range,
and whether the buffer has unsaved changes."
  (let ((results '()))
    (dolist (win (window-list nil 'no-minibuf))
      (let* ((buf (window-buffer win))
             (file (buffer-file-name buf))
             (name (buffer-name buf))
             (start-line (with-current-buffer buf
                           (line-number-at-pos (window-start win))))
             (end-line (with-current-buffer buf
                         (line-number-at-pos (window-end win t)))))
        (push (format "%s  lines %d-%d%s%s"
                      (or file name)
                      start-line
                      end-line
                      (if (buffer-modified-p buf) " [modified]" "")
                      (if file "" " [no file]"))
              results)))
    (if results
        (string-join (nreverse results) "\n")
      "No visible buffers")))

(defun copilot-ide-mcp-get-current-region ()
  "Return the current region or cursor position in the last-active buffer.
Reports the file path and the line/column range of the active region.
If no region is active, reports the cursor position instead.
The selected text is included when a region is active."
  (copilot-ide-mcp-server-with-session-context nil
    (if (not (buffer-file-name))
        "No file associated with the current buffer"
      (let* ((file-path (buffer-file-name))
             (has-region (use-region-p))
             (beg (if has-region (region-beginning) (point)))
             (end (if has-region (region-end) (point)))
             (beg-line (line-number-at-pos beg))
             (end-line (line-number-at-pos end))
             (beg-col (save-excursion (goto-char beg) (current-column)))
             (end-col (save-excursion (goto-char end) (current-column))))
        (if has-region
            (format "File: %s\nRegion: line %d col %d - line %d col %d\nText:\n%s"
                    file-path
                    beg-line beg-col
                    end-line end-col
                    (buffer-substring-no-properties beg end))
          (format "File: %s\nCursor: line %d col %d\n(no active region)"
                  file-path beg-line beg-col))))))

;;; Setup Function

;;;###autoload
(defun copilot-ide-emacs-tools-setup ()
  "Enable all Emacs MCP tools and activate the MCP server.
Add this to your init file to expose xref, imenu, tree-sitter, and
project information to Copilot CLI via the HTTP MCP server."
  (interactive)
  (setq copilot-ide-enable-mcp-server t)

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-xref-find-references
   :name "copilot_cli_xref_find_references"
   :description "Find where a function, variable, or class is used throughout the codebase"
   :args '((:name "identifier"
                  :type string
                  :description "The identifier to find references for")
           (:name "file_path"
                  :type string
                  :description "File path to use as context for the search")))

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-xref-find-definitions
   :name "copilot_cli_xref_find_definitions"
   :description "Find where a function, variable, or class is defined"
   :args '((:name "identifier"
                  :type string
                  :description "The identifier to find the definition for")
           (:name "file_path"
                  :type string
                  :description "File path to use as context for the search")))

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-xref-find-apropos
   :name "copilot_cli_xref_find_apropos"
   :description "Search for symbols by name pattern across the project"
   :args '((:name "pattern"
                  :type string
                  :description "Pattern to search for symbols")
           (:name "file_path"
                  :type string
                  :description "File path to use as context for the search")))

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-project-info
   :name "copilot_cli_project_info"
   :description "Get an overview of the current project: directory, active buffer, file count"
   :args nil)

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-imenu-list-symbols
   :name "copilot_cli_imenu_list_symbols"
   :description "List all functions, classes, and variables in a file with their locations"
   :args '((:name "file_path"
                  :type string
                  :description "Path to the file to analyze")))

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-treesit-info
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

  (copilot-ide-diagnostics-setup)

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-eval-elisp
   :name "copilot_cli_eval_elisp"
   :description (concat "Evaluate an Emacs Lisp expression and return the result. "
                         "Useful for inspecting Emacs state, running commands, or "
                         "checking configuration values.")
   :args '((:name "expression"
                  :type string
                  :description "Emacs Lisp expression to evaluate")))

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-get-buffer-content
   :name "copilot_cli_get_buffer_content"
   :description (concat "Return the current in-memory content of an open buffer, "
                         "including unsaved changes not yet written to disk.")
   :args '((:name "file_path"
                  :type string
                  :description "Absolute path to the file whose buffer to read")))

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-list-open-buffers
   :name "copilot_cli_list_open_buffers"
   :description (concat "List all open file-visiting buffers.  "
                         "Modified (unsaved) buffers are marked with *.  "
                         "Buffers inside the current project are marked with [project].")
   :args nil)

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-compilation-errors
   :name "copilot_cli_compilation_errors"
   :description (concat "Return errors and warnings from the most recent compilation "
                         "run (M-x compile).  Complements flycheck/flymake diagnostics "
                         "with build-time errors.")
   :args nil)

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-get-visible-buffers
   :name "copilot_cli_get_visible_buffers"
   :description (concat "Return all buffers currently visible in Emacs windows, "
                         "including file path, visible line range, and modification status. "
                         "Useful for understanding what the user is currently looking at.")
   :args nil)

  (copilot-ide-make-tool
   :function #'copilot-ide-mcp-get-current-region
   :name "copilot_cli_get_current_region"
   :description (concat "Return the user's current text selection (region) in the last-active buffer. "
                         "Includes file path, start/end line and column, and the selected text. "
                         "Falls back to cursor position when no region is active.")
   :args nil))

(provide 'copilot-ide-emacs-tools)

;;; copilot-ide-emacs-tools.el ends here
