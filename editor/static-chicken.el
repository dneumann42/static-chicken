;;; static-chicken.el --- Compatibility shim for the moved Emacs helper -*- lexical-binding: t; -*-

;; Keep the historical load path working for existing configs that still add
;; vendor/static-chicken/editor to `load-path`.

(load (expand-file-name "../tools/emacs/static-chicken.el"
                        (file-name-directory (or load-file-name buffer-file-name))))

;;; static-chicken.el ends here
