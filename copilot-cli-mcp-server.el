;;; copilot-cli-mcp-server.el --- MCP tools server for Copilot CLI  -*- lexical-binding: t; -*-

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
(require 'copilot-cli-debug)

;; Forward declarations
(declare-function ws-process "web-server" (server))
(declare-function copilot-cli-mcp-http-server-start "copilot-cli-mcp-http-server" (&optional port))
(declare-function copilot-cli-mcp-http-server-stop "copilot-cli-mcp-http-server" (server))

;;; Customization

(defgroup copilot-cli-mcp-server nil
  "MCP tools server settings for Copilot CLI."
  :group 'copilot-cli
  :prefix "copilot-cli-mcp-server-")

(defcustom copilot-cli-enable-mcp-server nil
  "Enable MCP tools server for exposing Emacs functions to Copilot.
When enabled, a separate HTTP MCP server will be started to provide
Copilot with access to configured Emacs functions."
  :type 'boolean
  :group 'copilot-cli-mcp-server)

(defcustom copilot-cli-mcp-server-port nil
  "Port for the MCP tools server.
If nil, a random available port will be selected automatically."
  :type '(choice (const :tag "Auto-select" nil)
                 (integer :tag "Fixed port"))
  :group 'copilot-cli-mcp-server)

(defcustom copilot-cli-mcp-server-tools nil
  "List of tool specifications to expose via the MCP tools server.
Use `copilot-cli-make-tool' to register tools."
  :type 'list
  :group 'copilot-cli-mcp-server)

;;; State Management

(defvar copilot-cli-mcp-server--server nil
  "The MCP tools server process.")

(defvar copilot-cli-mcp-server--port nil
  "The port the MCP tools server is running on.")

(defvar copilot-cli-mcp-server--session-count 0
  "Number of active Copilot sessions using the MCP tools server.")

(defvar copilot-cli-mcp-server--sessions (make-hash-table :test 'equal)
  "Hash table mapping session IDs to session contexts.
Each entry is a plist with :project-dir, :buffer, :last-active-buffer.")

(defvar copilot-cli-mcp-server--current-session-id nil
  "The session ID for the current MCP tool request.
Dynamically bound during tool execution.")

;;; Tool Definition

(defun copilot-cli-make-tool (&rest slots)
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
      (add-to-list 'copilot-cli-mcp-server-tools spec)
      spec)))

;;; Internal Tool Normalization

(defun copilot-cli--normalize-tool-spec (tool-spec)
  "Normalize TOOL-SPEC to a consistent plist."
  tool-spec)

;;; Public Functions

(defun copilot-cli-mcp-server-ensure-server ()
  "Ensure the MCP tools server is running.
Returns the port number on success, nil if disabled or failed."
  (when copilot-cli-enable-mcp-server
    (unless (and copilot-cli-mcp-server--server
                 copilot-cli-mcp-server--port
                 (copilot-cli-mcp-server--server-alive-p))
      (copilot-cli-mcp-server--start-server))
    copilot-cli-mcp-server--port))

(defun copilot-cli-mcp-server-get-port ()
  "Get the port number of the running MCP tools server, or nil."
  (when (and copilot-cli-mcp-server--server
             copilot-cli-mcp-server--port
             (copilot-cli-mcp-server--server-alive-p))
    copilot-cli-mcp-server--port))

(defun copilot-cli-mcp-server-session-started (&optional session-id project-dir buffer)
  "Notify the server that a Copilot session started.
Increments the session counter and registers the session."
  (cl-incf copilot-cli-mcp-server--session-count)
  (copilot-cli-debug "MCP session started. Count: %d" copilot-cli-mcp-server--session-count)
  (when (and session-id project-dir buffer)
    (copilot-cli-mcp-server-register-session session-id project-dir buffer)))

(defun copilot-cli-mcp-server-session-ended (&optional session-id)
  "Notify the server that a Copilot session ended.
Decrements the session counter and stops the server when no sessions remain."
  (when session-id
    (copilot-cli-mcp-server-unregister-session session-id))
  (when (> copilot-cli-mcp-server--session-count 0)
    (cl-decf copilot-cli-mcp-server--session-count)
    (copilot-cli-debug "MCP session ended. Count: %d" copilot-cli-mcp-server--session-count)
    (when (= copilot-cli-mcp-server--session-count 0)
      (copilot-cli-mcp-server--stop-server))))

(defun copilot-cli-mcp-server-get-config (&optional session-id)
  "Return the MCP `--mcp-config' JSON structure for passing to Copilot.
SESSION-ID is embedded in the URL path so each session has its own context."
  (when-let* ((port (copilot-cli-mcp-server-get-port)))
    (let* ((path (if session-id (format "/mcp/%s" session-id) "/mcp"))
           (url (format "http://127.0.0.1:%d%s" port path))
           (config `((type . "http") (url . ,url))))
      `((mcpServers . ((emacs-tools . ,config)))))))

(defun copilot-cli-mcp-server-get-tool-names (&optional prefix)
  "Return a list of registered tool names, each optionally prefixed with PREFIX."
  (mapcar (lambda (spec)
            (let ((name (plist-get spec :name)))
              (if prefix (concat prefix name) name)))
          copilot-cli-mcp-server-tools))

;;; Session Management

(defun copilot-cli-mcp-server-register-session (session-id project-dir buffer)
  "Register a session with SESSION-ID, PROJECT-DIR, and BUFFER."
  (puthash session-id
           (list :project-dir project-dir
                 :buffer buffer
                 :last-active-buffer nil
                 :start-time (current-time))
           copilot-cli-mcp-server--sessions)
  (copilot-cli-debug "Registered MCP session %s for project %s" session-id project-dir))

(defun copilot-cli-mcp-server-unregister-session (session-id)
  "Remove the session registered under SESSION-ID."
  (when (gethash session-id copilot-cli-mcp-server--sessions)
    (remhash session-id copilot-cli-mcp-server--sessions)
    (copilot-cli-debug "Unregistered MCP session %s" session-id)))

(defun copilot-cli-mcp-server-get-session-context (&optional session-id)
  "Return the context plist for SESSION-ID (or the current session)."
  (let ((id (or session-id copilot-cli-mcp-server--current-session-id)))
    (when id (gethash id copilot-cli-mcp-server--sessions))))

(defun copilot-cli-mcp-server-update-last-active-buffer (session-id buffer)
  "Set the last active BUFFER for SESSION-ID."
  (when-let* ((session (gethash session-id copilot-cli-mcp-server--sessions)))
    (plist-put session :last-active-buffer buffer)
    (copilot-cli-debug "Updated last active buffer for session %s to %s"
                       session-id (buffer-name buffer))))

(defmacro copilot-cli-mcp-server-with-session-context (session-id &rest body)
  "Execute BODY in the context of SESSION-ID.
Sets `default-directory' to the session project root and makes the
last active buffer (falling back to the registered buffer) current."
  (declare (indent 1))
  `(let* ((context (copilot-cli-mcp-server-get-session-context ,session-id))
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

(defun copilot-cli-mcp-server--server-alive-p ()
  "Return non-nil if the HTTP server process is live."
  (when copilot-cli-mcp-server--server
    (condition-case nil
        (let ((process (ws-process copilot-cli-mcp-server--server)))
          (and process (process-live-p process)))
      (error nil))))

(defun copilot-cli-mcp-server--start-server ()
  "Start the MCP HTTP server."
  (condition-case err
      (progn
        (require 'copilot-cli-mcp-http-server)
        (unless (featurep 'web-server)
          (error "The web-server package is required.  Install it with: M-x package-install RET web-server RET"))
        (let ((result (copilot-cli-mcp-http-server-start copilot-cli-mcp-server-port)))
          (setq copilot-cli-mcp-server--server (car result)
                copilot-cli-mcp-server--port (cdr result))
          copilot-cli-mcp-server--port))
    (error
     (copilot-cli-debug "Failed to start MCP server: %s" (error-message-string err))
     (message "Warning: Failed to start MCP server: %s" (error-message-string err))
     nil)))

(defun copilot-cli-mcp-server--stop-server ()
  "Stop the MCP HTTP server."
  (when copilot-cli-mcp-server--server
    (condition-case err
        (progn
          (copilot-cli-mcp-http-server-stop copilot-cli-mcp-server--server)
          (setq copilot-cli-mcp-server--server nil
                copilot-cli-mcp-server--port nil)
          (clrhash copilot-cli-mcp-server--sessions)
          (copilot-cli-debug "MCP server stopped"))
      (error
       (copilot-cli-debug "Error stopping MCP server: %s" (error-message-string err))))))

(provide 'copilot-cli-mcp-server)

;;; copilot-cli-mcp-server.el ends here
