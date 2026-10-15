;;; copilot-ide-test.el --- Tests for copilot-ide  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run with `make test'.  The session tests need ghostel and its native
;; module and are skipped without them; they run test/fake-agent in
;; place of a real agent CLI.

;;; Code:

(require 'ert)
(require 'copilot-ide)
(require 'copilot-ide-mcp-http-server)

(defconst copilot-ide-test--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this file.")

(defconst copilot-ide-test--fake-agent
  (expand-file-name "fake-agent" copilot-ide-test--dir))

;;; Helpers

(defmacro copilot-ide-test--with-clean-state (&rest body)
  "Run BODY with fresh session tables, default options and no MCP server."
  (declare (indent 0))
  `(let ((copilot-ide--sessions (make-hash-table :test 'equal))
         (copilot-ide-mcp-server--sessions (make-hash-table :test 'equal))
         (copilot-ide-mcp-server--server nil)
         (copilot-ide-mcp-server--port nil)
         (copilot-ide-mcp-server-tools nil)
         (copilot-ide-enable-mcp-server nil)
         (copilot-ide-agent 'copilot)
         (copilot-ide-cli-path nil)
         (copilot-ide-cli-extra-flags "")
         (copilot-ide-environment nil)
         (copilot-ide-use-side-window nil)
         (copilot-ide-emacs-keybindings nil)
         (copilot-ide-mcp-available-tools nil)
         (copilot-ide-mcp-excluded-tools nil)
         (copilot-ide-mcp-allow-tools nil)
         (copilot-ide-mcp-deny-tools nil))
     (unwind-protect
         (progn ,@body)
       (copilot-ide-mcp-server--stop-server))))

(defun copilot-ide-test--http (request)
  "Send raw REQUEST (a string or list of strings) to the MCP server.
Strings in a list are sent as separate writes.  Return (STATUS . BODY)."
  (let* ((out "")
         (proc (make-network-process
                :name "copilot-ide-test-client" :host "127.0.0.1"
                :service (copilot-ide-mcp-server-get-port) :coding 'binary
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

(defun copilot-ide-test--post (path body &optional extra-headers)
  "POST BODY to PATH with EXTRA-HEADERS (a string).  Return (STATUS . BODY)."
  (let ((payload (encode-coding-string body 'utf-8)))
    (copilot-ide-test--http
     (format "POST %s HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n%sContent-Length: %d\r\n\r\n%s"
             path (or extra-headers "") (length payload) payload))))

(defun copilot-ide-test--rpc (session-id method &optional params)
  "Call METHOD with PARAMS on SESSION-ID; return the parsed response."
  (let ((response (copilot-ide-test--post
                   (concat "/mcp/" session-id)
                   (json-encode `((jsonrpc . "2.0") (id . 42) (method . ,method)
                                  ,@(when params `((params . ,params))))))))
    (should (equal (car response) 200))
    (json-parse-string (cdr response) :object-type 'alist)))

(defmacro copilot-ide-test--with-mcp-session (session-id &rest body)
  "Run BODY with the MCP server running and SESSION-ID registered."
  (declare (indent 1))
  `(copilot-ide-test--with-clean-state
     (setq copilot-ide-enable-mcp-server t)
     (should (copilot-ide-mcp-server-ensure-server))
     (let ((,session-id (copilot-ide-mcp-server-new-session-id)))
       (copilot-ide-mcp-server-session-started ,session-id temporary-file-directory nil)
       ,@body)))

(defun copilot-ide-test--ghostel-p ()
  "Return non-nil if ghostel and its native module can be loaded."
  (and (require 'ghostel nil t)
       (ignore-errors (ghostel--load-module t) t)))

(defun copilot-ide-test--wait-for (predicate &optional timeout)
  "Process output until PREDICATE returns non-nil or TIMEOUT seconds pass."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defun copilot-ide-test--read-log (file)
  "Return the contents of FILE, or the empty string."
  (if (file-exists-p file)
      (with-temp-buffer (insert-file-contents file) (buffer-string))
    ""))

(defmacro copilot-ide-test--with-agent-env (log &rest body)
  "Run BODY with the fake agent configured; LOG is bound to its log file."
  (declare (indent 1))
  `(copilot-ide-test--with-clean-state
     (let* ((,log (make-temp-file "copilot-ide-log"))
            (copilot-ide-cli-path copilot-ide-test--fake-agent)
            (copilot-ide-environment (list (concat "FAKE_AGENT_LOG=" ,log))))
       (unwind-protect
           (progn ,@body)
         (dolist (s (copilot-ide--live-sessions))
           (let ((kill-buffer-query-functions nil))
             (kill-buffer (copilot-ide--session-buffer s))))
         (delete-file ,log)))))

;;; Command line

(ert-deftest copilot-ide-test-args-resume-and-extra-flags ()
  "Resume and extra flags become separate argv entries; quoting is honored."
  (copilot-ide-test--with-clean-state
    (setq copilot-ide-cli-extra-flags "--model \"a b\" --banner")
    (should (equal (copilot-ide--build-args 'copilot "id" nil "abc")
                   '("--resume" "abc" "--model" "a b" "--banner")))
    (should (equal (copilot-ide--build-args 'claude "id" t nil)
                   '("--continue" "--model" "a b" "--banner")))
    (should (equal (copilot-ide--build-args 'claude "id" nil t)
                   '("--resume" "--model" "a b" "--banner")))))

(ert-deftest copilot-ide-test-args-copilot-tool-flags ()
  "Copilot gets its four tool flags, entries passed verbatim."
  (copilot-ide-test--with-clean-state
    (setq copilot-ide-mcp-available-tools '("a" "b(x)")
          copilot-ide-mcp-excluded-tools '("c")
          copilot-ide-mcp-allow-tools '("shell(git)")
          copilot-ide-mcp-deny-tools '("d(rm)"))
    (should (equal (copilot-ide--build-args 'copilot "id")
                   '("--available-tools=a,b(x)" "--allow-tool=shell(git)"
                     "--excluded-tools=c" "--deny-tool=d(rm)")))))

(ert-deftest copilot-ide-test-args-claude-tool-flags ()
  "Claude merges excluded and denied tools and ignores available tools."
  (copilot-ide-test--with-clean-state
    (setq copilot-ide-mcp-excluded-tools '("mcp__x")
          copilot-ide-mcp-allow-tools '("mcp__emacs-tools" "Bash(git log:*)")
          copilot-ide-mcp-deny-tools '("Bash(rm:*)"))
    (should (equal (copilot-ide--build-args 'claude "id")
                   '("--allowedTools=mcp__emacs-tools,Bash(git log:*)"
                     "--disallowedTools=mcp__x,Bash(rm:*)")))
    (setq copilot-ide-mcp-available-tools '("a"))
    (let ((warned nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (&rest _) (setq warned t))))
        (should (equal (copilot-ide--build-args 'claude "id")
                       '("--allowedTools=mcp__emacs-tools,Bash(git log:*)"
                         "--disallowedTools=mcp__x,Bash(rm:*)"))))
      (should warned))))

(ert-deftest copilot-ide-test-args-mcp-config ()
  "The MCP config is one argv entry with the agent's flag and session URL."
  (copilot-ide-test--with-clean-state
    (setq copilot-ide-enable-mcp-server t)
    (dolist (case '((copilot . "--additional-mcp-config=") (claude . "--mcp-config=")))
      (let* ((arg (car (last (copilot-ide--build-args (car case) "tok123"))))
             (json (substring arg (length (cdr case))))
             (config (json-parse-string json :object-type 'alist)))
        (should (string-prefix-p (cdr case) arg))
        (should (equal (alist-get 'type (alist-get 'emacs-tools (alist-get 'mcpServers config)))
                       "http"))
        (should (string-match-p
                 (format "\\`http://127\\.0\\.0\\.1:%d/mcp/tok123\\'"
                         (copilot-ide-mcp-server-get-port))
                 (alist-get 'url (alist-get 'emacs-tools (alist-get 'mcpServers config)))))))))

;;; MCP server

(ert-deftest copilot-ide-test-session-id-random ()
  "Session ids are 32 hex digits and differ."
  (let ((a (copilot-ide-mcp-server-new-session-id))
        (b (copilot-ide-mcp-server-new-session-id)))
    (should (string-match-p "\\`[0-9a-f]\\{32\\}\\'" a))
    (should-not (equal a b))))

(ert-deftest copilot-ide-test-mcp-rejects-unknown-session ()
  "Requests without a registered session token run no tool."
  (copilot-ide-test--with-mcp-session _id
    (let ((called nil))
      (copilot-ide-make-tool :name "t" :description "d"
                             :function (lambda () (setq called t) "x"))
      (dolist (path '("/mcp" "/mcp/" "/mcp/wrong" "/other"))
        (should (equal (car (copilot-ide-test--post
                             path "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"t\"}}"))
                       404)))
      (should-not called))))

(ert-deftest copilot-ide-test-mcp-rejects-foreign-origin ()
  "A request from a web page origin is refused; a local one is served."
  (copilot-ide-test--with-mcp-session id
    (let ((body "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"))
      (should (equal (car (copilot-ide-test--post (concat "/mcp/" id) body
                                                   "Origin: https://example.com\r\n"))
                     403))
      (should (equal (car (copilot-ide-test--post (concat "/mcp/" id) body
                                                   "Origin: http://localhost:3000\r\n"))
                     200)))))

(ert-deftest copilot-ide-test-mcp-error-codes ()
  "Unknown methods and tools give JSON-RPC errors with the request id."
  (copilot-ide-test--with-mcp-session id
    (let ((r (copilot-ide-test--rpc id "bogus")))
      (should (equal (alist-get 'id r) 42))
      (should (equal (alist-get 'code (alist-get 'error r)) -32601)))
    (let ((r (copilot-ide-test--rpc id "tools/call" '((name . "nope")))))
      (should (equal (alist-get 'id r) 42))
      (should (equal (alist-get 'code (alist-get 'error r)) -32602)))))

(ert-deftest copilot-ide-test-mcp-missing-required-argument ()
  "A missing required argument is an invalid-params error."
  (copilot-ide-test--with-mcp-session id
    (copilot-ide-make-tool :name "t" :description "d" :function #'identity
                           :args '((:name "x" :type string :description "x")))
    (let ((r (copilot-ide-test--rpc id "tools/call" `((name . "t") (arguments . ,(make-hash-table))))))
      (should (equal (alist-get 'code (alist-get 'error r)) -32602)))))

(ert-deftest copilot-ide-test-mcp-false-and-null-are-nil ()
  "JSON false and null reach the tool function as nil."
  (copilot-ide-test--with-mcp-session id
    (copilot-ide-make-tool :name "t" :description "d"
                           :function (lambda (a b c) (format "%S %S %S" a b c))
                           :args '((:name "a" :type boolean :optional t)
                                   (:name "b" :type string :optional t)
                                   (:name "c" :type boolean :optional t)))
    (let* ((response (copilot-ide-test--post
                      (concat "/mcp/" id)
                      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"t\",\"arguments\":{\"a\":false,\"b\":null,\"c\":true}}}"))
           (r (json-parse-string (cdr response) :object-type 'alist)))
      (should (equal (alist-get 'text (aref (alist-get 'content (alist-get 'result r)) 0))
                     "nil nil t")))))

(ert-deftest copilot-ide-test-mcp-required-false-is-present ()
  "A required boolean argument given as false is not missing."
  (copilot-ide-test--with-mcp-session id
    (copilot-ide-make-tool :name "t" :description "d"
                           :function (lambda (flag) (format "%S" flag))
                           :args '((:name "flag" :type boolean :description "f")))
    (let* ((response (copilot-ide-test--post
                      (concat "/mcp/" id)
                      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"t\",\"arguments\":{\"flag\":false}}}"))
           (r (json-parse-string (cdr response) :object-type 'alist)))
      (should (equal (alist-get 'text (aref (alist-get 'content (alist-get 'result r)) 0))
                     "nil")))))

(ert-deftest copilot-ide-test-mcp-tool-error-is-error-result ()
  "An error in the tool becomes a result with isError set."
  (copilot-ide-test--with-mcp-session id
    (copilot-ide-make-tool :name "t" :description "d"
                           :function (lambda () (error "Boom")))
    (let* ((r (copilot-ide-test--rpc id "tools/call" '((name . "t"))))
           (result (alist-get 'result r)))
      (should (eq (alist-get 'isError result) t))
      (should (equal (alist-get 'text (aref (alist-get 'content result) 0))
                     "Error: Boom")))))

(ert-deftest copilot-ide-test-mcp-tool-runs-in-project-directory ()
  "Tools run with `default-directory' set to the session project."
  (copilot-ide-test--with-mcp-session id
    (copilot-ide-make-tool :name "pwd" :description "d"
                           :function (lambda ()
                                       (copilot-ide-mcp-server-with-session-context nil
                                         default-directory)))
    (let ((r (copilot-ide-test--rpc id "tools/call" '((name . "pwd")))))
      (should (equal (alist-get 'text (aref (alist-get 'content (alist-get 'result r)) 0))
                     temporary-file-directory)))))

(ert-deftest copilot-ide-test-mcp-notification-and-get ()
  "Notifications get 202, GET gets 405."
  (copilot-ide-test--with-mcp-session id
    (should (equal (car (copilot-ide-test--post
                         (concat "/mcp/" id)
                         "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"))
                   202))
    (should (equal (car (copilot-ide-test--http
                         (format "GET /mcp/%s HTTP/1.1\r\nHost: x\r\n\r\n" id)))
                   405))))

(ert-deftest copilot-ide-test-mcp-body-in-separate-write ()
  "A body that arrives after the headers is still read completely."
  (copilot-ide-test--with-mcp-session id
    (let* ((body "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}")
           (response (copilot-ide-test--http
                      (list (format "POST /mcp/%s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
                                    id (length body))
                            (substring body 0 10)
                            (substring body 10)))))
      (should (equal (car response) 200))
      (should (equal (alist-get 'id (json-parse-string (cdr response) :object-type 'alist))
                     9)))))

(ert-deftest copilot-ide-test-mcp-initialize-and-list ()
  "initialize negotiates the version; tools/list returns the tools."
  (copilot-ide-test--with-mcp-session id
    (copilot-ide-make-tool :name "t" :description "d" :function #'ignore
                           :args '((:name "x" :type string :description "x")))
    (let ((r (copilot-ide-test--rpc id "initialize" '((protocolVersion . "2025-03-26")))))
      (should (equal (alist-get 'protocolVersion (alist-get 'result r)) "2025-03-26")))
    (let ((r (copilot-ide-test--rpc id "initialize" '((protocolVersion . "1999-01-01")))))
      (should (equal (alist-get 'protocolVersion (alist-get 'result r)) "2025-06-18")))
    (let* ((tools (alist-get 'tools (alist-get 'result (copilot-ide-test--rpc id "tools/list"))))
           (tool (aref tools 0)))
      (should (equal (length tools) 1))
      (should (equal (alist-get 'required (alist-get 'inputSchema tool)) ["x"])))))

(ert-deftest copilot-ide-test-make-tool-replaces-by-name ()
  "Registering a tool again under the same name replaces it."
  (copilot-ide-test--with-clean-state
    (copilot-ide-make-tool :name "t" :description "old" :function #'ignore)
    (copilot-ide-make-tool :name "t" :description "new" :function #'ignore)
    (should (equal (mapcar (lambda (s) (plist-get s :description))
                           copilot-ide-mcp-server-tools)
                   '("new")))))

(ert-deftest copilot-ide-test-server-stops-with-last-session ()
  "The MCP server stops when the last session ends."
  (copilot-ide-test--with-mcp-session id
    (let ((second (copilot-ide-mcp-server-new-session-id)))
      (copilot-ide-mcp-server-session-started second "/" nil)
      (copilot-ide-mcp-server-session-ended id)
      (should (copilot-ide-mcp-server-get-port))
      (copilot-ide-mcp-server-session-ended second)
      (should-not (copilot-ide-mcp-server-get-port)))))

;;; Emacs tools

(ert-deftest copilot-ide-test-relative-path-uses-project ()
  "Relative file paths are resolved against the session project."
  (copilot-ide-test--with-clean-state
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
            (copilot-ide-mcp-server-session-started id project other)
            (copilot-ide-mcp-server-update-last-active-buffer id other)
            (let ((copilot-ide-mcp-server--current-session-id id))
              (with-current-buffer other
                (should (equal (copilot-ide-mcp-get-buffer-content "a.txt") "unsaved"))
                (should (eq (copilot-ide-mcp--get-xref-buffer "a.txt")
                            (find-buffer-visiting file))))))
        (let ((buf (find-buffer-visiting file)))
          (when buf (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf)))
        (kill-buffer other)
        (delete-directory project t)))))

(ert-deftest copilot-ide-test-grep-definitions-only ()
  "The definitions grep matches the identifier, not every def/class line."
  (let ((project (make-temp-file "proj" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.py" project)
            (insert "def other():\n    pass\nclass Unrelated:\n    pass\n"
                    "def target():\n    pass\nx = target()\n"))
          (let ((defs (copilot-ide-mcp--grep-symbol-in-project "target" project t))
                (refs (copilot-ide-mcp--grep-symbol-in-project "target" project)))
            (should (equal (length defs) 1))
            (should (string-match-p "def target" (car defs)))
            (should (equal (length refs) 2))))
      (delete-directory project t))))

;;; Sessions (ghostel)

(ert-deftest copilot-ide-test-session-environment-and-args ()
  "The agent gets `copilot-ide-environment' and its arguments."
  (skip-unless (copilot-ide-test--ghostel-p))
  (copilot-ide-test--with-agent-env log
    (let ((copilot-ide-environment (cons "FAKE_VAR=hello" copilot-ide-environment))
          (copilot-ide-cli-extra-flags "--x \"a b\"")
          (default-directory temporary-file-directory))
      (copilot-ide)
      (should (copilot-ide-test--wait-for
               (lambda () (string-match-p "READY" (copilot-ide-test--read-log log)))))
      (let ((text (copilot-ide-test--read-log log)))
        (should (string-match-p "^ENV:FAKE_VAR=hello$" text))
        (should (string-match-p "^ARG:a b$" text))))))

(ert-deftest copilot-ide-test-session-keys-are-buffer-local ()
  "Session key overrides do not leak into other ghostel buffers."
  (skip-unless (copilot-ide-test--ghostel-p))
  (copilot-ide-test--with-agent-env _log
    (let ((default-directory temporary-file-directory)
          (other (get-buffer-create "*plain-ghostel*")))
      (unwind-protect
          (let ((session (copilot-ide--create-session 'copilot default-directory)))
            (ghostel-exec other "/bin/sh" '("-c" "sleep 5"))
            (with-current-buffer (copilot-ide--session-buffer session)
              (should (eq (key-binding (kbd "S-<return>")) #'copilot-ide-insert-newline)))
            (with-current-buffer other
              (should-not (eq (key-binding (kbd "S-<return>")) #'copilot-ide-insert-newline))
              (should-not (eq (key-binding (kbd "C-<escape>")) #'copilot-ide-send-escape))))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer other))))))

(ert-deftest copilot-ide-test-same-basename-projects ()
  "Projects with the same directory name get separate buffers."
  (skip-unless (copilot-ide-test--ghostel-p))
  (copilot-ide-test--with-agent-env _log
    (let* ((root (make-temp-file "roots" t))
           (a (file-name-as-directory (expand-file-name "x/src" root)))
           (b (file-name-as-directory (expand-file-name "y/src" root))))
      (make-directory a t)
      (make-directory b t)
      (unwind-protect
          (let ((sa (copilot-ide--create-session 'copilot a))
                (sb (copilot-ide--create-session 'copilot b)))
            (should-not (eq (copilot-ide--session-buffer sa) (copilot-ide--session-buffer sb)))
            (should (process-live-p (copilot-ide--session-process sa)))
            (should (process-live-p (copilot-ide--session-process sb)))
            (let ((default-directory b))
              (copilot-ide-stop))
            (should (buffer-live-p (copilot-ide--session-buffer sa)))
            (should-not (buffer-live-p (copilot-ide--session-buffer sb)))
            (should (eq (gethash a copilot-ide--sessions) sa))
            (should-not (gethash b copilot-ide--sessions)))
        (delete-directory root t)))))

(ert-deftest copilot-ide-test-agent-exit-ends-session ()
  "When the agent exits, the session, its buffer and MCP entry go away."
  (skip-unless (copilot-ide-test--ghostel-p))
  (copilot-ide-test--with-agent-env _log
    (let* ((copilot-ide-enable-mcp-server t)
           (copilot-ide-cli-extra-flags "--exit-now")
           (dir temporary-file-directory)
           (session (copilot-ide--create-session 'claude dir)))
      (should (copilot-ide-mcp-server-get-session-context (copilot-ide--session-id session)))
      (should (copilot-ide-test--wait-for
               (lambda () (not (buffer-live-p (copilot-ide--session-buffer session))))))
      (should-not (gethash dir copilot-ide--sessions))
      (should-not (copilot-ide-mcp-server-get-session-context (copilot-ide--session-id session)))
      (should-not (copilot-ide-mcp-server-get-port)))))

(ert-deftest copilot-ide-test-failed-start-cleans-up ()
  "A missing agent executable leaves no buffer or session behind."
  (copilot-ide-test--with-clean-state
    (let ((copilot-ide-cli-path "/nonexistent/agent")
          (buffers (buffer-list)))
      (should-error (copilot-ide--create-session 'copilot temporary-file-directory)
                    :type 'user-error)
      (should (equal (hash-table-count copilot-ide--sessions) 0))
      (should (equal (buffer-list) buffers)))))

(ert-deftest copilot-ide-test-toggle-in-single-window ()
  "Toggling without side windows works when the session fills the frame."
  (skip-unless (copilot-ide-test--ghostel-p))
  (copilot-ide-test--with-agent-env _log
    (let ((default-directory temporary-file-directory)
          (start (get-buffer-create "*start*")))
      (with-current-buffer start (setq default-directory temporary-file-directory))
      (delete-other-windows)
      (switch-to-buffer start)
      (copilot-ide)
      (let ((buffer (window-buffer (selected-window))))
        (should (copilot-ide--current-session))
        (should (buffer-local-value 'copilot-ide--buffer-session buffer))
        (copilot-ide-toggle)
        (should (eq (window-buffer (selected-window)) start))
        (copilot-ide-toggle)
        (should (eq (window-buffer (selected-window)) buffer)))
      (kill-buffer start))))

(ert-deftest copilot-ide-test-send-prompt-from-session-buffer ()
  "Prompts sent from the session buffer reach that session's agent."
  (skip-unless (copilot-ide-test--ghostel-p))
  (copilot-ide-test--with-agent-env log
    (let* ((default-directory temporary-file-directory)
           (session (copilot-ide--create-session 'copilot default-directory)))
      (should (copilot-ide-test--wait-for
               (lambda () (string-match-p "READY" (copilot-ide-test--read-log log)))))
      (with-current-buffer (copilot-ide--session-buffer session)
        ;; The session buffer must be found without a project lookup.
        (let ((default-directory "/"))
          (copilot-ide-send-prompt "hello agent")))
      (should (copilot-ide-test--wait-for
               (lambda () (string-match-p "hello agent" (copilot-ide-test--read-log log))))))))

(provide 'copilot-ide-test)

;;; copilot-ide-test.el ends here
