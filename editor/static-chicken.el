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
;;   (add-to-list 'load-path "/path/to/vendor/static-chicken/editor")
;;   (require 'static-chicken)
;;   (add-hook 'scheme-mode-hook #'static-chicken-mode)
;;
;; Then <f5> in any .scm buffer saves and reloads (and launches if needed).

;;; Code:

(require 'comint)
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
     ((fboundp 'geiser-connect)
      (geiser-connect static-chicken-geiser-impl
                      static-chicken-repl-host
                      static-chicken-repl-port))
     (t
      (let* ((host static-chicken-repl-host)
             (port static-chicken-repl-port)
             (buf-name (string-trim static-chicken--repl-buffer-name "\\*" "\\*"))
             (existing (get-buffer static-chicken--repl-buffer-name)))
        (if (and existing (get-buffer-process existing))
            (pop-to-buffer existing)
          (when existing (kill-buffer existing))
          (let ((buf (make-comint buf-name (cons host port))))
            (with-current-buffer buf
              (setq-local comint-prompt-regexp "^> ")
              (setq-local comint-use-prompt-regexp t))
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
  :keymap static-chicken-mode-map)

(provide 'static-chicken)

;;; static-chicken.el ends here
