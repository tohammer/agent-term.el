;;; agent-term-test.el --- Tests for agent-term  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run with `make test'.  The session tests need ghostel and its native
;; module and are skipped without them; they run test/fake-agent in
;; place of a real agent CLI.

;;; Code:

(require 'ert)
(require 'agent-term)
(require 'agent-term-mcp-http-server)

(defconst agent-term-test--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this file.")

(defconst agent-term-test--fake-agent
  (expand-file-name "fake-agent" agent-term-test--dir))

;;; Helpers

(defmacro agent-term-test--with-clean-state (&rest body)
  "Run BODY with fresh session tables, default options and no MCP server."
  (declare (indent 0))
  `(let ((agent-term--sessions (make-hash-table :test 'equal))
         (agent-term-mcp-server--sessions (make-hash-table :test 'equal))
         (agent-term-mcp-server--server nil)
         (agent-term-mcp-server--port nil)
         (agent-term-mcp-server-tools nil)
         (agent-term-enable-mcp-server nil)
         (agent-term-agent 'copilot)
         (agent-term-cli-path nil)
         (agent-term-cli-extra-flags "")
         (agent-term-environment nil)
         (agent-term-use-side-window nil)
         (agent-term-emacs-keybindings nil)
         (agent-term-mcp-available-tools nil)
         (agent-term-mcp-excluded-tools nil)
         (agent-term-mcp-allow-tools nil)
         (agent-term-mcp-deny-tools nil))
     (unwind-protect
         (progn ,@body)
       (agent-term-mcp-server--stop-server))))

(defun agent-term-test--http (request)
  "Send raw REQUEST (a string or list of strings) to the MCP server.
Strings in a list are sent as separate writes.  Return (STATUS . BODY)."
  (let* ((out "")
         (proc (make-network-process
                :name "agent-term-test-client" :host "127.0.0.1"
                :service (agent-term-mcp-server-get-port) :coding 'binary
                :filter (lambda (_p s) (setq out (concat out s))))))
    (dolist (part (if (listp request) request (list request)))
      (process-send-string proc part)
      (accept-process-output nil 0.05))
    (let ((deadline (+ (float-time) 5)))
      (while (and (process-live-p proc) (< (float-time) deadline))
        (accept-process-output proc 0.05)))
    (delete-process proc)
    (when (string-match "\\`HTTP/1\\.1 \\([0-9]+\\)" out)
      (cons (string-to-number (match-string 1 out))
            (decode-coding-string
             (substring out (+ 4 (string-search "\r\n\r\n" out))) 'utf-8)))))

(defun agent-term-test--post (path body &optional extra-headers)
  "POST BODY to PATH with EXTRA-HEADERS (a string).  Return (STATUS . BODY)."
  (let ((payload (encode-coding-string body 'utf-8)))
    (agent-term-test--http
     (format "POST %s HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n%sContent-Length: %d\r\n\r\n%s"
             path (or extra-headers "") (length payload) payload))))

(defun agent-term-test--rpc (session-id method &optional params)
  "Call METHOD with PARAMS on SESSION-ID; return the parsed response."
  (let ((response (agent-term-test--post
                   (concat "/mcp/" session-id)
                   (json-encode `((jsonrpc . "2.0") (id . 42) (method . ,method)
                                  ,@(when params `((params . ,params))))))))
    (should (equal (car response) 200))
    (json-parse-string (cdr response) :object-type 'alist)))

(defmacro agent-term-test--with-mcp-session (session-id &rest body)
  "Run BODY with the MCP server running and SESSION-ID registered."
  (declare (indent 1))
  `(agent-term-test--with-clean-state
     (setq agent-term-enable-mcp-server t)
     (should (agent-term-mcp-server-ensure-server))
     (let ((,session-id (agent-term-mcp-server-new-session-id)))
       (agent-term-mcp-server-session-started ,session-id temporary-file-directory nil)
       ,@body)))

(defun agent-term-test--ghostel-p ()
  "Return non-nil if ghostel and its native module can be loaded."
  (and (require 'ghostel nil t)
       (ignore-errors (ghostel--load-module t) t)))

(defun agent-term-test--wait-for (predicate &optional timeout)
  "Process output until PREDICATE returns non-nil or TIMEOUT seconds pass."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defun agent-term-test--read-log (file)
  "Return the contents of FILE, or the empty string."
  (if (file-exists-p file)
      (with-temp-buffer (insert-file-contents file) (buffer-string))
    ""))

(defmacro agent-term-test--with-agent-env (log &rest body)
  "Run BODY with the fake agent configured; LOG is bound to its log file."
  (declare (indent 1))
  `(agent-term-test--with-clean-state
     (let* ((,log (make-temp-file "agent-term-log"))
            (agent-term-cli-path agent-term-test--fake-agent)
            (agent-term-environment (list (concat "FAKE_AGENT_LOG=" ,log))))
       (unwind-protect
           (progn ,@body)
         (dolist (s (agent-term--live-sessions))
           (let ((kill-buffer-query-functions nil))
             (kill-buffer (agent-term--session-buffer s))))
         (delete-file ,log)))))

;;; Command line

(ert-deftest agent-term-test-args-resume-and-extra-flags ()
  "Resume and extra flags become separate argv entries; quoting is honored."
  (agent-term-test--with-clean-state
    (setq agent-term-cli-extra-flags "--model \"a b\" --banner")
    (should (equal (agent-term--build-args 'copilot "id" nil "abc")
                   '("--resume" "abc" "--model" "a b" "--banner")))
    (should (equal (agent-term--build-args 'claude "id" t nil)
                   '("--continue" "--model" "a b" "--banner")))
    (should (equal (agent-term--build-args 'claude "id" nil t)
                   '("--resume" "--model" "a b" "--banner")))))

(ert-deftest agent-term-test-args-copilot-tool-flags ()
  "Copilot gets its four tool flags, entries passed verbatim."
  (agent-term-test--with-clean-state
    (setq agent-term-mcp-available-tools '("a" "b(x)")
          agent-term-mcp-excluded-tools '("c")
          agent-term-mcp-allow-tools '("shell(git)")
          agent-term-mcp-deny-tools '("d(rm)"))
    (should (equal (agent-term--build-args 'copilot "id")
                   '("--available-tools=a,b(x)" "--allow-tool=shell(git)"
                     "--excluded-tools=c" "--deny-tool=d(rm)")))))

(ert-deftest agent-term-test-args-claude-tool-flags ()
  "Claude merges excluded and denied tools and ignores available tools."
  (agent-term-test--with-clean-state
    (setq agent-term-mcp-excluded-tools '("mcp__x")
          agent-term-mcp-allow-tools '("mcp__emacs-tools" "Bash(git log:*)")
          agent-term-mcp-deny-tools '("Bash(rm:*)"))
    (should (equal (agent-term--build-args 'claude "id")
                   '("--allowedTools=mcp__emacs-tools,Bash(git log:*)"
                     "--disallowedTools=mcp__x,Bash(rm:*)")))
    (setq agent-term-mcp-available-tools '("a"))
    (let ((warned nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (&rest _) (setq warned t))))
        (should (equal (agent-term--build-args 'claude "id")
                       '("--allowedTools=mcp__emacs-tools,Bash(git log:*)"
                         "--disallowedTools=mcp__x,Bash(rm:*)"))))
      (should warned))))

(ert-deftest agent-term-test-args-mcp-config ()
  "The MCP config is one argv entry with the agent's flag and session URL."
  (agent-term-test--with-clean-state
    (setq agent-term-enable-mcp-server t)
    (dolist (case '((copilot . "--additional-mcp-config=") (claude . "--mcp-config=")))
      (let* ((arg (car (last (agent-term--build-args (car case) "tok123"))))
             (json (substring arg (length (cdr case))))
             (config (json-parse-string json :object-type 'alist)))
        (should (string-prefix-p (cdr case) arg))
        (should (equal (alist-get 'type (alist-get 'emacs-tools (alist-get 'mcpServers config)))
                       "http"))
        (should (string-match-p
                 (format "\\`http://127\\.0\\.0\\.1:%d/mcp/tok123\\'"
                         (agent-term-mcp-server-get-port))
                 (alist-get 'url (alist-get 'emacs-tools (alist-get 'mcpServers config)))))))))

;;; MCP server

(ert-deftest agent-term-test-session-id-random ()
  "Session ids are 32 hex digits and differ."
  (let ((a (agent-term-mcp-server-new-session-id))
        (b (agent-term-mcp-server-new-session-id)))
    (should (string-match-p "\\`[0-9a-f]\\{32\\}\\'" a))
    (should-not (equal a b))))

(ert-deftest agent-term-test-mcp-rejects-unknown-session ()
  "Requests without a registered session token run no tool."
  (agent-term-test--with-mcp-session _id
    (let ((called nil))
      (agent-term-make-tool :name "t" :description "d"
                             :function (lambda () (setq called t) "x"))
      (dolist (path '("/mcp" "/mcp/" "/mcp/wrong" "/other"))
        (should (equal (car (agent-term-test--post
                             path "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"t\"}}"))
                       404)))
      (should-not called))))

(ert-deftest agent-term-test-mcp-rejects-foreign-origin ()
  "A request from a web page origin is refused; a local one is served."
  (agent-term-test--with-mcp-session id
    (let ((body "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"))
      (should (equal (car (agent-term-test--post (concat "/mcp/" id) body
                                                   "Origin: https://example.com\r\n"))
                     403))
      (should (equal (car (agent-term-test--post (concat "/mcp/" id) body
                                                   "Origin: http://localhost:3000\r\n"))
                     200)))))

(ert-deftest agent-term-test-mcp-error-codes ()
  "Unknown methods and tools give JSON-RPC errors with the request id."
  (agent-term-test--with-mcp-session id
    (let ((r (agent-term-test--rpc id "bogus")))
      (should (equal (alist-get 'id r) 42))
      (should (equal (alist-get 'code (alist-get 'error r)) -32601)))
    (let ((r (agent-term-test--rpc id "tools/call" '((name . "nope")))))
      (should (equal (alist-get 'id r) 42))
      (should (equal (alist-get 'code (alist-get 'error r)) -32602)))))

(ert-deftest agent-term-test-mcp-missing-required-argument ()
  "A missing required argument is an invalid-params error."
  (agent-term-test--with-mcp-session id
    (agent-term-make-tool :name "t" :description "d" :function #'identity
                           :args '((:name "x" :type string :description "x")))
    (let ((r (agent-term-test--rpc id "tools/call" `((name . "t") (arguments . ,(make-hash-table))))))
      (should (equal (alist-get 'code (alist-get 'error r)) -32602)))))

(ert-deftest agent-term-test-mcp-false-and-null-are-nil ()
  "JSON false and null reach the tool function as nil."
  (agent-term-test--with-mcp-session id
    (agent-term-make-tool :name "t" :description "d"
                           :function (lambda (a b c) (format "%S %S %S" a b c))
                           :args '((:name "a" :type boolean :optional t)
                                   (:name "b" :type string :optional t)
                                   (:name "c" :type boolean :optional t)))
    (let* ((response (agent-term-test--post
                      (concat "/mcp/" id)
                      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"t\",\"arguments\":{\"a\":false,\"b\":null,\"c\":true}}}"))
           (r (json-parse-string (cdr response) :object-type 'alist)))
      (should (equal (alist-get 'text (aref (alist-get 'content (alist-get 'result r)) 0))
                     "nil nil t")))))

(ert-deftest agent-term-test-mcp-required-false-is-present ()
  "A required boolean argument given as false is not missing."
  (agent-term-test--with-mcp-session id
    (agent-term-make-tool :name "t" :description "d"
                           :function (lambda (flag) (format "%S" flag))
                           :args '((:name "flag" :type boolean :description "f")))
    (let* ((response (agent-term-test--post
                      (concat "/mcp/" id)
                      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"t\",\"arguments\":{\"flag\":false}}}"))
           (r (json-parse-string (cdr response) :object-type 'alist)))
      (should (equal (alist-get 'text (aref (alist-get 'content (alist-get 'result r)) 0))
                     "nil")))))

(ert-deftest agent-term-test-mcp-tool-error-is-error-result ()
  "An error in the tool becomes a result with isError set."
  (agent-term-test--with-mcp-session id
    (agent-term-make-tool :name "t" :description "d"
                           :function (lambda () (error "Boom")))
    (let* ((r (agent-term-test--rpc id "tools/call" '((name . "t"))))
           (result (alist-get 'result r)))
      (should (eq (alist-get 'isError result) t))
      (should (equal (alist-get 'text (aref (alist-get 'content result) 0))
                     "Error: Boom")))))

(ert-deftest agent-term-test-mcp-tool-runs-in-project-directory ()
  "Tools run with `default-directory' set to the session project."
  (agent-term-test--with-mcp-session id
    (agent-term-make-tool :name "pwd" :description "d"
                           :function (lambda ()
                                       (agent-term-mcp-server-with-session-context nil
                                         default-directory)))
    (let ((r (agent-term-test--rpc id "tools/call" '((name . "pwd")))))
      (should (equal (alist-get 'text (aref (alist-get 'content (alist-get 'result r)) 0))
                     temporary-file-directory)))))

(ert-deftest agent-term-test-mcp-notification-and-get ()
  "Notifications get 202, GET gets 405."
  (agent-term-test--with-mcp-session id
    (should (equal (car (agent-term-test--post
                         (concat "/mcp/" id)
                         "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"))
                   202))
    (should (equal (car (agent-term-test--http
                         (format "GET /mcp/%s HTTP/1.1\r\nHost: x\r\n\r\n" id)))
                   405))))

(ert-deftest agent-term-test-mcp-body-in-separate-write ()
  "A body that arrives after the headers is still read completely."
  (agent-term-test--with-mcp-session id
    (let* ((body "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}")
           (response (agent-term-test--http
                      (list (format "POST /mcp/%s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
                                    id (length body))
                            (substring body 0 10)
                            (substring body 10)))))
      (should (equal (car response) 200))
      (should (equal (alist-get 'id (json-parse-string (cdr response) :object-type 'alist))
                     9)))))

(ert-deftest agent-term-test-mcp-initialize-and-list ()
  "initialize negotiates the version; tools/list returns the tools."
  (agent-term-test--with-mcp-session id
    (agent-term-make-tool :name "t" :description "d" :function #'ignore
                           :args '((:name "x" :type string :description "x")))
    (let ((r (agent-term-test--rpc id "initialize" '((protocolVersion . "2025-03-26")))))
      (should (equal (alist-get 'protocolVersion (alist-get 'result r)) "2025-03-26")))
    (let ((r (agent-term-test--rpc id "initialize" '((protocolVersion . "1999-01-01")))))
      (should (equal (alist-get 'protocolVersion (alist-get 'result r)) "2025-06-18")))
    (let* ((tools (alist-get 'tools (alist-get 'result (agent-term-test--rpc id "tools/list"))))
           (tool (aref tools 0)))
      (should (equal (length tools) 1))
      (should (equal (alist-get 'required (alist-get 'inputSchema tool)) ["x"])))))

(ert-deftest agent-term-test-make-tool-replaces-by-name ()
  "Registering a tool again under the same name replaces it."
  (agent-term-test--with-clean-state
    (agent-term-make-tool :name "t" :description "old" :function #'ignore)
    (agent-term-make-tool :name "t" :description "new" :function #'ignore)
    (should (equal (mapcar (lambda (s) (plist-get s :description))
                           agent-term-mcp-server-tools)
                   '("new")))))

(ert-deftest agent-term-test-server-stops-with-last-session ()
  "The MCP server stops when the last session ends."
  (agent-term-test--with-mcp-session id
    (let ((second (agent-term-mcp-server-new-session-id)))
      (agent-term-mcp-server-session-started second "/" nil)
      (agent-term-mcp-server-session-ended id)
      (should (agent-term-mcp-server-get-port))
      (agent-term-mcp-server-session-ended second)
      (should-not (agent-term-mcp-server-get-port)))))

;;; Emacs tools

(ert-deftest agent-term-test-relative-path-uses-project ()
  "Relative file paths are resolved against the session project."
  (agent-term-test--with-clean-state
    (let* ((project (file-name-as-directory (make-temp-file "proj" t)))
           (file (expand-file-name "a.txt" project))
           (other (get-buffer-create "*other*"))
           (id "s"))
      (unwind-protect
          (progn
            (with-temp-file file (insert "on disk"))
            (with-current-buffer (find-file-noselect file)
              (erase-buffer) (insert "unsaved"))
            (with-current-buffer other (setq default-directory "/"))
            (agent-term-mcp-server-session-started id project other)
            (agent-term-mcp-server-update-last-active-buffer id other)
            (let ((agent-term-mcp-server--current-session-id id))
              (with-current-buffer other
                (should (equal (agent-term-mcp-get-buffer-content "a.txt") "unsaved"))
                (should (eq (agent-term-mcp--get-xref-buffer "a.txt")
                            (find-buffer-visiting file))))))
        (let ((buf (find-buffer-visiting file)))
          (when buf (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf)))
        (kill-buffer other)
        (delete-directory project t)))))

(ert-deftest agent-term-test-grep-definitions-only ()
  "The definitions grep matches the identifier, not every def/class line."
  (let ((project (make-temp-file "proj" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.py" project)
            (insert "def other():\n    pass\nclass Unrelated:\n    pass\n"
                    "def target():\n    pass\nx = target()\n"))
          (let ((defs (agent-term-mcp--grep-symbol-in-project "target" project t))
                (refs (agent-term-mcp--grep-symbol-in-project "target" project)))
            (should (equal (length defs) 1))
            (should (string-match-p "def target" (car defs)))
            (should (equal (length refs) 2))))
      (delete-directory project t))))

;;; Sessions (ghostel)

(ert-deftest agent-term-test-session-environment-and-args ()
  "The agent gets `agent-term-environment' and its arguments."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-agent-env log
    (let ((agent-term-environment (cons "FAKE_VAR=hello" agent-term-environment))
          (agent-term-cli-extra-flags "--x \"a b\"")
          (default-directory temporary-file-directory))
      (agent-term)
      (should (agent-term-test--wait-for
               (lambda () (string-match-p "READY" (agent-term-test--read-log log)))))
      (let ((text (agent-term-test--read-log log)))
        (should (string-match-p "^ENV:FAKE_VAR=hello$" text))
        (should (string-match-p "^ARG:a b$" text))))))

(ert-deftest agent-term-test-session-keys-are-buffer-local ()
  "Session key overrides do not leak into other ghostel buffers."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-agent-env _log
    (let ((default-directory temporary-file-directory)
          (other (get-buffer-create "*plain-ghostel*")))
      (unwind-protect
          (let ((session (agent-term--create-session 'copilot default-directory)))
            (ghostel-exec other "/bin/sh" '("-c" "sleep 5"))
            (with-current-buffer (agent-term--session-buffer session)
              (should (eq (key-binding (kbd "S-<return>")) #'agent-term-insert-newline)))
            (with-current-buffer other
              (should-not (eq (key-binding (kbd "S-<return>")) #'agent-term-insert-newline))
              (should-not (eq (key-binding (kbd "C-<escape>")) #'agent-term-send-escape))))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer other))))))

(ert-deftest agent-term-test-same-basename-projects ()
  "Projects with the same directory name get separate buffers."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-agent-env _log
    (let* ((root (make-temp-file "roots" t))
           (a (file-name-as-directory (expand-file-name "x/src" root)))
           (b (file-name-as-directory (expand-file-name "y/src" root))))
      (make-directory a t)
      (make-directory b t)
      (unwind-protect
          (let ((sa (agent-term--create-session 'copilot a))
                (sb (agent-term--create-session 'copilot b)))
            (should-not (eq (agent-term--session-buffer sa) (agent-term--session-buffer sb)))
            (should (process-live-p (agent-term--session-process sa)))
            (should (process-live-p (agent-term--session-process sb)))
            (let ((default-directory b))
              (agent-term-stop))
            (should (buffer-live-p (agent-term--session-buffer sa)))
            (should-not (buffer-live-p (agent-term--session-buffer sb)))
            (should (eq (gethash a agent-term--sessions) sa))
            (should-not (gethash b agent-term--sessions)))
        (delete-directory root t)))))

(ert-deftest agent-term-test-agent-exit-ends-session ()
  "When the agent exits, the session, its buffer and MCP entry go away."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-agent-env _log
    (let* ((agent-term-enable-mcp-server t)
           (agent-term-cli-extra-flags "--exit-now")
           (dir temporary-file-directory)
           (session (agent-term--create-session 'claude dir)))
      (should (agent-term-mcp-server-get-session-context (agent-term--session-id session)))
      (should (agent-term-test--wait-for
               (lambda () (not (buffer-live-p (agent-term--session-buffer session))))))
      (should-not (gethash dir agent-term--sessions))
      (should-not (agent-term-mcp-server-get-session-context (agent-term--session-id session)))
      (should-not (agent-term-mcp-server-get-port)))))

(ert-deftest agent-term-test-failed-start-cleans-up ()
  "A missing agent executable leaves no buffer or session behind."
  (agent-term-test--with-clean-state
    (let ((agent-term-cli-path "/nonexistent/agent")
          (buffers (buffer-list)))
      (should-error (agent-term--create-session 'copilot temporary-file-directory)
                    :type 'user-error)
      (should (equal (hash-table-count agent-term--sessions) 0))
      (should (equal (buffer-list) buffers)))))

(ert-deftest agent-term-test-toggle-in-single-window ()
  "Toggling without side windows works when the session fills the frame."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-agent-env _log
    (let ((default-directory temporary-file-directory)
          (start (get-buffer-create "*start*")))
      (with-current-buffer start (setq default-directory temporary-file-directory))
      (delete-other-windows)
      (switch-to-buffer start)
      (agent-term)
      (let ((buffer (window-buffer (selected-window))))
        (should (agent-term--current-session))
        (should (buffer-local-value 'agent-term--buffer-session buffer))
        (agent-term-toggle)
        (should (eq (window-buffer (selected-window)) start))
        (agent-term-toggle)
        (should (eq (window-buffer (selected-window)) buffer)))
      (kill-buffer start))))

(ert-deftest agent-term-test-send-prompt-from-session-buffer ()
  "Prompts sent from the session buffer reach that session's agent."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-agent-env log
    (let* ((default-directory temporary-file-directory)
           (session (agent-term--create-session 'copilot default-directory)))
      (should (agent-term-test--wait-for
               (lambda () (string-match-p "READY" (agent-term-test--read-log log)))))
      (with-current-buffer (agent-term--session-buffer session)
        ;; The session buffer must be found without a project lookup.
        (let ((default-directory "/"))
          (agent-term-send-prompt "hello agent")))
      (should (agent-term-test--wait-for
               (lambda () (string-match-p "hello agent" (agent-term-test--read-log log))))))))

;;; Drafts

(defmacro agent-term-test--with-drafts (log &rest body)
  "Run BODY with the fake agent and an empty draft directory.
LOG is bound to the agent's log file."
  (declare (indent 1))
  `(agent-term-test--with-agent-env ,log
     (let ((agent-term-draft-directory (file-name-as-directory (make-temp-file "drafts" t)))
           (agent-term-draft-save-delay 0.05))
       (unwind-protect
           (progn ,@body)
         (dolist (b (agent-term-draft--buffers))
           (with-current-buffer b (setq agent-term-draft--finished t))
           (kill-buffer b))
         (delete-directory agent-term-draft-directory t)))))

(defun agent-term-test--draft-text (buffer)
  "Return the saved text of the draft BUFFER."
  (agent-term-draft--read
   (agent-term-draft--file (buffer-local-value 'agent-term-draft--id buffer) "txt")))

(defun agent-term-test--start (directory)
  "Start a fake-agent session in DIRECTORY and wait until it runs."
  (let ((session (agent-term--create-session 'claude directory)))
    (should (agent-term-test--wait-for
             (lambda () (string-match-p "READY" (agent-term-test--read-log
                                                 (substring (car (last agent-term-environment))
                                                            (length "FAKE_AGENT_LOG=")))))))
    session))

(ert-deftest agent-term-test-draft-key-in-session ()
  "C-c ' opens a draft from a session buffer."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-drafts _log
    (let ((session (agent-term-test--start temporary-file-directory)))
      (with-current-buffer (agent-term--session-buffer session)
        (should (eq (key-binding (kbd "C-c '")) #'agent-term-draft))))))

(ert-deftest agent-term-test-draft-many ()
  "Any number of drafts can be open, for one or several sessions."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-drafts _log
    (let* ((root (make-temp-file "roots" t))
           (a (file-name-as-directory (expand-file-name "a" root)))
           (b (file-name-as-directory (expand-file-name "b" root))))
      (make-directory a) (make-directory b)
      (unwind-protect
          (let* ((sa (agent-term-test--start a))
                 (sb (agent-term-test--start b))
                 (drafts (list (agent-term-draft--create sa) (agent-term-draft--create sa)
                               (agent-term-draft--create sb))))
            (should (equal (length (delete-dups (copy-sequence drafts))) 3))
            (should (equal (length (agent-term-draft--saved)) 3))
            (should (equal (length (agent-term-draft--saved a)) 2))
            (should (equal (length (agent-term-draft--saved b)) 1))
            (cl-loop for d in drafts for i from 0
                     do (with-current-buffer d (insert (format "text %d" i))))
            (should (agent-term-test--wait-for
                     (lambda () (cl-every (lambda (d) (equal (agent-term-test--draft-text d)
                                                              (with-current-buffer d (buffer-string))))
                                          drafts)))))
        (delete-directory root t)))))

(ert-deftest agent-term-test-draft-saved-while-typing ()
  "Typed text reaches the disk shortly after the change."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-drafts _log
    (let ((draft (agent-term-draft--create (agent-term-test--start temporary-file-directory))))
      (with-current-buffer draft (insert "hello"))
      (should (agent-term-test--wait-for
               (lambda () (equal (agent-term-test--draft-text draft) "hello")))))))

(ert-deftest agent-term-test-draft-survives-kill-and-restart ()
  "Killing the buffer or restarting Emacs keeps the draft."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-drafts _log
    (let* ((session (agent-term-test--start temporary-file-directory))
           (draft (agent-term-draft--create session))
           (id (buffer-local-value 'agent-term-draft--id draft)))
      ;; Killed right after typing, before the delayed save.
      (with-current-buffer draft (insert "first line\nsecond"))
      (kill-buffer draft)
      (let ((saved (agent-term-draft--saved temporary-file-directory)))
        (should (equal (mapcar (lambda (m) (plist-get m :id)) saved) (list id)))
        ;; Reopen through the command, as after a restart.
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt choices &rest _) (cadr choices))))
          (with-current-buffer (agent-term--session-buffer session)
            (agent-term-draft t)))
        (let ((reopened (agent-term-draft--buffer-for-id id)))
          (should reopened)
          (should (equal (with-current-buffer reopened (buffer-string)) "first line\nsecond"))
          ;; kill-emacs-hook saves pending changes.
          (with-current-buffer reopened (insert "!"))
          (should (memq #'agent-term-draft--save-all kill-emacs-hook))
          (agent-term-draft--save-all)
          (should (equal (agent-term-test--draft-text reopened) "first line\nsecond!")))))))

(ert-deftest agent-term-test-draft-survives-major-mode-change ()
  "Changing the major mode of a draft keeps it a saved draft."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-drafts _log
    (let ((draft (agent-term-draft--create (agent-term-test--start temporary-file-directory))))
      (with-current-buffer draft
        (fundamental-mode)
        (insert "still saved")
        (should (eq (key-binding (kbd "C-c C-c")) #'agent-term-draft-send)))
      (should (agent-term-test--wait-for
               (lambda () (equal (agent-term-test--draft-text draft) "still saved"))))
      ;; The kill-buffer save survives the mode change as well.
      (with-current-buffer draft (insert "!"))
      (kill-buffer draft)
      (should (equal (agent-term-draft--read
                      (agent-term-draft--file
                       (plist-get (car (agent-term-draft--saved)) :id) "txt"))
                     "still saved!")))))

(ert-deftest agent-term-test-draft-send ()
  "C-c C-c sends the whole text to the agent and removes the draft."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-drafts log
    (let* ((session (agent-term-test--start temporary-file-directory))
           (draft (agent-term-draft--create session))
           (id (buffer-local-value 'agent-term-draft--id draft)))
      (with-current-buffer draft
        (insert "line one\nline two\n")
        (agent-term-draft-send))
      (should-not (buffer-live-p draft))
      (should-not (file-exists-p (agent-term-draft--file id "txt")))
      (should-not (file-exists-p (agent-term-draft--file id "eld")))
      (should (agent-term-test--wait-for
               (lambda () (let ((text (agent-term-test--read-log log)))
                            (and (string-match-p "line one" text)
                                 (string-match-p "line two" text)))))))))

(ert-deftest agent-term-test-draft-cancel ()
  "C-c C-k removes the draft and sends nothing."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-drafts log
    (let* ((draft (agent-term-draft--create (agent-term-test--start temporary-file-directory))))
      (with-current-buffer draft
        (insert "secret plan")
        (agent-term-draft-cancel))
      (should-not (buffer-live-p draft))
      (should-not (agent-term-draft--saved))
      (accept-process-output nil 0.3)
      (should-not (string-match-p "secret plan" (agent-term-test--read-log log))))))

(ert-deftest agent-term-test-draft-kept-without-session ()
  "Sending without a running session keeps the draft."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-drafts _log
    (let* ((session (agent-term-test--start temporary-file-directory))
           (draft (agent-term-draft--create session)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer (agent-term--session-buffer session)))
      (with-current-buffer draft
        (insert "later")
        (should-error (agent-term-draft-send) :type 'user-error))
      (should (buffer-live-p draft))
      (should (equal (agent-term-test--draft-text draft) "later")))))

(ert-deftest agent-term-test-draft-announced-on-start ()
  "Starting a session mentions its saved drafts."
  (skip-unless (agent-term-test--ghostel-p))
  (agent-term-test--with-drafts _log
    (let* ((dir temporary-file-directory)
           (draft (agent-term-draft--create (agent-term-test--start dir)))
           (messages nil))
      (kill-buffer draft)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer (agent-term--session-buffer (agent-term--session-for-directory dir))))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (agent-term--create-session 'claude dir))
      (should (cl-some (lambda (m) (string-match-p "1 saved draft for this project" m))
                       messages)))))

(provide 'agent-term-test)

;;; agent-term-test.el ends here
