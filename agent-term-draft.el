;;; agent-term-draft.el --- Draft prompts for agent-term sessions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Tobias Hammer

;; Keywords: ai, convenience
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

;; A draft is an ordinary Emacs buffer for writing a prompt with full
;; editing, which is then sent to the agent of a project with C-c C-c
;; or thrown away with C-c C-k.  `agent-term-draft' (C-c ' in a session
;; buffer) opens a new draft; any number of drafts can be open, for the
;; same or for different projects.
;;
;; Every draft is saved to `agent-term-draft-directory' while you type
;; and stays there until it is sent or cancelled, so neither killing
;; the buffer nor restarting Emacs loses it.  `agent-term-drafts'
;; reopens saved drafts.
;;
;; A draft belongs to a project directory, not to a buffer: it is sent
;; to whatever session runs in that directory when you send it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function agent-term--current-session "agent-term" ())
(declare-function agent-term--session-for-directory "agent-term" (directory))
(declare-function agent-term--session-directory "agent-term" (session))
(declare-function agent-term--session-agent "agent-term" (session))
(declare-function agent-term--agent-name "agent-term" (&optional agent))
(declare-function agent-term--send-text "agent-term" (session text &optional no-submit))

;;; Customization

(defgroup agent-term-draft nil
  "Draft prompts for agent-term sessions."
  :group 'agent-term
  :prefix "agent-term-draft-")

(defcustom agent-term-draft-directory
  (locate-user-emacs-file "agent-term-drafts/")
  "Directory where drafts are kept until they are sent or cancelled."
  :type 'directory)

(defcustom agent-term-draft-major-mode #'text-mode
  "Major mode for new draft buffers, e.g. `markdown-mode'."
  :type 'function)

