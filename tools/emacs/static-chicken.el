;;; static-chicken.el --- Hot-reload helpers for static-chicken apps  -*- lexical-binding: t; -*-

;; A static-chicken app exposes a TCP REPL on 127.0.0.1:1234. This package
;; provides `static-chicken-reload', which saves every modified .scm buffer
;; and sends `(check-watches!)' to the running app so the changed files are
;; reloaded into the live image. If no app is running, it launches the app
;; via the project's run.sh, waits for the REPL port to come up, attaches
;; geiser to it via `geiser-connect', and then performs the reload.
;;
;; Usage:
;;
;;   (add-to-list 'load-path "/path/to/vendor/static-chicken/tools/emacs")
;;   (require 'static-chicken)
;;   (add-hook 'scheme-mode-hook #'static-chicken-mode)
;;
;; Then <f5> in any .scm buffer saves and reloads (and launches if needed).

;;; Code:

(require 'comint)
(require 'cl-lib)
(require 'geiser-mode nil 'noerror)

(defgroup static-chicken nil
  "Hot-reload integration for static-chicken Scheme apps."
  :group 'tools
  :prefix "static-chicken-")

(defcustom static-chicken-repl-host "127.0.0.1"
  "Host where the running static-chicken app's TCP REPL is listening."
  :type 'string
  :group 'static-chicken)

(defcustom static-chicken-repl-port 1234
  "Port where the running static-chicken app's TCP REPL is listening.
Override this if you launch the app with REPL_PORT set."
  :type 'integer
  :group 'static-chicken)

(defcustom static-chicken-reload-timeout 0.5
  "Seconds to wait for the app to acknowledge a reload before disconnecting."
  :type 'number
  :group 'static-chicken)

(defcustom static-chicken-run-script "run.sh"
  "Filename of the launcher script at the project root."
  :type 'string
  :group 'static-chicken)

(defcustom static-chicken-run-args '("--watch")
  "Arguments passed to `static-chicken-run-script' when auto-launching."
  :type '(repeat string)
  :group 'static-chicken)

