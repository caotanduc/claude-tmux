;;; claude-tmux.el --- Send current file reference to a Claude tmux pane -*- lexical-binding: t; -*-

;; Author: Cao Tan Duc <ductancao.work@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/caotanduc/claude-tmux

;;; Commentary:

;; Drop this file somewhere in your load-path, then:
;;   (require 'claude-tmux)
;;
;; Commands:
;;   M-x claude-tmux-dispatch                  (transient menu, recommended)
;;   M-x claude-tmux-send-file-reference
;;   M-x claude-tmux-send-absolute-path
;;   M-x claude-tmux-send-project-relative-path
;;
;; Behavior:
;; - Computes absolute + project-relative path for the current buffer file.
;; - Tries to find a tmux pane running a process whose args contain "claude".
;; - If not found: creates a new tmux pane, optionally starts claude, then
;;   sends the file reference.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup claude-tmux nil
  "Send file references from Emacs to a Claude session running in tmux."
  :group 'tools)

(defcustom claude-tmux-claude-regexp "\\bclaude\\b"
  "Regexp used to detect a running Claude process from `ps' output."
  :type 'regexp
  :group 'claude-tmux)

(defcustom claude-tmux-create-pane-args '("-h")
  "Arguments passed to tmux `split-window' when creating a new pane.
Common values:
  '(\"-h\") horizontal split
  '(\"-v\") vertical split
You may also add \"-p\" \"30\" etc."
  :type '(repeat string)
  :group 'claude-tmux)

(defcustom claude-tmux-start-claude-in-new-pane t
  "If non-nil, send `claude' + Enter to the newly created pane before sending the reference."
  :type 'boolean
  :group 'claude-tmux)

(defcustom claude-tmux-claude-command "claude"
  "Command to run in a newly created pane when `claude-tmux-start-claude-in-new-pane' is non-nil."
  :type 'string
  :group 'claude-tmux)

(defcustom claude-tmux-file-reference-format " %s"
  "Format string used to create the text sent to tmux.
It receives one %s which will be replaced with the chosen path.
Example: \"@file:%s\" or \"%s\"."
  :type 'string
  :group 'claude-tmux)

(defcustom claude-tmux-file-reference-lines-format "@%s:%d:%d"
  "Format string used when sending a file reference with a line range.
It receives %s (path), %d (first line), %d (last line).
Example: \"@%s:%d:%d\" produces \"@src/foo.el:10:20\"."
  :type 'string
  :group 'claude-tmux)

(defcustom claude-tmux-prefer-project-relative t
  "If non-nil, send project-relative path when available, else absolute path."
  :type 'boolean
  :group 'claude-tmux)

(defcustom claude-tmux-switch-after-send nil
  "If non-nil, switch focus to the Claude tmux pane after sending the reference."
  :type 'boolean
  :group 'claude-tmux)

(defcustom claude-tmux-tmux-binary "tmux"
  "Name or path of the tmux executable."
  :type 'string
  :group 'claude-tmux)

(defun claude-tmux--in-tmux-p ()
  "Return non-nil if Emacs is running inside a tmux client."
  (getenv "TMUX"))

(defun claude-tmux--call (prog &rest args)
  "Run PROG ARGS and return stdout as string (trimmed).  Signal error on nonzero exit."
  (let* ((buf (generate-new-buffer " *claude-tmux*"))
         (status (unwind-protect
                     (apply #'call-process prog nil buf nil args)
                   nil))
         (out (with-current-buffer buf (buffer-string))))
    (kill-buffer buf)
    (unless (and (integerp status) (= status 0))
      (error "Command failed (%s %s): %s" prog (string-join args " ") (string-trim out)))
    (string-trim out)))

(defun claude-tmux--call-noerror (prog &rest args)
  "Run PROG ARGS and return stdout (trimmed), or nil on failure."
  (condition-case _e
      (apply #'claude-tmux--call prog args)
    (error nil)))

(defun claude-tmux--project-root ()
  "Return project root (string) or nil."
  (cond
   ((fboundp 'project-current)
    (when-let ((pr (project-current nil)))
      (ignore-errors (project-root pr))))
   ((fboundp 'projectile-project-root)
    (ignore-errors (projectile-project-root)))
   (t nil)))

(defun claude-tmux--paths-for-current-buffer ()
  "Return plist (:abs ABS :rel REL :root ROOT) for current buffer file."
  (unless (buffer-file-name)
    (error "Current buffer is not visiting a file"))
  (let* ((abs (expand-file-name (buffer-file-name)))
         (root (claude-tmux--project-root))
         (rel (when root (file-relative-name abs root))))
    (list :abs abs :rel rel :root root)))

(defun claude-tmux--tmux-list-panes ()
  "Return an alist mapping pane shell PID (integer) -> plist with pane info."
  ;; Format:
  ;; target \t pid \t window_name \t pane_title \t pane_current_path
  (let* ((fmt "#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}\t#{window_name}\t#{pane_title}\t#{pane_current_path}")
         (out (claude-tmux--call-noerror claude-tmux-tmux-binary "list-panes" "-s" "-F" fmt)))
    (unless out (error "Tmux not available or not running"))
    (let ((lines (split-string out "\n" t))
          (acc nil))
      (dolist (line lines (nreverse acc))
        (let ((parts (split-string line "\t")))
          (when (= (length parts) 5)
            (pcase-let ((`(,target ,pid ,wname ,ptitle ,cwd) parts))
              (push (cons (string-to-number pid)
                          (list :target target
                                :window_name wname
                                :pane_title ptitle
                                :cwd cwd))
                    acc))))))))

(defun claude-tmux--ps-list ()
  "Return a hash table mapping PID (integer) to process info plist."
  (let* ((user (user-login-name))
         (fields "pid,ppid,args")
         (raw (apply #'claude-tmux--call-noerror
                     (list "ps" "-u" user "-ww" "-o" fields))))
    (unless raw (error "Failed to run ps"))
    (let ((ht (make-hash-table :test 'eql))
          (lines (split-string raw "\n" t)))
      ;; Skip header
      (dolist (line (cdr lines) ht)
        (when (string-match "^\\s-*\\([0-9]+\\)\\s-+\\([0-9]+\\)\\s-+\\(.*\\)$" line)
          (let ((pid (string-to-number (match-string 1 line)))
                (ppid (string-to-number (match-string 2 line)))
                (args (match-string 3 line)))
            (puthash pid (list :ppid ppid :args args) ht)))))))

(defun claude-tmux--claude-panes ()
  "Return a list of plists for panes that contain a running Claude process."
  (let* ((pane-map (claude-tmux--tmux-list-panes)) ; alist pid->pane plist
         (panepid->pane (let ((ht (make-hash-table :test 'eql)))
                          (dolist (kv pane-map ht)
                            (puthash (car kv) (cdr kv) ht))))
         (procs (claude-tmux--ps-list))
         (found nil))
    (maphash
     (lambda (pid info)
       (let ((args (plist-get info :args)))
         (when (and args (string-match-p claude-tmux-claude-regexp args))
           ;; Walk up parent chain to find a tmux pane shell pid
           (let ((cur pid)
                 (seen 0)
                 (max-depth 200)) ;; safety
             (while (and cur (< seen max-depth))
               (setq seen (1+ seen))
               (let ((pane (gethash cur panepid->pane)))
                 (when pane
                   (push (append pane (list :pid pid :args args)) found)
                   (setq cur nil))) ;; break
               (when cur
                 (setq cur (plist-get (gethash cur procs) :ppid))))))))
     procs)
    (nreverse found)))

(defun claude-tmux--choose-pane (panes)
  "Prompt user to choose from PANES (list of plists).  Return chosen pane plist."
  (cond
   ((null panes) nil)
   ((= (length panes) 1) (car panes))
   (t
    (let* ((candidates
            (mapcar
             (lambda (p)
               (let ((label (format "%s  window=%s  title=%s  cwd=%s  pid=%s  cmd=%s"
                                    (plist-get p :target)
                                    (plist-get p :window_name)
                                    (plist-get p :pane_title)
                                    (plist-get p :cwd)
                                    (plist-get p :pid)
                                    (plist-get p :args))))
                 (cons label p)))
             panes))
           (choice (completing-read "Choose Claude tmux pane: " candidates nil t)))
      (cdr (assoc choice candidates))))))

(defun claude-tmux--create-pane ()
  "Create a new tmux pane and return its target (like 'session:win.pane')."
  ;; We request target string using -P -F so we can send keys to it.
  ;; If Emacs isn't inside tmux, `tmux split-window` still works if it can find a server.
  (let* ((args (append (list "split-window" "-P" "-F" "#{session_name}:#{window_index}.#{pane_index}")
                       claude-tmux-create-pane-args))
         (target (apply #'claude-tmux--call claude-tmux-tmux-binary args)))
    (unless (and target (not (string-empty-p target)))
      (error "Failed to create tmux pane"))
    target))

(defun claude-tmux--send-keys (target text &optional press-enter)
  "Send TEXT to tmux pane TARGET.  If PRESS-ENTER is non-nil, also press Enter."
  (let ((args (append (list "send-keys" "-t" target text)
                      (when press-enter (list "Enter")))))
    (apply #'claude-tmux--call claude-tmux-tmux-binary args)))

(defun claude-tmux--switch-to-pane (target)
  "Switch tmux focus to pane TARGET (e.g. 'session:window.pane')."
  (claude-tmux--call-noerror claude-tmux-tmux-binary "switch-client" "-t" target))

(defun claude-tmux--build-reference (path)
  "Return the outgoing text for PATH."
  (format claude-tmux-file-reference-format path))

(defun claude-tmux--region-lines ()
  "Return (FIRST-LINE . LAST-LINE) for the active region, or nil if no region."
  (when (use-region-p)
    (let* ((beg (region-beginning))
           (end (region-end))
           (first (line-number-at-pos beg))
           ;; If end is at column 0, it belongs to the previous line visually.
           (last (save-excursion
                   (goto-char end)
                   (if (bolp) (max first (1- (line-number-at-pos end)))
                     (line-number-at-pos end)))))
      (cons first last))))

(defun claude-tmux--select-path (&optional force-absolute force-relative)
  "Pick which path to use for current buffer.
If FORCE-ABSOLUTE is non-nil, always return the absolute path.
If FORCE-RELATIVE is non-nil, prefer the project-relative path."
  (let* ((pp (claude-tmux--paths-for-current-buffer))
         (abs (plist-get pp :abs))
         (rel (plist-get pp :rel)))
    (cond
     (force-absolute abs)
     (force-relative (or rel abs))
     (claude-tmux-prefer-project-relative (or rel abs))
     (t abs))))

;;;###autoload
(defun claude-tmux-send-file-reference (&optional force-absolute)
  "Send a file reference for the current buffer to a Claude tmux pane.

If FORCE-ABSOLUTE is non-nil (prefix arg \\[universal-argument]), send the
absolute path even when a project-relative path is available.

If no Claude pane is found, create a new tmux pane, optionally start
`claude', then send the file reference."
  (interactive "P")
  (let* ((path (claude-tmux--select-path force-absolute nil))
         (text (claude-tmux--build-reference path))
         (panes (claude-tmux--claude-panes))
         (pane (claude-tmux--choose-pane panes))
         (target (or (and pane (plist-get pane :target))
                     (claude-tmux--create-pane))))
    (when (and (not pane) claude-tmux-start-claude-in-new-pane)
      (claude-tmux--send-keys target claude-tmux-claude-command t)
      ;; (optional) small pause could be added, but avoid async/estimates; keep simple.
      )
    (claude-tmux--send-keys target text t)
    (when claude-tmux-switch-after-send
      (claude-tmux--switch-to-pane target))
    (message "Sent to tmux %s: %s" target text)))

;;;###autoload
(defun claude-tmux-send-absolute-path ()
  "Send absolute path of current file to a Claude tmux pane (creating one if needed)."
  (interactive)
  (let ((claude-tmux-prefer-project-relative nil))
    (claude-tmux-send-file-reference t)))

;;;###autoload
(defun claude-tmux-send-project-relative-path ()
  "Send project-relative path of current file to a Claude tmux pane (fallback to absolute)."
  (interactive)
  (let ((claude-tmux-prefer-project-relative t))
    (claude-tmux-send-file-reference nil)))

;;;###autoload
(defun claude-tmux-send-file-reference-with-lines (&optional force-absolute)
  "Send a file reference with line range for the current buffer to a Claude tmux pane.

When the region is active, sends `claude-tmux-file-reference-lines-format'
formatted with the path and the first/last line of the region.
When no region is active, falls back to `claude-tmux-send-file-reference'.

If FORCE-ABSOLUTE is non-nil (prefix arg \\[universal-argument]), send the
absolute path even when a project-relative path is available."
  (interactive "P")
  (let ((lines (claude-tmux--region-lines)))
    (if (null lines)
        (claude-tmux-send-file-reference force-absolute)
      (let* ((path (claude-tmux--select-path force-absolute nil))
             (text (format claude-tmux-file-reference-lines-format
                           path (car lines) (cdr lines)))
             (panes (claude-tmux--claude-panes))
             (pane (claude-tmux--choose-pane panes))
             (target (or (and pane (plist-get pane :target))
                         (claude-tmux--create-pane))))
        (when (and (not pane) claude-tmux-start-claude-in-new-pane)
          (claude-tmux--send-keys target claude-tmux-claude-command t))
        (claude-tmux--send-keys target text t)
        (when claude-tmux-switch-after-send
          (claude-tmux--switch-to-pane target))
        (message "Sent to tmux %s: %s" target text)))))

;;; Transient dispatch (transient is bundled with Emacs 28.1+)

(when (require 'transient nil t)

  (transient-define-suffix claude-tmux--toggle-prefer-relative ()
    "Toggle `claude-tmux-prefer-project-relative'."
    :description (lambda ()
                   (concat "Prefer project-relative  "
                           (if claude-tmux-prefer-project-relative
                               (propertize "on"  'face 'transient-value)
                             (propertize "off" 'face 'shadow))))
    :transient t
    (interactive)
    (setq claude-tmux-prefer-project-relative
          (not claude-tmux-prefer-project-relative)))

  (transient-define-suffix claude-tmux--toggle-switch-after-send ()
    "Toggle `claude-tmux-switch-after-send'."
    :description (lambda ()
                   (concat "Switch to pane after send  "
                           (if claude-tmux-switch-after-send
                               (propertize "on"  'face 'transient-value)
                             (propertize "off" 'face 'shadow))))
    :transient t
    (interactive)
    (setq claude-tmux-switch-after-send
          (not claude-tmux-switch-after-send)))

  (transient-define-suffix claude-tmux--toggle-start-claude ()
    "Toggle `claude-tmux-start-claude-in-new-pane'."
    :description (lambda ()
                   (concat "Start claude in new pane  "
                           (if claude-tmux-start-claude-in-new-pane
                               (propertize "on"  'face 'transient-value)
                             (propertize "off" 'face 'shadow))))
    :transient t
    (interactive)
    (setq claude-tmux-start-claude-in-new-pane
          (not claude-tmux-start-claude-in-new-pane)))

  ;;;###autoload
  (transient-define-prefix claude-tmux-dispatch ()
    "Transient menu for claude-tmux."
    ["Options"
     ("r" claude-tmux--toggle-prefer-relative)
     ("s" claude-tmux--toggle-switch-after-send)
     ("c" claude-tmux--toggle-start-claude)]
    ["Send"
     ("f" "Send file reference (smart)"   claude-tmux-send-file-reference)
     ("l" "Send with line range (region)" claude-tmux-send-file-reference-with-lines)
     ("a" "Send absolute path"            claude-tmux-send-absolute-path)
     ("p" "Send project-relative path"    claude-tmux-send-project-relative-path)]))

(provide 'claude-tmux)
;;; claude-tmux.el ends here