(defcustom agent-term-draft-window-height 10
  "Height in lines of the window that shows a draft."
  :type 'integer)

(defcustom agent-term-draft-save-delay 0.5
  "Seconds of idle time after which changed drafts are saved."
  :type 'number)

(defcustom agent-term-draft-save-interval 10
  "Seconds between saves of changed drafts while typing without a pause.
This bounds what is lost when Emacs dies before an idle save."
  :type 'number)

;;; State

;; These survive a change of major mode in the draft buffer, so that
;; e.g. M-x markdown-mode does not turn the buffer into an unsaved one.

(defvar-local agent-term-draft--id nil
  "In a draft buffer: the id of the draft.")
(put 'agent-term-draft--id 'permanent-local t)

(defvar-local agent-term-draft--directory nil
  "In a draft buffer: the project directory the draft is sent to.")
(put 'agent-term-draft--directory 'permanent-local t)

(defvar-local agent-term-draft--meta nil
  "In a draft buffer: the plist written to the draft's .eld file.")
(put 'agent-term-draft--meta 'permanent-local t)

(defvar-local agent-term-draft--finished nil
  "In a draft buffer: non-nil once the draft was sent or cancelled.")
(put 'agent-term-draft--finished 'permanent-local t)

(defvar-local agent-term-draft--saved-tick nil
  "In a draft buffer: `buffer-chars-modified-tick' at the last save.")
(put 'agent-term-draft--saved-tick 'permanent-local t)

(defvar agent-term-draft--idle-timer nil
  "Idle timer that saves changed drafts; runs while draft buffers exist.")

(defvar agent-term-draft--interval-timer nil
  "Timer that saves changed drafts during long stretches of typing.")

(defvar agent-term-draft-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-term-draft-send)
    (define-key map (kbd "C-c C-k") #'agent-term-draft-cancel)
    map)
  "Keymap of `agent-term-draft-mode'.")

(define-minor-mode agent-term-draft-mode
  "Minor mode of agent-term draft buffers.
\\{agent-term-draft-mode-map}
`agent-term-draft-send' sends the draft to the agent and submits it;
with a prefix argument, it does not submit.  `agent-term-draft-cancel'
throws the draft away.  Until then the draft is kept in
`agent-term-draft-directory'."
  :lighter " Draft"
  :keymap agent-term-draft-mode-map)
(put 'agent-term-draft-mode 'permanent-local t)

;;; Files

(defun agent-term-draft--file (id extension)
  "Return the file of draft ID with EXTENSION (\"txt\" or \"eld\")."
  (expand-file-name (concat id "." extension) agent-term-draft-directory))

(defun agent-term-draft--new-id ()
  "Return a new draft id; ids sort by creation time."
  (format "%s-%04x" (format-time-string "%Y%m%dT%H%M%S%3N") (random #x10000)))

(defun agent-term-draft--write (file string)
  "Write STRING to FILE as UTF-8, without messages."
  (make-directory (file-name-directory file) t)
  ;; Lock files cost most of the time of a write; only this code writes
  ;; draft files, so they protect nothing.
  (let ((coding-system-for-write 'utf-8-unix)
        (create-lockfiles nil))
    (write-region string nil file nil 'silent)))

(defun agent-term-draft--read (file)
  "Return the contents of FILE, or nil if it does not exist."
  (when (file-readable-p file)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (buffer-string))))

(defun agent-term-draft--saved (&optional directory)
  "Return the saved drafts, oldest first, optionally only for DIRECTORY.
Each is a plist with :id, :directory, :agent and :created."
  (when (file-directory-p agent-term-draft-directory)
    (cl-loop for file in (directory-files agent-term-draft-directory t "\\.eld\\'")
             for meta = (ignore-errors (read (agent-term-draft--read file)))
             when (and (plist-get meta :id)
                       (or (null directory)
                           (equal (plist-get meta :directory) directory)))
             collect meta)))

(defun agent-term-draft--delete-files (id)
  "Delete the files of draft ID, if they exist."
  (dolist (ext '("txt" "eld"))
    (let ((file (agent-term-draft--file id ext)))
      (when (file-exists-p file) (delete-file file)))))

(defun agent-term-draft--save (&optional buffer)
  "Write the text of the draft BUFFER (default: current buffer) to disk.
A draft with only whitespace is not kept: its files are deleted."
  (with-current-buffer (or buffer (current-buffer))
    (when (and agent-term-draft--id (not agent-term-draft--finished))
      (let ((text (save-restriction
                    (widen)
                    (buffer-substring-no-properties (point-min) (point-max)))))
        (if (string-blank-p text)
            (agent-term-draft--delete-files agent-term-draft--id)
          (agent-term-draft--write (agent-term-draft--file agent-term-draft--id "eld")
                                   (let ((print-length nil) (print-level nil))
                                     (prin1-to-string agent-term-draft--meta)))
          (agent-term-draft--write (agent-term-draft--file agent-term-draft--id "txt")
                                   text)))
      (setq agent-term-draft--saved-tick (buffer-chars-modified-tick)))))
(put 'agent-term-draft--save 'permanent-local-hook t)

(defun agent-term-draft--save-modified ()
  "Save the drafts changed since their last save; stop when none is left.
Polling the modification tick is used instead of `after-change-functions':
after a change of major mode, Emacs can skip that hook for the first
change in the buffer."
  (let ((buffers (agent-term-draft--buffers)))
    (dolist (buffer buffers)
      (unless (eql (buffer-chars-modified-tick buffer)
                   (buffer-local-value 'agent-term-draft--saved-tick buffer))
        (agent-term-draft--save buffer)))
    (unless buffers
      (agent-term-draft--stop-timers))))

(defun agent-term-draft--ensure-timer ()
  "Start the save timers if they are not running yet.
The idle timer saves after a pause in typing; the interval timer saves
during typing without pauses, when the idle timer never fires."
  (unless (memq agent-term-draft--idle-timer timer-idle-list)
    (setq agent-term-draft--idle-timer
          (run-with-idle-timer agent-term-draft-save-delay t
                               #'agent-term-draft--save-modified)))
  (unless (memq agent-term-draft--interval-timer timer-list)
    (setq agent-term-draft--interval-timer
          (run-with-timer agent-term-draft-save-interval agent-term-draft-save-interval
                          #'agent-term-draft--save-modified))))

(defun agent-term-draft--stop-timers ()
  "Cancel the save timers."
  (when agent-term-draft--idle-timer
    (cancel-timer agent-term-draft--idle-timer)
    (setq agent-term-draft--idle-timer nil))
  (when agent-term-draft--interval-timer
    (cancel-timer agent-term-draft--interval-timer)
    (setq agent-term-draft--interval-timer nil)))

(defun agent-term-draft--save-all ()
  "Save all draft buffers (run from `kill-emacs-hook')."
  (dolist (buffer (agent-term-draft--buffers))
    (agent-term-draft--save buffer)))

(add-hook 'kill-emacs-hook #'agent-term-draft--save-all)

;;; Buffers

(defun agent-term-draft--buffers ()
  "Return all live draft buffers."
  (cl-remove-if-not (lambda (b) (buffer-local-value 'agent-term-draft--id b))
                    (buffer-list)))

(defun agent-term-draft--buffer-for-id (id)
  "Return the live buffer of draft ID, or nil."
  (cl-find id (agent-term-draft--buffers)
           :key (lambda (b) (buffer-local-value 'agent-term-draft--id b))
           :test #'equal))

(defun agent-term-draft--open (meta)
  "Return the buffer of the draft described by META, creating it if needed."
  (let ((id (plist-get meta :id)))
    (or (agent-term-draft--buffer-for-id id)
        (let* ((directory (plist-get meta :directory))
               (buffer (generate-new-buffer
                        ;; No leading "*": Doom treats such buffers as
                        ;; popups and kills them when they are closed.
                        (format "%s-draft[%s]"
                                (downcase (agent-term--agent-name (plist-get meta :agent)))
                                (file-name-nondirectory (directory-file-name directory))))))
          (with-current-buffer buffer
            (funcall agent-term-draft-major-mode)
            (setq default-directory (file-name-as-directory directory)
                  agent-term-draft--id id
                  agent-term-draft--directory directory
                  agent-term-draft--meta meta)
            (insert (or (agent-term-draft--read (agent-term-draft--file id "txt")) ""))
            (set-buffer-modified-p nil)
            (setq agent-term-draft--saved-tick (buffer-chars-modified-tick))
            (agent-term-draft-mode 1)
            (add-hook 'kill-buffer-hook #'agent-term-draft--save nil t))
          (agent-term-draft--ensure-timer)
          buffer))))

(defun agent-term-draft--create (session)
  "Create a new draft for SESSION and return its buffer.
Nothing is written to disk until the draft has text."
  (agent-term-draft--open
   (list :id (agent-term-draft--new-id)
         :directory (agent-term--session-directory session)
         :agent (agent-term--session-agent session)
         :created (format-time-string "%F %T"))))

(defun agent-term-draft--display (buffer)
  "Show and select the draft BUFFER below the selected window."
  (pop-to-buffer buffer `((display-buffer-reuse-window display-buffer-below-selected)
                          (window-height . ,agent-term-draft-window-height)))
  buffer)

(defun agent-term-draft--finish (buffer)
  "Delete the files of the draft BUFFER and close it."
  (with-current-buffer buffer
    (setq agent-term-draft--finished t)
    (agent-term-draft--delete-files agent-term-draft--id))
  (dolist (window (get-buffer-window-list buffer nil t))
    (quit-restore-window window))
  (kill-buffer buffer))

(defun agent-term-draft--label (meta)
  "Return a completion label for the saved draft META."
  (let ((text (or (agent-term-draft--read (agent-term-draft--file (plist-get meta :id) "txt"))
                  "")))
    (format "%s  %s  %s"
            (plist-get meta :created)
            (abbreviate-file-name (plist-get meta :directory))
            (truncate-string-to-width
             (replace-regexp-in-string "[ \t\n]+" " " (string-trim text)) 60 nil nil "…"))))

(defun agent-term-draft--announce (directory)
  "Tell the user about saved drafts for DIRECTORY that are not open."
  (let ((count (cl-count-if-not
                (lambda (meta) (agent-term-draft--buffer-for-id (plist-get meta :id)))
                (agent-term-draft--saved directory))))
    (when (> count 0)
      (message "%d saved draft%s for this project: C-u M-x agent-term-draft to reopen"
               count (if (= count 1) "" "s")))))

;;; Commands

;;;###autoload (autoload 'agent-term-draft "agent-term" nil t)
(defun agent-term-draft (&optional choose)
  "Open a new draft for the agent session of this buffer or project.
In the draft, `agent-term-draft-send' (\\<agent-term-draft-mode-map>\\[agent-term-draft-send]) sends it,
`agent-term-draft-cancel' (\\[agent-term-draft-cancel]) cancels it.
With prefix argument CHOOSE, pick one of the project's saved drafts
instead (or a new one)."
  (interactive "P")
  (let* ((session (or (agent-term--current-session)
                      (user-error "No agent session for this project")))
         (saved (and choose (agent-term-draft--saved (agent-term--session-directory session))))
         (choices (mapcar (lambda (meta) (cons (agent-term-draft--label meta) meta)) saved))
         (choice (and choices
                      (completing-read "Draft: " (cons "[new draft]" (mapcar #'car choices))
                                       nil t)))
         (meta (cdr (assoc choice choices))))
    (agent-term-draft--display
     (if meta (agent-term-draft--open meta) (agent-term-draft--create session)))
    (goto-char (point-max))))

;;;###autoload (autoload 'agent-term-drafts "agent-term" nil t)
(defun agent-term-drafts ()
  "Reopen one of the saved drafts of any project."
  (interactive)
  (let* ((choices (mapcar (lambda (meta) (cons (agent-term-draft--label meta) meta))
                          (reverse (agent-term-draft--saved)))))
    (unless choices
      (user-error "No saved drafts"))
    (agent-term-draft--display
     (agent-term-draft--open
      (cdr (assoc (completing-read "Draft: " choices nil t) choices))))))

(defun agent-term-draft-send (&optional no-submit)
  "Send the draft to the agent session of its project and close it.
With prefix argument NO-SUBMIT, only insert the text into the agent's
prompt.  Without a running session, the draft is kept."
  (interactive "P")
  (unless agent-term-draft--id
    (user-error "Not in an agent-term draft"))
  (let ((text (string-trim (buffer-substring-no-properties (point-min) (point-max))))
        (session (agent-term--session-for-directory agent-term-draft--directory)))
    (cond
     ((string-empty-p text)
      (user-error "The draft is empty; C-c C-k cancels it"))
     ((null session)
      (agent-term-draft--save)
      (user-error "No agent session runs in %s; the draft is kept"
                  (abbreviate-file-name agent-term-draft--directory)))
     (t
      (let ((draft (current-buffer)))
        (agent-term--send-text session text no-submit)
        (agent-term-draft--finish draft))))))

(defun agent-term-draft-cancel ()
  "Throw the draft away and close it."
  (interactive)
  (unless agent-term-draft--id
    (user-error "Not in an agent-term draft"))
  (agent-term-draft--finish (current-buffer))
  (message "Draft discarded"))

(provide 'agent-term-draft)

;;; agent-term-draft.el ends here
