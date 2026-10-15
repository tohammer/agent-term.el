;;; copilot-ide-mcp-server.el --- MCP tools server for AI coding agents  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Tobias Hammer
;; Copyright (C) 2025 Yoav Orot

;; Based on claude-code-ide.el by Yoav Orot (manzaltu)
;; https://github.com/manzaltu/claude-code-ide.el

;; Keywords: ai, mcp, tools
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

;; Registry of MCP tools and agent sessions, and the lifecycle of the
;; HTTP MCP server that exposes the tools to the agents:
;; - the server starts with the first session (if enabled),
;; - it stops when the last session ends.
;;
;; Each session is registered under a random token.  The token is part
;; of the endpoint URL handed to the agent and is the only way in.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'copilot-ide-debug)

(declare-function copilot-ide-mcp-http-server-start "copilot-ide-mcp-http-server" (&optional port))
(declare-function copilot-ide-mcp-http-server-stop "copilot-ide-mcp-http-server" (server))

;;; Customization

(defgroup copilot-ide-mcp-server nil
  "MCP tools server settings."
  :group 'copilot-ide
  :prefix "copilot-ide-mcp-server-")

(defcustom copilot-ide-enable-mcp-server nil
  "Enable the MCP tools server that exposes Emacs functions to the agent.
When enabled, an HTTP MCP server on 127.0.0.1 provides the tools
registered with `copilot-ide-make-tool' to every session."
  :type 'boolean
  :group 'copilot-ide-mcp-server)

(defcustom copilot-ide-mcp-server-port nil
  "Port for the MCP tools server.
If nil, a free port is selected automatically."
  :type '(choice (const :tag "Auto-select" nil)
                 (integer :tag "Fixed port"))
  :group 'copilot-ide-mcp-server)

(defvar copilot-ide-mcp-server-tools nil
  "List of tool specifications exposed via the MCP tools server.
Use `copilot-ide-make-tool' to register tools.")

;;; State Management

(defvar copilot-ide-mcp-server--server nil
  "The MCP tools server process.")

(defvar copilot-ide-mcp-server--port nil
  "The port the MCP tools server is running on.")

(defvar copilot-ide-mcp-server--sessions (make-hash-table :test 'equal)
  "Hash table mapping session IDs to session contexts.
Each entry is a plist with :project-dir, :buffer, :last-active-buffer.")

(defvar copilot-ide-mcp-server--current-session-id nil
  "The session ID for the current MCP tool request.
Dynamically bound during tool execution.")

;;; Tool Definition

(defun copilot-ide-make-tool (&rest slots)
  "Define an MCP tool and register it with the server.
A tool registered earlier under the same name is replaced.

SLOTS are keyword arguments:
  :name        - Tool name string (required)
  :function    - Elisp function to call (required)
  :description - Human-readable description (required)
  :args        - List of argument plists, each with:
                   :name        - Argument name string
                   :type        - Type symbol (string, number, boolean, ...)
                   :description - Argument description
                   :optional    - Non-nil if argument is optional

The function receives the arguments in the order of :args; a missing
optional argument, JSON false and JSON null arrive as nil.

Returns the tool specification."
  (let ((function (plist-get slots :function))
        (name (plist-get slots :name))
        (description (plist-get slots :description))
        (args (plist-get slots :args)))
    (unless function (error "Tool :function is required"))
    (unless name (error "Tool :name is required"))
    (unless description (error "Tool :description is required"))
    (let ((spec (list :function function
                      :name name
                      :description description)))
      (when args (setq spec (plist-put spec :args args)))
      (setq copilot-ide-mcp-server-tools
            (append (cl-remove name copilot-ide-mcp-server-tools
                               :key (lambda (s) (plist-get s :name))
                               :test #'equal)
                    (list spec)))
      spec)))

;;; Public Functions

(defun copilot-ide-mcp-server-new-session-id ()
  "Return a new random session token (32 hex digits)."
  (let ((bytes (ignore-errors
                 (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally "/dev/urandom" nil 0 16)
                   (buffer-string)))))
    (if (= (length bytes) 16)
        (mapconcat (lambda (b) (format "%02x" b)) bytes "")
      (substring (secure-hash 'sha256 (format "%S%S%S%S" (random t) (current-time)
                                              (emacs-pid) (recent-keys)))
                 0 32))))

(defun copilot-ide-mcp-server-ensure-server ()
  "Ensure the MCP tools server is running.
Returns the port number on success, nil if disabled or failed."
  (when copilot-ide-enable-mcp-server
    (unless (copilot-ide-mcp-server-get-port)
      (copilot-ide-mcp-server--start-server))
    copilot-ide-mcp-server--port))

(defun copilot-ide-mcp-server-get-port ()
  "Get the port number of the running MCP tools server, or nil."
  (when (and copilot-ide-mcp-server--port
             (process-live-p copilot-ide-mcp-server--server))
    copilot-ide-mcp-server--port))

(defun copilot-ide-mcp-server-session-started (session-id project-dir buffer)
  "Register the session SESSION-ID for PROJECT-DIR shown in BUFFER."
  (puthash session-id
           (list :project-dir project-dir
                 :buffer buffer
                 :last-active-buffer nil)
           copilot-ide-mcp-server--sessions)
  (copilot-ide-debug "Registered MCP session for project %s" project-dir))

(defun copilot-ide-mcp-server-session-ended (session-id)
  "Unregister SESSION-ID; stop the server when no session remains."
  (remhash session-id copilot-ide-mcp-server--sessions)
  (when (zerop (hash-table-count copilot-ide-mcp-server--sessions))
    (copilot-ide-mcp-server--stop-server)))

(defun copilot-ide-mcp-server-get-config (session-id)
  "Return the MCP client configuration for SESSION-ID, or nil.
The result is an alist that encodes to the JSON object both Copilot
and Claude accept: {\"mcpServers\": {\"emacs-tools\": {...}}}."
  (when-let* ((port (copilot-ide-mcp-server-get-port)))
    `((mcpServers
       . ((emacs-tools
           . ((type . "http")
              (url . ,(format "http://127.0.0.1:%d/mcp/%s" port session-id)))))))))

(defun copilot-ide-mcp-server-get-tool-names (&optional prefix)
  "Return a list of registered tool names, each optionally prefixed with PREFIX."
  (mapcar (lambda (spec)
            (let ((name (plist-get spec :name)))
              (if prefix (concat prefix name) name)))
          copilot-ide-mcp-server-tools))

;;; Session Context

(defun copilot-ide-mcp-server-get-session-context (&optional session-id)
  "Return the context plist for SESSION-ID (or the current session)."
  (let ((id (or session-id copilot-ide-mcp-server--current-session-id)))
    (when id (gethash id copilot-ide-mcp-server--sessions))))

(defun copilot-ide-mcp-server-update-last-active-buffer (session-id buffer)
  "Set the last active BUFFER for SESSION-ID."
  (when-let* ((session (gethash session-id copilot-ide-mcp-server--sessions)))
    (unless (eq (plist-get session :last-active-buffer) buffer)
      (puthash session-id (plist-put session :last-active-buffer buffer)
               copilot-ide-mcp-server--sessions))))

(defun copilot-ide-mcp-server-expand-file-name (file)
  "Expand FILE relative to the project directory of the current session.
Outside a session, FILE is expanded relative to `default-directory'."
  (expand-file-name
   file (or (plist-get (copilot-ide-mcp-server-get-session-context) :project-dir)
            default-directory)))

(defmacro copilot-ide-mcp-server-with-session-context (session-id &rest body)
  "Execute BODY in the context of SESSION-ID (nil means the current session).
Makes the last active buffer (falling back to the session buffer)
current and binds `default-directory' to the project root."
  (declare (indent 1))
  (let ((context (make-symbol "context"))
        (buffer (make-symbol "buffer")))
    `(let* ((,context (copilot-ide-mcp-server-get-session-context ,session-id))
            (,buffer (cl-find-if #'buffer-live-p
                                 (list (plist-get ,context :last-active-buffer)
                                       (plist-get ,context :buffer)))))
       (unless ,context
         (error "No session context found"))
       (with-current-buffer (or ,buffer (current-buffer))
         ;; `default-directory' is buffer-local everywhere, so bind it
         ;; after switching buffers.
         (let ((default-directory (or (plist-get ,context :project-dir)
                                      default-directory)))
           ,@body)))))

;;; Internal Functions

(defun copilot-ide-mcp-server--start-server ()
  "Start the MCP HTTP server; return its port or nil on failure."
  (condition-case err
      (progn
        (require 'copilot-ide-mcp-http-server)
        (let ((result (copilot-ide-mcp-http-server-start copilot-ide-mcp-server-port)))
          (setq copilot-ide-mcp-server--server (car result)
                copilot-ide-mcp-server--port (cdr result))))
    (error
     (copilot-ide-debug "Failed to start MCP server: %s" (error-message-string err))
     (message "Warning: Failed to start MCP server: %s" (error-message-string err))
     nil)))

(defun copilot-ide-mcp-server--stop-server ()
  "Stop the MCP HTTP server."
  (when copilot-ide-mcp-server--server
    (copilot-ide-mcp-http-server-stop copilot-ide-mcp-server--server)
    (setq copilot-ide-mcp-server--server nil
          copilot-ide-mcp-server--port nil)
    (copilot-ide-debug "MCP server stopped")))

(provide 'copilot-ide-mcp-server)

;;; copilot-ide-mcp-server.el ends here
