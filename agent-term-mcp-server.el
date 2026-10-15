;;; agent-term-mcp-server.el --- MCP tools server for AI coding agents  -*- lexical-binding: t; -*-

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
(require 'agent-term-debug)

(declare-function agent-term-mcp-http-server-start "agent-term-mcp-http-server" (&optional port))
(declare-function agent-term-mcp-http-server-stop "agent-term-mcp-http-server" (server))

;;; Customization

(defgroup agent-term-mcp-server nil
  "MCP tools server settings."
  :group 'agent-term
  :prefix "agent-term-mcp-server-")

(defcustom agent-term-enable-mcp-server nil
  "Enable the MCP tools server that exposes Emacs functions to the agent.
When enabled, an HTTP MCP server on 127.0.0.1 provides the tools
registered with `agent-term-make-tool' to every session."
  :type 'boolean
  :group 'agent-term-mcp-server)

(defcustom agent-term-mcp-server-port nil
  "Port for the MCP tools server.
If nil, a free port is selected automatically."
  :type '(choice (const :tag "Auto-select" nil)
                 (integer :tag "Fixed port"))
  :group 'agent-term-mcp-server)

(defvar agent-term-mcp-server-tools nil
  "List of tool specifications exposed via the MCP tools server.
Use `agent-term-make-tool' to register tools.")

;;; State Management

(defvar agent-term-mcp-server--server nil
  "The MCP tools server process.")

(defvar agent-term-mcp-server--port nil
  "The port the MCP tools server is running on.")

(defvar agent-term-mcp-server--sessions (make-hash-table :test 'equal)
  "Hash table mapping session IDs to session contexts.
Each entry is a plist with :project-dir, :buffer, :last-active-buffer.")

(defvar agent-term-mcp-server--current-session-id nil
  "The session ID for the current MCP tool request.
Dynamically bound during tool execution.")

;;; Tool Definition

(defun agent-term-make-tool (&rest slots)
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
      (setq agent-term-mcp-server-tools
            (append (cl-remove name agent-term-mcp-server-tools
                               :key (lambda (s) (plist-get s :name))
                               :test #'equal)
                    (list spec)))
      spec)))

;;; Public Functions

(defun agent-term-mcp-server-new-session-id ()
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

(defun agent-term-mcp-server-ensure-server ()
  "Ensure the MCP tools server is running.
Returns the port number on success, nil if disabled or failed."
  (when agent-term-enable-mcp-server
    (unless (agent-term-mcp-server-get-port)
      (agent-term-mcp-server--start-server))
    agent-term-mcp-server--port))

(defun agent-term-mcp-server-get-port ()
  "Get the port number of the running MCP tools server, or nil."
  (when (and agent-term-mcp-server--port
             (process-live-p agent-term-mcp-server--server))
    agent-term-mcp-server--port))

(defun agent-term-mcp-server-session-started (session-id project-dir buffer)
  "Register the session SESSION-ID for PROJECT-DIR shown in BUFFER."
  (puthash session-id
           (list :project-dir project-dir
                 :buffer buffer
                 :last-active-buffer nil)
           agent-term-mcp-server--sessions)
  (agent-term-debug "Registered MCP session for project %s" project-dir))

(defun agent-term-mcp-server-session-ended (session-id)
  "Unregister SESSION-ID; stop the server when no session remains."
  (remhash session-id agent-term-mcp-server--sessions)
  (when (zerop (hash-table-count agent-term-mcp-server--sessions))
    (agent-term-mcp-server--stop-server)))

(defun agent-term-mcp-server-get-config (session-id)
  "Return the MCP client configuration for SESSION-ID, or nil.
The result is an alist that encodes to the JSON object both Copilot
and Claude accept: {\"mcpServers\": {\"emacs-tools\": {...}}}."
  (when-let* ((port (agent-term-mcp-server-get-port)))
    `((mcpServers
       . ((emacs-tools
           . ((type . "http")
              (url . ,(format "http://127.0.0.1:%d/mcp/%s" port session-id)))))))))

(defun agent-term-mcp-server-get-tool-names (&optional prefix)
  "Return a list of registered tool names, each optionally prefixed with PREFIX."
  (mapcar (lambda (spec)
            (let ((name (plist-get spec :name)))
              (if prefix (concat prefix name) name)))
          agent-term-mcp-server-tools))

;;; Session Context

(defun agent-term-mcp-server-get-session-context (&optional session-id)
  "Return the context plist for SESSION-ID (or the current session)."
  (let ((id (or session-id agent-term-mcp-server--current-session-id)))
    (when id (gethash id agent-term-mcp-server--sessions))))

(defun agent-term-mcp-server-update-last-active-buffer (session-id buffer)
  "Set the last active BUFFER for SESSION-ID."
  (when-let* ((session (gethash session-id agent-term-mcp-server--sessions)))
    (unless (eq (plist-get session :last-active-buffer) buffer)
      (puthash session-id (plist-put session :last-active-buffer buffer)
               agent-term-mcp-server--sessions))))

(defun agent-term-mcp-server-expand-file-name (file)
  "Expand FILE relative to the project directory of the current session.
Outside a session, FILE is expanded relative to `default-directory'."
  (expand-file-name
   file (or (plist-get (agent-term-mcp-server-get-session-context) :project-dir)
            default-directory)))

(defmacro agent-term-mcp-server-with-session-context (session-id &rest body)
  "Execute BODY in the context of SESSION-ID (nil means the current session).
Makes the last active buffer (falling back to the session buffer)
current and binds `default-directory' to the project root."
  (declare (indent 1))
  (let ((context (make-symbol "context"))
        (buffer (make-symbol "buffer")))
    `(let* ((,context (agent-term-mcp-server-get-session-context ,session-id))
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

(defun agent-term-mcp-server--start-server ()
  "Start the MCP HTTP server; return its port or nil on failure."
  (condition-case err
      (progn
        (require 'agent-term-mcp-http-server)
        (let ((result (agent-term-mcp-http-server-start agent-term-mcp-server-port)))
          (setq agent-term-mcp-server--server (car result)
                agent-term-mcp-server--port (cdr result))))
    (error
     (agent-term-debug "Failed to start MCP server: %s" (error-message-string err))
     (message "Warning: Failed to start MCP server: %s" (error-message-string err))
     nil)))

(defun agent-term-mcp-server--stop-server ()
  "Stop the MCP HTTP server."
  (when agent-term-mcp-server--server
    (agent-term-mcp-http-server-stop agent-term-mcp-server--server)
    (setq agent-term-mcp-server--server nil
          agent-term-mcp-server--port nil)
    (agent-term-debug "MCP server stopped")))

(provide 'agent-term-mcp-server)

;;; agent-term-mcp-server.el ends here
