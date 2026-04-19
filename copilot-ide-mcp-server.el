;;; copilot-ide-mcp-server.el --- MCP tools server for Copilot CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, copilot, mcp, tools

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

;; HTTP MCP tools server that exposes Emacs functions to Copilot CLI.
;; The server lifecycle is managed automatically:
;; - Starts when the first Copilot session begins
;; - Stops when the last Copilot session ends

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'copilot-ide-debug)

;; Forward declarations
(declare-function ws-process "web-server" (server))
(declare-function copilot-ide-mcp-http-server-start "copilot-ide-mcp-http-server" (&optional port))
(declare-function copilot-ide-mcp-http-server-stop "copilot-ide-mcp-http-server" (server))

;;; Customization

(defgroup copilot-ide-mcp-server nil
  "MCP tools server settings for Copilot CLI."
  :group 'copilot-ide
  :prefix "copilot-ide-mcp-server-")

(defcustom copilot-ide-enable-mcp-server nil
  "Enable MCP tools server for exposing Emacs functions to Copilot.
When enabled, a separate HTTP MCP server will be started to provide
Copilot with access to configured Emacs functions."
  :type 'boolean
  :group 'copilot-ide-mcp-server)

(defcustom copilot-ide-mcp-server-port nil
  "Port for the MCP tools server.
If nil, a random available port will be selected automatically."
  :type '(choice (const :tag "Auto-select" nil)
                 (integer :tag "Fixed port"))
  :group 'copilot-ide-mcp-server)

(defcustom copilot-ide-mcp-server-tools nil
  "List of tool specifications to expose via the MCP tools server.
Use `copilot-ide-make-tool' to register tools."
  :type 'list
  :group 'copilot-ide-mcp-server)

;;; State Management

(defvar copilot-ide-mcp-server--server nil
  "The MCP tools server process.")

(defvar copilot-ide-mcp-server--port nil
  "The port the MCP tools server is running on.")

(defvar copilot-ide-mcp-server--session-count 0
  "Number of active Copilot sessions using the MCP tools server.")

(defvar copilot-ide-mcp-server--sessions (make-hash-table :test 'equal)
  "Hash table mapping session IDs to session contexts.
Each entry is a plist with :project-dir, :buffer, :last-active-buffer.")

(defvar copilot-ide-mcp-server--current-session-id nil
  "The session ID for the current MCP tool request.
Dynamically bound during tool execution.")

;;; Tool Definition

(defun copilot-ide-make-tool (&rest slots)
  "Define an MCP tool and register it with the server.

Keyword arguments:
  :name        - Tool name string (required)
  :function    - Elisp function to call (required)
  :description - Human-readable description (required)
  :args        - List of argument plists, each with:
                   :name        - Argument name string
                   :type        - Type symbol (string, number, boolean, ...)
                   :description - Argument description
                   :optional    - Non-nil if argument is optional

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
      (add-to-list 'copilot-ide-mcp-server-tools spec)
      spec)))

;;; Internal Tool Normalization

(defun copilot-ide--normalize-tool-spec (tool-spec)
  "Normalize TOOL-SPEC to a consistent plist."
  tool-spec)

;;; Public Functions

(defun copilot-ide-mcp-server-ensure-server ()
  "Ensure the MCP tools server is running.
Returns the port number on success, nil if disabled or failed."
  (when copilot-ide-enable-mcp-server
    (unless (and copilot-ide-mcp-server--server
                 copilot-ide-mcp-server--port
                 (copilot-ide-mcp-server--server-alive-p))
      (copilot-ide-mcp-server--start-server))
    copilot-ide-mcp-server--port))

(defun copilot-ide-mcp-server-get-port ()
  "Get the port number of the running MCP tools server, or nil."
  (when (and copilot-ide-mcp-server--server
             copilot-ide-mcp-server--port
             (copilot-ide-mcp-server--server-alive-p))
    copilot-ide-mcp-server--port))

(defun copilot-ide-mcp-server-session-started (&optional session-id project-dir buffer)
  "Notify the server that a Copilot session started.
Increments the session counter and registers the session."
  (cl-incf copilot-ide-mcp-server--session-count)
  (copilot-ide-debug "MCP session started. Count: %d" copilot-ide-mcp-server--session-count)
  (when (and session-id project-dir buffer)
    (copilot-ide-mcp-server-register-session session-id project-dir buffer)))

(defun copilot-ide-mcp-server-session-ended (&optional session-id)
  "Notify the server that a Copilot session ended.
Decrements the session counter and stops the server when no sessions remain."
  (when session-id
    (copilot-ide-mcp-server-unregister-session session-id))
  (when (> copilot-ide-mcp-server--session-count 0)
    (cl-decf copilot-ide-mcp-server--session-count)
    (copilot-ide-debug "MCP session ended. Count: %d" copilot-ide-mcp-server--session-count)
    (when (= copilot-ide-mcp-server--session-count 0)
      (copilot-ide-mcp-server--stop-server))))

(defun copilot-ide-mcp-server-get-config (&optional session-id)
  "Return the MCP `--mcp-config' JSON structure for passing to Copilot.
SESSION-ID is embedded in the URL path so each session has its own context."
  (when-let* ((port (copilot-ide-mcp-server-get-port)))
    (let* ((path (if session-id (format "/mcp/%s" session-id) "/mcp"))
           (url (format "http://127.0.0.1:%d%s" port path))
           (config `((type . "http") (url . ,url))))
      `((mcpServers . ((emacs-tools . ,config)))))))

(defun copilot-ide-mcp-server-get-tool-names (&optional prefix)
  "Return a list of registered tool names, each optionally prefixed with PREFIX."
  (mapcar (lambda (spec)
            (let ((name (plist-get spec :name)))
              (if prefix (concat prefix name) name)))
          copilot-ide-mcp-server-tools))

;;; Session Management

(defun copilot-ide-mcp-server-register-session (session-id project-dir buffer)
  "Register a session with SESSION-ID, PROJECT-DIR, and BUFFER."
  (puthash session-id
           (list :project-dir project-dir
                 :buffer buffer
                 :last-active-buffer nil
                 :start-time (current-time))
           copilot-ide-mcp-server--sessions)
  (copilot-ide-debug "Registered MCP session %s for project %s" session-id project-dir))

(defun copilot-ide-mcp-server-unregister-session (session-id)
  "Remove the session registered under SESSION-ID."
  (when (gethash session-id copilot-ide-mcp-server--sessions)
    (remhash session-id copilot-ide-mcp-server--sessions)
    (copilot-ide-debug "Unregistered MCP session %s" session-id)))

(defun copilot-ide-mcp-server-get-session-context (&optional session-id)
  "Return the context plist for SESSION-ID (or the current session)."
  (let ((id (or session-id copilot-ide-mcp-server--current-session-id)))
    (when id (gethash id copilot-ide-mcp-server--sessions))))

(defun copilot-ide-mcp-server-update-last-active-buffer (session-id buffer)
  "Set the last active BUFFER for SESSION-ID."
  (when-let* ((session (gethash session-id copilot-ide-mcp-server--sessions)))
    (plist-put session :last-active-buffer buffer)
    (copilot-ide-debug "Updated last active buffer for session %s to %s"
                       session-id (buffer-name buffer))))

(defmacro copilot-ide-mcp-server-with-session-context (session-id &rest body)
  "Execute BODY in the context of SESSION-ID.
Sets `default-directory' to the session project root and makes the
last active buffer (falling back to the registered buffer) current."
  (declare (indent 1))
  `(let* ((context (copilot-ide-mcp-server-get-session-context ,session-id))
          (project-dir (plist-get context :project-dir))
          (last-active-buffer (plist-get context :last-active-buffer))
          (registered-buffer (plist-get context :buffer))
          (buffer (or (and last-active-buffer
                           (buffer-live-p last-active-buffer)
                           last-active-buffer)
                      (and registered-buffer
                           (buffer-live-p registered-buffer)
                           registered-buffer))))
     (if (not context)
         (error "No session context found for session %s" ,session-id)
       (let ((default-directory (or project-dir default-directory)))
         (if buffer
             (with-current-buffer buffer ,@body)
           ,@body)))))

;;; Internal Functions

(defun copilot-ide-mcp-server--server-alive-p ()
  "Return non-nil if the HTTP server process is live."
  (when copilot-ide-mcp-server--server
    (condition-case nil
        (let ((process (ws-process copilot-ide-mcp-server--server)))
          (and process (process-live-p process)))
      (error nil))))

(defun copilot-ide-mcp-server--start-server ()
  "Start the MCP HTTP server."
  (condition-case err
      (progn
        (require 'copilot-ide-mcp-http-server)
        (unless (featurep 'web-server)
          (error "The web-server package is required.  Install it with: M-x package-install RET web-server RET"))
        (let ((result (copilot-ide-mcp-http-server-start copilot-ide-mcp-server-port)))
          (setq copilot-ide-mcp-server--server (car result)
                copilot-ide-mcp-server--port (cdr result))
          copilot-ide-mcp-server--port))
    (error
     (copilot-ide-debug "Failed to start MCP server: %s" (error-message-string err))
     (message "Warning: Failed to start MCP server: %s" (error-message-string err))
     nil)))

(defun copilot-ide-mcp-server--stop-server ()
  "Stop the MCP HTTP server."
  (when copilot-ide-mcp-server--server
    (condition-case err
        (progn
          (copilot-ide-mcp-http-server-stop copilot-ide-mcp-server--server)
          (setq copilot-ide-mcp-server--server nil
                copilot-ide-mcp-server--port nil)
          (clrhash copilot-ide-mcp-server--sessions)
          (copilot-ide-debug "MCP server stopped"))
      (error
       (copilot-ide-debug "Error stopping MCP server: %s" (error-message-string err))))))

(provide 'copilot-ide-mcp-server)

;;; copilot-ide-mcp-server.el ends here
