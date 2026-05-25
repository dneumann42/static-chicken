;; ---------------------------------------------------------------------------
;; TCP REPL

(define *repl-listener* #f)

(define (start-repl-server!)
  (handle-exceptions exn
    (fprintf (current-error-port)
             "[repl] could not bind ~A:~A — ~A~%"
             *repl-host* *repl-port* (condition->string exn))
    (set! *repl-listener* (tcp-listen *repl-port* 4 *repl-host*))
    (fprintf (current-error-port)
             "[repl] listening on ~A:~A~%"
             *repl-host* *repl-port*)))

;; Polled from the frame loop. Single-thread design: poll for new connections
;; and per-client readability with tcp-accept-ready? / char-ready?, so we never
;; block on I/O. The frame loop drives everything.
(define *repl-conns* '())   ; ((in out buffer) ...)
(define *current-repl-in* (make-parameter #f))
(define *current-repl-out* (make-parameter #f))
(define *repl-ui-next-id* 0)
(define *repl-ui-protocol-prefix* ";; STATIC-CHICKEN-UI ")
(define *repl-completion-groups* '())
(define *repl-alias-values* (make-hash-table))
(define *repl-missing-alias-value* (list 'missing-repl-alias-value))

(define (next-repl-ui-id!)
  (set! *repl-ui-next-id* (+ *repl-ui-next-id* 1))
  *repl-ui-next-id*)

(define (write-repl-ui-message! out payload)
  (safe-write-out
   out
   (lambda ()
     (display *repl-ui-protocol-prefix* out)
     (write payload out)
     (newline out)
     (flush-output out))))

(define (send-repl-ui-message! payload)
  (let ((out (*current-repl-out*)))
    (if out
        (write-repl-ui-message! out payload)
        (for-each
         (lambda (client)
           (write-repl-ui-message! client payload))
         *repl-clients*))))

(define (repl-completions! group choices)
  "Register completion CHOICES for GROUP in connected Emacs REPL clients."
  (set! *repl-completion-groups*
        (cons (cons group choices)
              (alist-delete group *repl-completion-groups* eq?)))
  (send-repl-ui-message! (list 'completions group choices))
  choices)

(define (repl-clear-completions! group)
  "Clear completion candidates for GROUP in connected Emacs REPL clients."
  (set! *repl-completion-groups*
        (alist-delete group *repl-completion-groups* eq?))
  (send-repl-ui-message! (list 'clear-completions group))
  group)

(define (repl-functions)
  "Return function names available to the REPL as strings."
  (available-repl-functions))

(define (repl-global-variables)
  "Return global variable names available to the REPL as strings."
  (available-repl-global-variables))

(define (repl-refresh-symbol-completions!)
  "Refresh REPL completion groups for functions and variables."
  (repl-completions! 'repl-functions (repl-functions))
  (repl-completions! 'repl-variables (repl-global-variables))
  #t)

(define (repl-choose-function)
  "Prompt for a REPL function name and return the selected string."
  (repl-choose "Function: " (repl-functions)))

(define (repl-choose-global-variable)
  "Prompt for a REPL global variable name and return the selected string."
  (repl-choose "Variable: " (repl-global-variables)))

(define (repl-choose-symbol)
  "Prompt for either a REPL function or global variable name."
  (let ((kind (repl-choose "Find: " '("Function" "Variable")
                           '((default . "Function")))))
    (if (string=? kind "Variable")
        (repl-choose-global-variable)
        (repl-choose-function))))

(define (send-repl-completion-snapshot! out)
  (repl-refresh-symbol-completions!)
  (for-each
   (lambda (group)
     (write-repl-ui-message!
      out
      (list 'completions (car group) (cdr group))))
   (reverse *repl-completion-groups*)))

(define (wait-repl-ui-response! id)
  (let ((in (*current-repl-in*)))
    (unless in
      (error "REPL UI prompt is only available while evaluating REPL input"))
    (let loop ()
      (let ((message (read in)))
        (cond
          ((eof-object? message)
           (error "REPL UI prompt disconnected"))
          ((and (pair? message)
                (eq? (car message) 'static-chicken-ui-response)
                (pair? (cdr message))
                (equal? (cadr message) id))
           (let ((status (and (pair? (cddr message)) (caddr message)))
                 (value (and (pair? (cdddr message)) (cadddr message))))
             (cond
               ((eq? status 'ok) value)
               ((eq? status 'cancel) (error "REPL UI prompt cancelled"))
               (else (error "invalid REPL UI prompt response" message)))))
          ((and (pair? message)
                (eq? (car message) 'static-chicken-ui-response))
           (loop))
          (else
           (error "unexpected REPL UI prompt response" message)))))))

(define (repl-choose prompt choices . maybe-options)
  "Ask Emacs to select one value from CHOICES and return the selected string."
  (let ((id (next-repl-ui-id!))
        (options (if (null? maybe-options) '() (car maybe-options))))
    (send-repl-ui-message! (list 'choose id prompt choices options))
    (wait-repl-ui-response! id)))

(define (repl-input prompt . maybe-options)
  "Ask Emacs for a free-form text value and return the entered string."
  (let ((id (next-repl-ui-id!))
        (options (if (null? maybe-options) '() (car maybe-options))))
    (send-repl-ui-message! (list 'input id prompt options))
    (wait-repl-ui-response! id)))

(define (poll-repl-accept!)
  (when (and *repl-listener*
             (handle-exceptions _ #f (tcp-accept-ready? *repl-listener*)))
    (handle-exceptions exn
      (fprintf (current-error-port)
               "[repl] accept failed: ~A~%"
               (condition->string exn))
      (receive (in out) (tcp-accept *repl-listener*)
        (if (safe-write-out
             out
             (lambda ()
               (display ";; static-chicken REPL — eval shares the live image.\n" out)
               (display ";; type Ctrl-D or ,quit to disconnect.\n> " out)
               (flush-output out)))
            (begin
              (send-repl-completion-snapshot! out)
              (set! *repl-clients* (cons out *repl-clients*))
              (set! *repl-conns* (cons (list in out "") *repl-conns*)))
            (drop-conn-fully! in out))))))

(define (drop-conn! out)
  (set! *repl-clients*
        (filter (lambda (p) (not (eq? p out))) *repl-clients*)))

(define (drop-conn-fully! in out)
  (drop-conn! out)
  (handle-exceptions _ #f (close-input-port in))
  (handle-exceptions _ #f (close-output-port out)))

(define (safe-write-out out thunk)
  ;; Returns #t on success, #f if writing to the socket fails (e.g. EPIPE).
  (handle-exceptions _ #f (begin (thunk) #t)))

(define (complete-expression-index s)
  (let ((n (string-length s)))
    (let loop ((i 0)
               (depth 0)
               (seen? #f)
               (in-string? #f)
               (escaped? #f)
               (in-comment? #f))
      (cond
        ((>= i n) #f)
        (in-comment?
         (loop (+ i 1)
               depth
               seen?
               in-string?
               #f
               (not (char=? (string-ref s i) #\newline))))
        (in-string?
         (let ((ch (string-ref s i)))
           (loop (+ i 1)
                 depth
                 #t
                 (or escaped?
                     (not (char=? ch #\")))
                 (and (not escaped?) (char=? ch #\\))
                 #f)))
        (else
         (let ((ch (string-ref s i)))
           (cond
             ((char=? ch #\;)
              (loop (+ i 1) depth seen? #f #f #t))
             ((char=? ch #\")
              (loop (+ i 1) depth #t #t #f #f))
             ((char=? ch #\()
              (loop (+ i 1) (+ depth 1) #t #f #f #f))
             ((char=? ch #\))
              (loop (+ i 1) (max 0 (- depth 1)) #t #f #f #f))
             ((and seen? (= depth 0) (char=? ch #\newline))
              i)
             ((char-whitespace? ch)
              (loop (+ i 1) depth seen? #f #f #f))
             (else
              (loop (+ i 1) depth #t #f #f #f)))))))))

(define (read-available-text in)
  (let loop ((chars '()))
    (cond
      ((not (handle-exceptions _ #f (char-ready? in)))
       (list->string (reverse chars)))
      (else
       (let ((ch (handle-exceptions _ #!eof (read-char in))))
         (if (eof-object? ch)
             #!eof
             (loop (cons ch chars))))))))

(define (safe-write-prompt out)
  (safe-write-out
   out
   (lambda ()
     (display "> " out)
     (flush-output out))))

(define (unbound-variable-condition-symbol exn)
  (and (condition? exn)
       (let ((msg (exn-message exn))
	     (args (exn-arguments exn)))
	 (and msg
	      (string=? msg "unbound variable")
	      (pair? args)
	      (symbol? (car args))
	      (car args)))))

(define (repl-alias-value name)
  (hash-table-ref *repl-alias-values* name))

(define (apropos-result-module result)
  (caar result))

(define (apropos-result-name result)
  (cdar result))

(define (find-repl-symbol-result name)
  (let loop ((results (apropos-information-list (symbol->string name)
						sort: #f
						imported?: #f)))
    (cond
     ((null? results) #f)
     ((eq? (apropos-result-name (car results)) name)
      (car results))
     (else
      (loop (cdr results))))))

(define (repl-symbol-value module name)
  (cond
   ((eq? module '||)
    (if (handle-exceptions _ #f (global-symbol-bound? name))
	(global-symbol-ref name)
	*repl-missing-alias-value*))
   ((symbol? module)
    (handle-exceptions _
      *repl-missing-alias-value*
      (eval name (module-environment module))))
   (else
    *repl-missing-alias-value*)))

(define (import-repl-symbol! module name)
  (and (symbol? module)
       (not (eq? module '||))
       (handle-exceptions _
	 #f
	 (eval `(import (only ,module ,name)) (interaction-environment))
	 #t)))

(define (alias-repl-symbol! module name)
  (let ((value (repl-symbol-value module name)))
    (and (not (eq? value *repl-missing-alias-value*))
	 (begin
	   (hash-table-set! *repl-alias-values* name value)
	   (eval `(define ,name (repl-alias-value ',name))
		 (interaction-environment))
	   #t))))

(define (ensure-repl-symbol-alias! name)
  (let ((result (find-repl-symbol-result name)))
    (and result
	 (let ((module (apropos-result-module result)))
	   (or (import-repl-symbol! module name)
	       (alias-repl-symbol! module name))))))

(define (prepare-repl-symbol-aliases! expr)
  (let ((seen '()))
    (let walk ((expr expr))
      (cond
       ((symbol? expr)
	(unless (memq expr seen)
	  (set! seen (cons expr seen))
	  (handle-exceptions _ #f (ensure-repl-symbol-alias! expr))))
       ((pair? expr)
	(cond
	 ((memq (car expr) '(quote quasiquote)) #f)
	 (else
	  (walk (car expr))
	  (walk (cdr expr)))))
       ((vector? expr)
	(let loop ((i 0))
	  (when (< i (vector-length expr))
	    (walk (vector-ref expr i))
	    (loop (+ i 1)))))
       (else #f)))))

(define (eval-repl-expr expr in out retry-unbound?)
  (handle-exceptions exn
    (let ((name (unbound-variable-condition-symbol exn)))
      (if (and retry-unbound?
	       name
	       (ensure-repl-symbol-alias! name))
	  (eval-repl-expr expr in out #f)
	  (abort exn)))
    (parameterize ((*current-repl-in* in)
		   (*current-repl-out* out))
      (prepare-repl-symbol-aliases! expr)
      (eval expr (interaction-environment)))))

(define (eval-repl-line! line in out)
  (handle-exceptions exn
    (safe-write-out
     out
     (lambda ()
       (display "[error] " out)
       (display (condition->string exn) out)
       (display "\n> " out)
       (flush-output out)))
    (let ((expr (with-input-from-string line read)))
      (cond
        ((eof-object? expr)
         (safe-write-prompt out))
        ((equal? expr ',quit)
         'quit)
        (else
         (let ((result (eval-repl-expr expr in out #t)))
           (safe-write-out
            out
            (lambda ()
              (pretty-print result out)
              (display "\n> " out)
              (flush-output out)))))))))

(define (process-repl-buffer! buffer in out)
  (let loop ((buffer buffer))
    (let ((newline (complete-expression-index buffer)))
      (cond
        ((not newline)
         (cons #t buffer))
        (else
         (let* ((line (substring buffer 0 newline))
                (rest (substring buffer (+ newline 1) (string-length buffer)))
                (result (eval-repl-line! line in out)))
           (cond
             ((eq? result 'quit) (cons #f rest))
             (else (loop rest)))))))))

(define (poll-repl-input!)
  (set! *repl-conns*
        (filter-map
         (lambda (c)
           (let ((in (car c))
                 (out (cadr c))
                 (buffer (caddr c)))
             (handle-exceptions _
               (begin (drop-conn-fully! in out) #f)
               (let ((text (read-available-text in)))
                 (cond
                   ((eof-object? text)
                    (drop-conn-fully! in out)
                    #f)
                   ((string=? text "")
                    c)
                   (else
                    (let ((processed
                           (process-repl-buffer!
                            (string-append buffer text)
                            in
                            out)))
                      (if (car processed)
                          (list in out (cdr processed))
                          (begin
                            (drop-conn-fully! in out)
                            #f)))))))))
         *repl-conns*)))
