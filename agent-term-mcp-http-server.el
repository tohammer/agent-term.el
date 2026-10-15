;;; agent-term-mcp-http-server.el --- HTTP transport for MCP tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Tobias Hammer

;; Keywords: ai, mcp, http
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

;; A minimal HTTP/1.1 server implementing the MCP Streamable HTTP
;; transport (JSON responses only, no SSE stream).
;;
;; Every session gets its own endpoint /mcp/TOKEN, where TOKEN is a
;; random secret that only the agent started by this package knows.
;; Requests for any other path are rejected, so other local processes
;; and web pages cannot call the tools.  Requests that carry a
;; non-local Origin header are rejected as well (DNS rebinding).
;;
;; The server reads the whole body (Content-Length) before it handles
;; a request; each connection carries exactly one request.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'agent-term-debug)
(require 'agent-term-mcp-server)

(define-error 'agent-term-mcp-error "MCP error")

(defconst agent-term-mcp-http-server--protocol-versions
  '("2025-06-18" "2025-03-26" "2024-11-05")
  "MCP protocol versions this server accepts, newest first.")

(defconst agent-term-mcp-http-server--max-request-size (* 16 1024 1024)
  "Largest request (headers and body, in bytes) the server accepts.")

;;; Public Functions

(defun agent-term-mcp-http-server-start (&optional port)
  "Start the MCP HTTP server on 127.0.0.1, on PORT or a free port.
Return a cons cell (SERVER-PROCESS . ACTUAL-PORT)."
  (let* ((server (make-network-process
                  :name "agent-term-mcp"
                  :server t
                  :host "127.0.0.1"
                  :family 'ipv4
                  :service (or port 0)
                  :coding 'binary
                  :noquery t
                  :filter #'agent-term-mcp-http-server--filter))
         (actual-port (process-contact server :service)))
    (agent-term-debug "MCP HTTP server started on port %d" actual-port)
    (cons server actual-port)))

(defun agent-term-mcp-http-server-stop (server)
  "Stop the MCP HTTP SERVER process."
  (when (processp server)
    (delete-process server)))

;;; Connection Handling

(defun agent-term-mcp-http-server--filter (proc string)
  "Collect STRING from connection PROC and handle a complete request."
  (let ((pending (concat (or (process-get proc 'pending) "") string)))
    (process-put proc 'pending pending)
    (cond
     ((> (length pending) agent-term-mcp-http-server--max-request-size)
      (agent-term-mcp-http-server--respond proc 413 "text/plain" "Too large"))
     ((process-get proc 'handled) nil)
     (t
      (when-let* ((request (agent-term-mcp-http-server--parse pending)))
        (process-put proc 'handled t)
        (agent-term-mcp-http-server--handle proc request))))))

(defun agent-term-mcp-http-server--parse (data)
  "Parse the HTTP request in unibyte DATA.
Return a plist (:method :path :headers :body), or nil while the
request is still incomplete.  Header names are downcased."
  (when-let* ((end (string-search "\r\n\r\n" data)))
    (let* ((lines (split-string (substring data 0 end) "\r\n"))
           (request-line (split-string (car lines) " "))
           (headers (delq nil
                          (mapcar (lambda (line)
                                    (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
                                      (cons (downcase (match-string 1 line))
                                            (string-trim (match-string 2 line)))))
                                  (cdr lines))))
           (length (string-to-number
                    (or (cdr (assoc "content-length" headers)) "0")))
           (body-start (+ end 4)))
      (when (>= (length data) (+ body-start length))
        (list :method (car request-line)
              :path (or (cadr request-line) "")
              :headers headers
              :body (substring data body-start (+ body-start length)))))))

(defun agent-term-mcp-http-server--respond (proc status content-type body
                                                 &optional extra-headers)
  "Send an HTTP response with STATUS, CONTENT-TYPE and BODY on PROC.
EXTRA-HEADERS is an alist of additional header names and values.
The connection is closed afterwards."
  (let ((payload (encode-coding-string (or body "") 'utf-8)))
    (when (process-live-p proc)
      (process-send-string
       proc
       (concat (format "HTTP/1.1 %d %s\r\n" status
                       (pcase status
                         (200 "OK") (202 "Accepted") (400 "Bad Request")
                         (403 "Forbidden") (404 "Not Found")
                         (405 "Method Not Allowed") (413 "Payload Too Large")
                         (_ "Error")))
               (if content-type (format "Content-Type: %s\r\n" content-type) "")
               (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h)))
                          extra-headers "")
               (format "Content-Length: %d\r\n" (length payload))
               "Connection: close\r\n\r\n"
               payload))
      (delete-process proc))))

(defun agent-term-mcp-http-server--local-origin-p (origin)
  "Return non-nil if ORIGIN is absent or names the local host."
  (or (null origin)
      (string-match-p
       "\\`https?://\\(localhost\\|127\\.0\\.0\\.1\\|\\[::1\\]\\)\\(:[0-9]+\\)?\\'"
       origin)))

(defun agent-term-mcp-http-server--session-id (path)
  "Return the session token from PATH (/mcp/TOKEN), or nil."
  (when (string-match "\\`/mcp/\\([^/?#]+\\)\\(?:[?#].*\\)?\\'" path)
    (match-string 1 path)))

(defun agent-term-mcp-http-server--handle (proc request)
  "Answer REQUEST, a plist from `agent-term-mcp-http-server--parse', on PROC."
  (let* ((headers (plist-get request :headers))
         (session-id (agent-term-mcp-http-server--session-id
                      (plist-get request :path))))
    (cond
     ((not (agent-term-mcp-http-server--local-origin-p
            (cdr (assoc "origin" headers))))
      (agent-term-mcp-http-server--respond proc 403 "text/plain" "Forbidden"))
     ((not (and session-id (agent-term-mcp-server-get-session-context session-id)))
      (agent-term-debug "MCP request for unknown path %s" (plist-get request :path))
      (agent-term-mcp-http-server--respond proc 404 "text/plain" "Not Found"))
     ((not (equal (plist-get request :method) "POST"))
      (agent-term-mcp-http-server--respond proc 405 "text/plain" "Method Not Allowed"
                                            '(("Allow" . "POST"))))
     (t
      (agent-term-mcp-http-server--handle-post
       proc session-id (decode-coding-string (plist-get request :body) 'utf-8))))))

(defun agent-term-mcp-http-server--handle-post (proc session-id body)
  "Handle the JSON-RPC message BODY for SESSION-ID and answer on PROC."
  (let ((message (condition-case nil
                     (json-parse-string body :object-type 'alist
                                        :null-object nil :false-object :false)
                   (error 'invalid))))
    (cond
     ((eq message 'invalid)
      (agent-term-mcp-http-server--send-json
       proc (agent-term-mcp-http-server--error-message nil -32700 "Parse error")))
     ((or (not (consp message)) (not (alist-get 'method message)))
      ;; A JSON-RPC response or notification batch: nothing to answer.
      (agent-term-mcp-http-server--respond proc 202 nil nil))
     ((not (assq 'id message))
      ;; Notification (e.g. notifications/initialized).
      (agent-term-mcp-http-server--respond proc 202 nil nil))
     (t
      (agent-term-mcp-http-server--send-json
       proc (agent-term-mcp-http-server--process-request session-id message))))))

(defun agent-term-mcp-http-server--process-request (session-id message)
  "Return the JSON-RPC response alist for request MESSAGE of SESSION-ID."
  (let ((id (alist-get 'id message))
        (method (alist-get 'method message))
        (params (alist-get 'params message)))
    (agent-term-debug "MCP request - method: %s, id: %s, session: %s"
                       method id session-id)
    (condition-case err
        (let ((agent-term-mcp-server--current-session-id session-id))
          `((jsonrpc . "2.0") (id . ,id)
            (result . ,(agent-term-mcp-http-server--dispatch method params))))
      (agent-term-mcp-error
       (agent-term-mcp-http-server--error-message id (nth 1 err) (nth 2 err)))
      (error
       (agent-term-debug "Error handling request: %s" (error-message-string err))
       (agent-term-mcp-http-server--error-message
        id -32603 (format "Internal error: %s" (error-message-string err)))))))

(defun agent-term-mcp-http-server--error-message (id code message)
  "Return a JSON-RPC error response alist for request ID with CODE and MESSAGE."
  `((jsonrpc . "2.0") (id . ,id) (error . ((code . ,code) (message . ,message)))))

(defun agent-term-mcp-http-server--send-json (proc object)
  "Send OBJECT as a JSON 200 response on PROC."
  (agent-term-mcp-http-server--respond proc 200 "application/json"
                                        (json-encode object)))

;;; MCP Protocol Dispatch

(defun agent-term-mcp-http-server--dispatch (method params)
  "Dispatch MCP METHOD with PARAMS and return the result."
  (pcase method
    ("initialize" (agent-term-mcp-http-server--handle-initialize params))
    ("ping" (make-hash-table))
    ("tools/list" (agent-term-mcp-http-server--handle-tools-list))
    ("tools/call" (agent-term-mcp-http-server--handle-tools-call params))
    (_ (signal 'agent-term-mcp-error
               (list -32601 (format "Method not found: %s" method))))))

(defun agent-term-mcp-http-server--handle-initialize (params)
  "Handle the MCP initialize request with PARAMS."
  (let ((requested (alist-get 'protocolVersion params)))
    `((protocolVersion . ,(if (member requested agent-term-mcp-http-server--protocol-versions)
                              requested
                            (car agent-term-mcp-http-server--protocol-versions)))
      (capabilities . ((tools . ((listChanged . :json-false)))))
      (serverInfo . ((name . "emacs-tools") (version . "0.1.0"))))))

(defun agent-term-mcp-http-server--handle-tools-list ()
  "Handle tools/list: return all registered tools."
  (let ((tools (mapcar #'agent-term-mcp-http-server--tool-to-mcp
                       agent-term-mcp-server-tools)))
    (agent-term-debug "MCP server returning %d tools" (length tools))
    `((tools . ,(vconcat tools)))))

(defun agent-term-mcp-http-server--handle-tools-call (params)
  "Handle tools/call with PARAMS.
Errors raised by the tool are returned as a result with isError set,
as the MCP specification requires."
  (let* ((tool-name (alist-get 'name params))
         (tool-spec (cl-find tool-name agent-term-mcp-server-tools
                             :key (lambda (spec) (plist-get spec :name))
                             :test #'equal)))
    (unless tool-spec
      (signal 'agent-term-mcp-error
              (list -32602 (format "Unknown tool: %s" tool-name))))
    (let ((args (agent-term-mcp-http-server--validate-args
                 (alist-get 'arguments params) (plist-get tool-spec :args))))
      (condition-case err
          `((content . [((type . "text")
                         (text . ,(agent-term-mcp-http-server--format-result
                                   (apply (plist-get tool-spec :function) args))))]))
        (quit
         '((content . [((type . "text") (text . "Operation cancelled by user"))])
           (isError . t)))
        (error
         `((content . [((type . "text")
                        (text . ,(format "Error: %s" (error-message-string err))))])
           (isError . t)))))))

;;; Helper Functions

(defun agent-term-mcp-http-server--tool-to-mcp (spec)
  "Convert tool SPEC to MCP wire format."
  (let ((args (plist-get spec :args)))
    `((name . ,(plist-get spec :name))
      (description . ,(plist-get spec :description))
      (inputSchema . ((type . "object")
                      (properties . ,(agent-term-mcp-http-server--args-to-schema args))
                      (required . ,(agent-term-mcp-http-server--required-args args)))))))

(defun agent-term-mcp-http-server--args-to-schema (args)
  "Convert ARGS list to a JSON Schema properties object."
  (let ((schema (make-hash-table :test 'equal)))
    (dolist (arg args schema)
      (let ((type (plist-get arg :type))
            (desc (plist-get arg :description)))
        (puthash (plist-get arg :name)
                 `((type . ,(if (symbolp type) (symbol-name type) type))
                   ,@(when desc `((description . ,desc))))
                 schema)))))

(defun agent-term-mcp-http-server--required-args (args)
  "Return a vector of required argument names from ARGS."
  (vconcat (delq nil (mapcar (lambda (arg)
                               (unless (plist-get arg :optional)
                                 (plist-get arg :name)))
                             args))))

(defun agent-term-mcp-http-server--validate-args (args arg-specs)
  "Return the values in ARGS ordered as in ARG-SPECS.
JSON false (`:false') and null are passed on as nil.  Signal an MCP
error when a required argument is missing or null."
  (mapcar (lambda (spec)
            (let* ((name (plist-get spec :name))
                   (value (alist-get (intern name) args)))
              (when (and (not (plist-get spec :optional)) (null value))
                (signal 'agent-term-mcp-error
                        (list -32602 (format "Missing required argument: %s" name))))
              (unless (eq value :false) value)))
          arg-specs))

(defun agent-term-mcp-http-server--format-result (result)
  "Format RESULT as a string for the MCP response."
  (cond
   ((stringp result) result)
   ((and result (listp result))
    (mapconcat (lambda (item) (format "%s" item)) result "\n"))
   (t (format "%s" result))))

(provide 'agent-term-mcp-http-server)

;;; agent-term-mcp-http-server.el ends here
