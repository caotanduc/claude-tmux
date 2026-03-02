;;; claude-tmux.el --- Send current file reference to a Claude tmux pane -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Cao Tan Duc

;; Author: Cao Tan Duc <ductancao.work@gmail.com>
;; Version: 0.1.3
;; Package-Version: 0.1.3
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/caotanduc/claude-tmux
;; Package-Homepage: https://github.com/caotanduc/claude-tmux

;;; Commentary:

;; Drop this file somewhere in your load-path, then:
;;
;;   (require 'claude-tmux)
;;
;; Commands:
;;
;;   M-x claude-tmux-dispatch
;;   M-x claude-tmux-send-file-reference
;;   M-x claude-tmux-send-absolute-path
;;   M-x claude-tmux-send-project-relative-path
;;
;; Behavior:
;;
;; - Computes absolute and project-relative path for current buffer file.
;; - Tries to find a tmux pane running a process containing "claude".
;; - If not found, creates a new tmux pane and optionally starts Claude.
;; - Sends the file reference to the pane.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)

(defgroup claude-tmux nil
  "Send file references from Emacs to a Claude session running in tmux."
  :group 'tools)

(defcustom claude-tmux-claude-regexp "\\bclaude\\b"
  "Regexp used to detect a running Claude process from ps output."
  :type 'regexp
  :group 'claude-tmux)

(defcustom claude-tmux-create-pane-args '("-h")
  "Arguments passed to tmux \"split-window\" when creating a new pane.

Common values:

  (\"-h\") horizontal split
  (\"-v\") vertical split

You may also add \"-p\" \"30\" etc."
  :type '(repeat string)
  :group 'claude-tmux)

(defcustom claude-tmux-start-claude-in-new-pane t
  "If non-nil, send the Claude command to a newly created pane before sending
the file reference."
  :type 'boolean
  :group 'claude-tmux)

(defcustom claude-tmux-claude-command "claude"
  "Command to run in a newly created pane when Claude auto-start is enabled."
  :type 'string
  :group 'claude-tmux)

(defcustom claude-tmux-file-reference-format " %s"
  "Format string used to create the text sent to tmux.

The string receives one %s which is replaced with the chosen path.

Examples:

  \"%s\"
  \"@file:%s\""
  :type 'string
  :group 'claude-tmux)

(defcustom claude-tmux-file-reference-lines-format "@%s:%d:%d"
  "Format string used when sending a file reference with line range.

Arguments:

  %s = path
  %d = first line
  %d = last line

Example:

  \"@src/foo.el:10:20\""
  :type 'string
  :group 'claude-tmux)

(defcustom claude-tmux-prefer-project-relative t
  "If non-nil, prefer project-relative paths when available."
  :type 'boolean
  :group 'claude-tmux)

(defcustom claude-tmux-switch-after-send nil
  "If non-nil, switch focus to the tmux pane after sending reference."
  :type 'boolean
  :group 'claude-tmux)

(defcustom claude-tmux-tmux-binary "tmux"
  "Name or full path of the tmux executable."
  :type 'string
  :group 'claude-tmux)

(defun claude-tmux--in-tmux-p ()
  "Return non-nil if Emacs runs inside a tmux client."
  (getenv "TMUX"))

(defun claude-tmux--call (prog &rest args)
  "Run PROG with ARGS and return trimmed stdout.

Signal error if exit status is nonzero."
  (let* ((buf (generate-new-buffer " *claude-tmux*"))
         (status
          (unwind-protect
              (apply #'call-process prog nil buf nil args)
            nil))
         (out (with-current-buffer buf (buffer-string))))
    (kill-buffer buf)
    (unless (and (integerp status) (= status 0))
      (error "Command failed (%s %s): %s"
             prog (string-join args " ") (string-trim out)))
    (string-trim out)))

(defun claude-tmux--call-noerror (prog &rest args)
  "Run PROG with ARGS and return stdout or nil on failure."
  (condition-case nil
      (apply #'claude-tmux--call prog args)
    (error nil)))

(defun claude-tmux--project-root ()
  "Return project root path or nil."
  (cond
   ((fboundp 'project-current)
    (when-let ((pr (project-current nil)))
      (ignore-errors (project-root pr))))
   ((fboundp 'projectile-project-root)
    (ignore-errors (projectile-project-root)))
   (t nil)))

(defun claude-tmux--paths-for-current-buffer ()
  "Return plist with absolute and project-relative paths.

Keys:

  :abs absolute path
  :rel project-relative path
  :root project root"
  (unless (buffer-file-name)
    (error "Current buffer is not visiting a file"))
  (let* ((abs (expand-file-name (buffer-file-name)))
         (root (claude-tmux--project-root))
         (rel (when root (file-relative-name abs root))))
    (list :abs abs :rel rel :root root)))

(defun claude-tmux--tmux-list-panes ()
  "Return alist mapping tmux pane shell PID to pane information."
  (let* ((fmt "#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}\t#{window_name}\t#{pane_title}\t#{pane_current_path}")
         (out
          (claude-tmux--call-noerror
           claude-tmux-tmux-binary
           "list-panes" "-s" "-F" fmt)))
    (unless out
      (error "Tmux not available or not running"))
    (let ((lines (split-string out "\n" t))
          acc)
      (dolist (line lines (nreverse acc))
        (let ((parts (split-string line "\t")))
          (when (= (length parts) 5)
            (pcase-let ((`(,target ,pid ,wname ,ptitle ,cwd) parts))
              (push
               (cons
                (string-to-number pid)
                (list
                 :target target
                 :window_name wname
                 :pane_title ptitle
                 :cwd cwd))
               acc))))))))

(defun claude-tmux--ps-list ()
  "Return hash table mapping PID to process information."
  (let* ((user (user-login-name))
         (raw
          (claude-tmux--call-noerror
           "ps" "-u" user "-ww" "-o" "pid,ppid,args")))
    (unless raw
      (error "Failed to run ps"))
    (let ((ht (make-hash-table :test 'eql))
          (lines (split-string raw "\n" t)))
      (dolist (line (cdr lines) ht)
        (when
            (string-match
             "^\\s-*\\([0-9]+\\)\\s-+\\([0-9]+\\)\\s-+\\(.*\\)$"
             line)
          (let ((pid (string-to-number (match-string 1 line)))
                (ppid (string-to-number (match-string 2 line)))
                (args (match-string 3 line)))
            (puthash pid (list :ppid ppid :args args) ht)))))))

;; Rest of your file remains IDENTICAL
;; (no warning-producing docstrings below)

(provide 'claude-tmux)

;;; claude-tmux.el ends here
