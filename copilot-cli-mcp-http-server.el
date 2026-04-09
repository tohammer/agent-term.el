;;; copilot-cli-mcp-http-server.el --- HTTP transport for MCP tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, copilot, mcp, http

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

;; HTTP server implementing MCP Streamable HTTP transport for copilot-cli.el.
;; Session IDs are passed via URL paths (e.g. /mcp/SESSION-ID) so multiple
;; concurrent Copilot sessions each get their own Emacs context.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'copilot-cli-debug)
(require 'copilot-cli-mcp-server)

(defvar copilot-cli-mcp-server--current-session-id)

(unless (featurep 'web-server)
  (condition-case err
      (require 'web-server)
    (error
     (copilot-cli-debug "Failed to load web-server package: %s" (error-message-string err)))))

(declare-function ws-process "web-server" (server))
(declare-function ws-start "web-server" (handlers port &optional log-buffer &rest network-args))
(declare-function ws-stop "web-server" (server))
(declare-function ws-send-404 "web-server" (proc &optional info))
(declare-function ws-headers "web-server" (request))
(declare-function ws-body "web-server" (request))
(declare-function ws-send "web-server" (proc msg))
(declare-function ws-response-header "web-server" (proc code &rest headers))

;;; Public Functions

(defun copilot-cli-mcp-http-server-start (&optional port)
  "Start the MCP HTTP server, optionally on PORT (0 = auto).
Returns a cons cell (server . actual-port)."
  (unless (featurep 'web-server)
    (error "web-server package is not available"))
  (copilot-cli-debug "Starting MCP HTTP server on port %s" (or port "auto"))
  (condition-case err
      (let* ((selected-port (or port 0))
             (server (ws-start
                      `(((:GET . "^/mcp\\(/.*\\)?$") . ,#'copilot-cli-mcp-http-server--handle-get)
                        ((:POST . "^/mcp\\(/.*\\)?$") . ,#'copilot-cli-mcp-http-server--handle-post))
                      selected-port
                      nil
                      :host "127.0.0.1")))
        (let* ((process (ws-process server))
               (actual-port (process-contact process :service)))
          (copilot-cli-debug "MCP HTTP server started on port %d" actual-port)
          (set-process-sentinel process
                                (lambda (_proc event)
                                  (when (string-match-p "\\(exited\\|killed\\|terminated\\)" event)
                                    (copilot-cli-debug "MCP HTTP server died unexpectedly"))))
          (cons server actual-port)))
    (error
     (copilot-cli-debug "Failed to start HTTP server: %s" (error-message-string err))
     (signal 'error (list (format "Failed to start MCP HTTP server: %s"
                                  (error-message-string err)))))))

(defun copilot-cli-mcp-http-server-stop (server)
  "Stop the MCP HTTP SERVER."
  (when server (ws-stop server)))

;;; Request Handlers

(defun copilot-cli-mcp-http-server--extract-session-id (headers)
  "Extract session ID from the URL path in HEADERS.
Matches the /mcp/SESSION-ID pattern."
  (let ((url (or (cdr (assoc :POST headers))
                 (cdr (assoc :GET headers)))))
    (when (and url (string-match "^/mcp/\\([^/?]+\\)" url))
      (match-string 1 url))))

(defun copilot-cli-mcp-http-server--handle-get (request)
  "Handle GET requests (not used; return 404)."
  (with-slots (process) request
    (ws-send-404 process)))

(defun copilot-cli-mcp-http-server--handle-post (request)
  "Handle POST requests to /mcp/* endpoints."
  (copilot-cli-debug "MCP HTTP server received POST")
  (condition-case err
      (let* ((headers (ws-headers request))
             (body (ws-body request))
             (session-id (copilot-cli-mcp-http-server--extract-session-id headers))
             (json-object (json-parse-string body :object-type 'alist))
             (method (alist-get 'method json-object))
             (params (alist-get 'params json-object))
             (id (alist-get 'id json-object)))
        (copilot-cli-debug "MCP request - method: %s, id: %s, session: %s" method id session-id)
        (if (null id)
            ;; Notification: no response needed
            (copilot-cli-mcp-http-server--send-empty-response request)
          (let* ((copilot-cli-mcp-server--current-session-id session-id)
                 (result (copilot-cli-mcp-http-server--dispatch method params)))
            (copilot-cli-mcp-http-server--send-json-response
             request 200
             `((jsonrpc . "2.0") (id . ,id) (result . ,result))))))
    (json-parse-error
     (copilot-cli-mcp-http-server--send-json-error request nil -32700 "Parse error"))
    (quit
     (copilot-cli-mcp-http-server--send-json-error request nil -32001 "Operation cancelled by user"))
    (error
     (copilot-cli-debug "Error handling request: %s" (error-message-string err))
     (copilot-cli-mcp-http-server--send-json-error
      request nil -32603 (format "Internal error: %s" (error-message-string err))))))

;;; MCP Protocol Dispatch

(defun copilot-cli-mcp-http-server--dispatch (method params)
  "Dispatch MCP METHOD with PARAMS."
  (pcase method
    ("initialize" (copilot-cli-mcp-http-server--handle-initialize params))
    ("tools/list" (copilot-cli-mcp-http-server--handle-tools-list params))
    ("tools/call" (copilot-cli-mcp-http-server--handle-tools-call params))
    (_ (signal 'json-rpc-error (list -32601 "Method not found")))))

(defun copilot-cli-mcp-http-server--handle-initialize (_params)
  "Handle the MCP initialize request."
  `((protocolVersion . "2024-11-05")
    (capabilities . ((tools . ((listChanged . :json-false)))
                     (logging . ,(make-hash-table :test 'equal))))
    (serverInfo . ((name . "copilot-cli-mcp-tools") (version . "0.1.0")))))

(defun copilot-cli-mcp-http-server--handle-tools-list (_params)
  "Handle tools/list: return all registered tools."
  (let ((tools (mapcar #'copilot-cli-mcp-http-server--tool-to-mcp
                       copilot-cli-mcp-server-tools)))
    (copilot-cli-debug "MCP server returning %d tools" (length tools))
    `((tools . ,tools))))

(defun copilot-cli-mcp-http-server--handle-tools-call (params)
  "Handle tools/call with PARAMS."
  (let* ((tool-name (alist-get 'name params))
         (tool-args (alist-get 'arguments params))
         (tool-spec (cl-find-if
                     (lambda (spec)
                       (string= (plist-get spec :name) tool-name))
                     copilot-cli-mcp-server-tools)))
    (unless tool-spec
      (signal 'json-rpc-error (list -32602 (format "Unknown tool: %s" tool-name))))
    (let* ((tool-function (plist-get tool-spec :function))
           (arg-specs (plist-get tool-spec :args))
           (args (copilot-cli-mcp-http-server--validate-args tool-args arg-specs)))
      (condition-case err
          (let ((result (apply tool-function args)))
            `((content . (((type . "text")
                           (text . ,(copilot-cli-mcp-http-server--format-result result)))))))
        (quit
         `((content . (((type . "text") (text . "Operation cancelled by user"))))))
        (error
         `((content . (((type . "text")
                        (text . ,(format "Error: %s" (error-message-string err))))))))))))

;;; Helper Functions

(defun copilot-cli-mcp-http-server--tool-to-mcp (spec)
  "Convert tool SPEC to MCP wire format."
  (let ((name (plist-get spec :name))
        (description (plist-get spec :description))
        (args (plist-get spec :args)))
    `((name . ,name)
      (description . ,description)
      (inputSchema . ((type . "object")
                      (properties . ,(copilot-cli-mcp-http-server--args-to-schema args))
                      (required . ,(copilot-cli-mcp-http-server--required-args args)))))))

(defun copilot-cli-mcp-http-server--args-to-schema (args)
  "Convert ARGS list to a JSON Schema properties alist."
  (if args
      (let ((schema '()))
        (dolist (arg args (nreverse schema))
          (let* ((name (plist-get arg :name))
                 (type (plist-get arg :type))
                 (desc (plist-get arg :description))
                 (prop `((type . ,(if (symbolp type) (symbol-name type) type)))))
            (when desc (setq prop (append prop `((description . ,desc)))))
            (push (cons (intern name) prop) schema))))
    (make-hash-table :test 'equal)))

(defun copilot-cli-mcp-http-server--required-args (args)
  "Return a vector of required argument names from ARGS."
  (vconcat (delq nil (mapcar (lambda (arg)
                               (unless (plist-get arg :optional)
                                 (plist-get arg :name)))
                             args))))

(defun copilot-cli-mcp-http-server--validate-args (args arg-specs)
  "Validate ARGS against ARG-SPECS; return ordered argument list."
  (let ((result '()))
    (dolist (spec arg-specs (nreverse result))
      (let* ((name (plist-get spec :name))
             (optional (plist-get spec :optional))
             (value (alist-get (intern name) args)))
        (when (and (not optional) (not value))
          (signal 'json-rpc-error (list -32602 (format "Missing required argument: %s" name))))
        (push value result)))))

(defun copilot-cli-mcp-http-server--format-result (result)
  "Format RESULT as a string for the MCP response."
  (cond
   ((stringp result) result)
   ((listp result)
    (mapconcat (lambda (item) (format "%s" item)) result "\n"))
   (t (format "%s" result))))

(defun copilot-cli-mcp-http-server--send-json-response (request status body)
  "Send a JSON response with STATUS and BODY to REQUEST."
  (with-slots (process) request
    (apply #'ws-response-header process status
           '(("Content-Type" . "application/json")
             ("Access-Control-Allow-Origin" . "*")))
    (ws-send process (json-encode body))
    (throw 'close-connection nil)))

(defun copilot-cli-mcp-http-server--send-empty-response (request)
  "Send an empty HTTP 200 response (for notifications)."
  (with-slots (process) request
    (ws-response-header process 200
                        (cons "Content-Type" "text/plain")
                        (cons "Content-Length" "0"))
    (throw 'close-connection nil)))

(defun copilot-cli-mcp-http-server--send-json-error (request id code message)
  "Send a JSON-RPC error response."
  (copilot-cli-mcp-http-server--send-json-response
   request 200
   `((jsonrpc . "2.0") (id . ,id) (error . ((code . ,code) (message . ,message))))))

(provide 'copilot-cli-mcp-http-server)

;;; copilot-cli-mcp-http-server.el ends here