(defcustom static-chicken-launch-timeout 60
  "Maximum seconds to wait for the REPL port to come up after launching."
  :type 'number
  :group 'static-chicken)

(defcustom static-chicken-geiser-impl 'guile
  "Geiser implementation symbol passed to `geiser-connect'.
The static-chicken TCP server is a plain sexp-in/value-out REPL; any
Geiser backend that produces a usable REPL buffer against it is fine.
Defaults to `guile' since `geiser-guile' is the common install."
  :type 'symbol
  :group 'static-chicken)

(defcustom static-chicken-use-geiser nil
  "When non-nil, use `geiser-connect' instead of the faster plain comint REPL."
  :type 'boolean
  :group 'static-chicken)

(defcustom static-chicken-repl-split 'horizontal
  "How `static-chicken-connect-repl' splits the frame for the REPL.
`horizontal' produces a side-by-side split (good for wide monitors),
`vertical' a top/bottom split, `nil' uses Emacs' usual rules."
  :type '(choice (const :tag "Side-by-side" horizontal)
                 (const :tag "Top/bottom" vertical)
                 (const :tag "Default rules" nil))
  :group 'static-chicken)

(defcustom static-chicken-reload-key "<f5>"
  "Key sequence bound to `static-chicken-reload' in `static-chicken-mode'.
Defaults to `<f5>'.  C-c C-c is unsuitable as a default because
`geiser-mode' and other Scheme major modes claim it; pick something
the active major-mode keymap doesn't already bind."
  :type 'key-sequence
  :group 'static-chicken)

(defcustom static-chicken-repl-find-symbol-key "C-c C-f"
  "Key sequence bound in the plain REPL to find a function or variable."
  :type 'key-sequence
  :group 'static-chicken)

(defun static-chicken--save-scheme-buffers ()
  "Save every modified buffer that visits a .scm file."
  (save-some-buffers t
                     (lambda ()
                       (and buffer-file-name
                            (string-suffix-p ".scm" buffer-file-name)))))

(defun static-chicken--port-open-p (host port)
  "Return non-nil if HOST:PORT accepts a TCP connection right now."
  (let ((proc (ignore-errors
                (make-network-process :name "static-chicken-probe"
                                      :host host
                                      :service port
                                      :nowait nil))))
    (when proc
      (delete-process proc)
      t)))

(defun static-chicken--project-root ()
  "Walk up from the current buffer looking for the project's run.sh.
Returns an absolute directory path, or nil if none is found."
  (let* ((start (or buffer-file-name default-directory))
         (dir (locate-dominating-file start static-chicken-run-script)))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defvar static-chicken--app-buffer-name "*static-chicken-app*")
(defvar static-chicken--repl-buffer-name "*static-chicken-repl*")
(defconst static-chicken--protocol-prefix ";; STATIC-CHICKEN-UI ")
(defvar-local static-chicken--protocol-fragment "")
(defvar-local static-chicken--completion-groups nil)
(defvar-local static-chicken--comint-repl-setup nil)

(defun static-chicken--repl-history-file ()
  "Return the file used for persisted plain comint REPL history."
  (if-let ((root (static-chicken--project-root)))
      (expand-file-name ".static-chicken-repl-history" root)
    (expand-file-name "static-chicken-repl-history" user-emacs-directory)))

(defun static-chicken--write-repl-history (&rest _)
  "Persist the current buffer's comint input ring, ignoring write failures."
  (when (derived-mode-p 'comint-mode)
    (ignore-errors
      (comint-write-input-ring))))

(defun static-chicken--completion-candidates ()
  "Return all Scheme-registered REPL completion candidates for this buffer."
  (delete-dups
   (copy-sequence
    (apply #'append (mapcar #'cdr static-chicken--completion-groups)))))

(defun static-chicken--completion-group-candidates (group)
  "Return Scheme-registered completion candidates for GROUP."
  (delete-dups
   (copy-sequence
    (or (cdr (assq group static-chicken--completion-groups)) '()))))

(defun static-chicken--string-start-for-completion (limit)
  "Return string-content start when point is inside a string after LIMIT."
  (let ((pos limit)
        (start nil)
        (escaped nil))
    (while (< pos (point))
      (let ((ch (char-after pos)))
        (cond
         (escaped
          (setq escaped nil))
         ((eq ch ?\\)
          (setq escaped t))
         ((eq ch ?\")
          (setq start (if start nil (1+ pos))))))
      (setq pos (1+ pos)))
    start))

(defun static-chicken--completion-at-point ()
  "Complete REPL input from candidates registered by Scheme."
  (let ((candidates (static-chicken--completion-candidates)))
    (when candidates
      (let* ((limit (save-excursion
                      (comint-bol)
                      (point)))
             (string-start (static-chicken--string-start-for-completion limit))
             (end (point))
             (start (or string-start
                        (save-excursion
                          (skip-chars-backward "[:alnum:]_?!*/+<>=.-" limit)
                          (point)))))
        (list start end candidates)))))

(defun static-chicken--send-protocol-response (id status &optional value)
  "Send a hidden protocol response for prompt ID."
  (when-let ((proc (get-buffer-process (current-buffer))))
    (process-send-string
     proc
     (concat (prin1-to-string
              (list 'static-chicken-ui-response id status value))
             "\n"))))

(defun static-chicken--protocol-option (key options)
  "Read KEY from protocol OPTIONS alist."
  (cdr (assq key options)))

(defun static-chicken--handle-choice-request (id prompt choices options)
  "Handle a Scheme choice request using minibuffer completion."
  (condition-case err
      (let* ((default (static-chicken--protocol-option 'default options))
             (selection (completing-read prompt choices nil t nil nil default)))
        (static-chicken--send-protocol-response id 'ok selection))
    (quit
     (static-chicken--send-protocol-response id 'cancel nil))
    (error
     (message "static-chicken prompt failed: %s" (error-message-string err))
     (static-chicken--send-protocol-response id 'cancel nil))))

(defun static-chicken--handle-input-request (id prompt options)
  "Handle a Scheme text input request using the minibuffer."
  (condition-case err
      (let* ((default (static-chicken--protocol-option 'default options))
             (input (read-from-minibuffer prompt nil nil nil nil default)))
        (static-chicken--send-protocol-response
         id 'ok (if (string-empty-p input) default input)))
    (quit
     (static-chicken--send-protocol-response id 'cancel nil))
    (error
     (message "static-chicken input failed: %s" (error-message-string err))
     (static-chicken--send-protocol-response id 'cancel nil))))

(defun static-chicken--set-completion-group (group choices)
  "Set completion CHOICES for GROUP in the current REPL buffer."
  (setq static-chicken--completion-groups
        (cons (cons group choices)
              (assq-delete-all group static-chicken--completion-groups))))

(defun static-chicken--clear-completion-group (group)
  "Clear completion candidates for GROUP in the current REPL buffer."
  (setq static-chicken--completion-groups
        (assq-delete-all group static-chicken--completion-groups)))

(defun static-chicken--handle-protocol-message (message)
  "Handle one hidden static-chicken protocol MESSAGE."
  (pcase message
    (`(choose ,id ,prompt ,choices ,options)
     (static-chicken--handle-choice-request id prompt choices options))
    (`(input ,id ,prompt ,options)
     (static-chicken--handle-input-request id prompt options))
    (`(completions ,group ,choices)
     (static-chicken--set-completion-group group choices))
    (`(clear-completions ,group)
     (static-chicken--clear-completion-group group))
    (_
     (message "static-chicken: unknown REPL protocol message: %S" message))))

(defun static-chicken--protocol-fragment-p (text)
  "Return non-nil if TEXT could be the start of a protocol line."
  (and (not (string-empty-p text))
       (string-prefix-p text static-chicken--protocol-prefix)))

(defun static-chicken--handle-protocol-line (line)
  "Handle a hidden protocol LINE, reporting malformed messages."
  (condition-case err
      (static-chicken--handle-protocol-message
       (car (read-from-string
             (substring line (length static-chicken--protocol-prefix)))))
    (error
     (message "static-chicken: malformed REPL protocol line: %s"
              (error-message-string err)))))

(defun static-chicken--preoutput-filter (text)
  "Strip and handle hidden static-chicken protocol lines from TEXT."
  (let ((pending (concat static-chicken--protocol-fragment text))
        (visible ""))
    (setq static-chicken--protocol-fragment "")
    (while (string-match "\n" pending)
      (let ((line (substring pending 0 (match-beginning 0))))
        (setq pending (substring pending (match-end 0)))
        (if (string-prefix-p static-chicken--protocol-prefix line)
            (static-chicken--handle-protocol-line line)
          (setq visible (concat visible line "\n")))))
    (cond
     ((static-chicken--protocol-fragment-p pending)
      (setq static-chicken--protocol-fragment pending))
     ((string-prefix-p static-chicken--protocol-prefix pending)
      (setq static-chicken--protocol-fragment pending))
     (t
      (setq visible (concat visible pending))))
    visible))

(defun static-chicken--setup-comint-repl ()
  "Configure static-chicken-specific behavior in a plain comint REPL buffer."
  (when (derived-mode-p 'comint-mode)
    (setq-local comint-prompt-regexp "^> ")
    (setq-local comint-use-prompt-regexp t)
    (setq-local comint-input-ring-file-name
                (static-chicken--repl-history-file))
    (unless static-chicken--comint-repl-setup
      (comint-read-input-ring t))
    (add-hook 'comint-input-filter-functions
              #'static-chicken--write-repl-history nil t)
    (add-hook 'comint-preoutput-filter-functions
              #'static-chicken--preoutput-filter nil t)
    (add-hook 'completion-at-point-functions
              #'static-chicken--completion-at-point nil t)
    (add-hook 'kill-buffer-hook
              #'static-chicken--write-repl-history nil t)
    (local-set-key (kbd "C-a") #'comint-bol)
    (local-set-key (kbd "<home>") #'comint-bol)
    (local-set-key (kbd "C-r") #'comint-history-isearch-backward-regexp)
    (local-set-key (kbd "TAB") #'completion-at-point)
    (local-set-key (kbd static-chicken-repl-find-symbol-key)
                   #'static-chicken-repl-find-symbol)
    (setq-local static-chicken--comint-repl-setup t)))

(defun static-chicken-repl-find-symbol ()
  "Prompt for a REPL function or variable and insert the selected name."
  (interactive)
  (let* ((kind (completing-read "Find: " '("Function" "Variable") nil t
                                nil nil "Function"))
         (group (if (string= kind "Variable") 'repl-variables 'repl-functions))
         (candidates (static-chicken--completion-group-candidates group)))
    (unless candidates
      (user-error "static-chicken: no %s candidates yet; reconnect or reload"
                  (downcase kind)))
    (let ((selection (completing-read (concat kind ": ") candidates nil t)))
      (when (use-region-p)
        (delete-region (region-beginning) (region-end)))
      (insert selection))))

(defun static-chicken--repl-buffer-p (buffer)
  "Return non-nil when BUFFER looks like a static-chicken plain comint REPL."
  (with-current-buffer buffer
    (and (derived-mode-p 'comint-mode)
         (string= (buffer-name buffer) static-chicken--repl-buffer-name))))

(defun static-chicken--setup-existing-repl-buffers ()
  "Apply current static-chicken comint setup to already-open REPL buffers."
  (dolist (buffer (buffer-list))
    (when (static-chicken--repl-buffer-p buffer)
      (with-current-buffer buffer
        (static-chicken--setup-comint-repl)))))

(defun static-chicken--app-running-p ()
  "Return non-nil if a static-chicken app process is alive in our buffer."
  (let ((buf (get-buffer static-chicken--app-buffer-name)))
    (and buf
         (let ((proc (get-buffer-process buf)))
           (and proc (process-live-p proc))))))

(defun static-chicken--launch-app (root)
  "Start ROOT/run.sh in the background, capturing output to a buffer."
  (let* ((default-directory root)
         (script (expand-file-name static-chicken-run-script root))
         (buf (get-buffer-create static-chicken--app-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\n--- launching %s %s @ %s ---\n"
                        script
                        (mapconcat #'identity static-chicken-run-args " ")
                        (format-time-string "%H:%M:%S")))))
    (apply #'start-process
           "static-chicken-app"
           buf
           script
           static-chicken-run-args)
    (message "static-chicken: launched %s (see %s)"
             script static-chicken--app-buffer-name)
    buf))

(defun static-chicken--wait-for-port (host port timeout)
  "Block until HOST:PORT is open or TIMEOUT seconds elapse.
Returns t if the port came up, nil on timeout."
  (let ((deadline (+ (float-time) timeout))
        (open nil))
    (while (and (not open) (< (float-time) deadline))
      (setq open (static-chicken--port-open-p host port))
      (unless open
        (sit-for 0.2)))
    open))

(defmacro static-chicken--with-split (&rest body)
  "Run BODY with split thresholds bent to honor `static-chicken-repl-split'."
  (declare (indent 0))
  `(let ((split-width-threshold
          (pcase static-chicken-repl-split
            ('horizontal 0)
            ('vertical most-positive-fixnum)
            (_ split-width-threshold)))
         (split-height-threshold
          (pcase static-chicken-repl-split
            ('horizontal most-positive-fixnum)
            ('vertical 0)
            (_ split-height-threshold))))
     ,@body))

(defun static-chicken-connect-repl ()
  "Open a REPL buffer connected to the static-chicken TCP server.
Uses `geiser-connect' with `static-chicken-geiser-impl' when geiser is
available; falls back to a plain comint buffer otherwise.  Window
placement honors `static-chicken-repl-split'."
  (interactive)
  (static-chicken--with-split
    (cond
     ((and static-chicken-use-geiser
           (fboundp 'geiser-connect))
      (geiser-connect static-chicken-geiser-impl
                      static-chicken-repl-host
                      static-chicken-repl-port))
     (t
      (let* ((host static-chicken-repl-host)
             (port static-chicken-repl-port)
             (buf-name (string-trim static-chicken--repl-buffer-name "\\*" "\\*"))
             (existing (get-buffer static-chicken--repl-buffer-name)))
        (if (and existing (get-buffer-process existing))
            (progn
              (with-current-buffer existing
                (static-chicken--setup-comint-repl))
              (pop-to-buffer existing))
          (when existing (kill-buffer existing))
          (let ((buf (make-comint buf-name (cons host port))))
            (with-current-buffer buf
              (static-chicken--setup-comint-repl))
            (pop-to-buffer buf))))))))

(defun static-chicken-reload ()
  "Save modified .scm buffers; reload via the running app, or launch one.

If `static-chicken-repl-host':`static-chicken-repl-port' is reachable,
sends `(check-watches!)' to trigger a transitive reload.  Otherwise
locates the project's `run.sh', starts it, waits for the REPL port,
opens a comint REPL buffer, and then performs the reload."
  (interactive)
  (static-chicken--save-scheme-buffers)
  (unless (static-chicken--port-open-p static-chicken-repl-host
                                       static-chicken-repl-port)
    (let ((root (static-chicken--project-root)))
      (unless root
        (user-error
         "static-chicken: no %s found above %s — can't auto-launch"
         static-chicken-run-script
         (or buffer-file-name default-directory)))
      (unless (static-chicken--app-running-p)
        (static-chicken--launch-app root))
      (message "static-chicken: waiting for %s:%d…"
               static-chicken-repl-host static-chicken-repl-port)
      (unless (static-chicken--wait-for-port
               static-chicken-repl-host
               static-chicken-repl-port
               static-chicken-launch-timeout)
        (user-error
         "static-chicken: %s:%d did not open within %ds; see %s"
         static-chicken-repl-host static-chicken-repl-port
         static-chicken-launch-timeout
         static-chicken--app-buffer-name))
      (static-chicken-connect-repl)))
  (let ((buf (generate-new-buffer " *static-chicken-reload*"))
        proc)
    (unwind-protect
        (condition-case err
            (progn
              (setq proc (open-network-stream "static-chicken-reload" buf
                                              static-chicken-repl-host
                                              static-chicken-repl-port))
              (process-send-string proc "(check-watches!)\n")
              (accept-process-output proc static-chicken-reload-timeout)
              (let ((reply (with-current-buffer buf
                             (string-trim (buffer-string)))))
                (if (string-empty-p reply)
                    (message "static-chicken: reload sent")
                  (message "static-chicken: %s" reply))))
          (error
           (message "static-chicken: reload failed: %s"
                    (error-message-string err))))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(defvar static-chicken-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd static-chicken-reload-key) #'static-chicken-reload)
    m)
  "Keymap for `static-chicken-mode'.")

;;;###autoload
(define-minor-mode static-chicken-mode
  "Minor mode for editing static-chicken Scheme files.

\\{static-chicken-mode-map}"
  :lighter " sc"
  :keymap static-chicken-mode-map
  (when static-chicken-mode
    (static-chicken--setup-existing-repl-buffers)))

(provide 'static-chicken)

;;; static-chicken.el ends here
