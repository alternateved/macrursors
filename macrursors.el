;;; macrursors.el --- Macro visualizer -*- lexical-binding: t; -*-

;;; Commentary:
;; Visualization as to where the macros will take place and reduce the
;; brain-work needed to create the macro.

;; 1. Select all like something (selection, word, sexp, line, etc)
;; 2. Place fake cursor at every point to indicate where the macros will be
;;    executed
;; 3. Automatically starts defining the macro.
;; 4. When done execute the macro at every point.

;; Heavily inspired by meow's beacon-mode. There are quite a few code snippets
;; from meow's beacon-mode. Thanks to meow's developers for doing a lot of the
;; heavy lifting, both conceptually and physically.

;; The faces were inspired by multiple-cursors.

;; TODO:
;; - Document different workflows
;; - Explain more in depth how secondary selection works
;; - Provide macrursors-mark-map by default
;; - Propose better binding scheme: https://github.com/corytertel/macrursors/issues/7

;;; Code:

(require 'cl-lib)
(require 'mouse)
(require 'thingatpt)

(defvar-local macrursors--overlays nil)
(defvar-local macrursors--insert-enter-key nil)
(defvar-local macrursors--hideshow-overlays nil)

(defgroup macrursors nil
  "Macrursors, a multi-edit tool for GNU Emacs."
  :group 'editing)

(defface macrursors-cursor-face
  '((t (:inverse-video t)))
  "The face used for fake cursors."
  :group 'macrursors)

(defface macrursors-cursor-bar-face
  `((t (:height 1 :background ,(face-attribute 'cursor :background))))
  "The face used for fake cursors if the `cursor-type' is bar."
  :group 'macrursors)

(defcustom macrursors-match-cursor-style t
  "If non-nil, attempt to match the cursor style that the user has selected.
Namely, use vertical bars if the user has configured Emacs to use that cursor.
If nil, just use standard rectangle cursors for all fake cursors.
In some modes/themes, the bar fake cursors are either not
rendered or shift text."
  :type '(boolean)
  :group 'macrursors)

(defface macrursors-region-face
  '((t :inherit region))
  "The face used for fake regions."
  :group 'macrursors)

(defcustom macrursors-pre-finish-hook nil
  "Hook run before macros are applied.
Useful for optizationing the speed of the macro application.
A simple solution is to disable all minor modes that are purely
aesthetic in `macrursors-pre-finish-hook'
and re-enable them in `macrursors-post-finish-hook'."
  :type 'hook
  :group 'macrursors)

(defcustom macrursors-post-finish-hook nil
  "Hook run after macros are applied.
Useful for optizationing the speed of the macro application.
A simple solution is to disable all minor modes that are purely
aesthetic in `macrursors-pre-finish-hook'
and re-enable them in `macrursors-post-finish-hook'."
  :type 'hook
  :group 'macrursors)

;; FIXME: this doesn't work properly
(defcustom macrursors-apply-keys "C-;"
  "The bind to end and apply the macro recorded."
  :type 'key-sequence
  :group 'macrursors)

(defvar-local macrursors--instance nil
  "The thing last used to create macrursors.")

(define-minor-mode macrursors-mode
  "Minor mode for when macrursors in active."
  :lighter macrursors-mode-line
  :keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd macrursors-apply-keys) #'macrursors-end)
    (define-key map (kbd "C-g") #'macrursors-early-quit)
    map))

;; FIXME: document how to use it
(defcustom macrursors-mode-line
  '(" MAC:" (:eval (if macrursors--overlays
                       (format (propertize "%d/%d" 'face 'font-lock-warning-face)
                               (1+ (cl-count-if (lambda (p) (< p (point))) macrursors--overlays
                                                :key #'overlay-start))
                               (1+ (length macrursors--overlays)))
                     (propertize "1/1" 'face 'font-lock-warning-face))))
  "Mode-line format for Macrursors."
  :type 'string
  :risky t
  :group 'macrursors)

(defun macrursors--inside-secondary-selection ()
  (and-let*
      ((buf (overlay-buffer mouse-secondary-overlay))
       ((eq buf (current-buffer))))
    (<= (overlay-start mouse-secondary-overlay)
        (point)
        (overlay-end mouse-secondary-overlay))))


;;;; Macrursor overlay manipulation functions

(defun macrursors--add-overlay-at-point (pos)
  "Create an overlay to draw a fake cursor at POS."
  (let* ((cursor-type (if (eq cursor-type t)
	                        (frame-parameter nil 'cursor-type)
	                      cursor-type))
         ov)
    (if (and macrursors-match-cursor-style
             (or (eq cursor-type 'bar)
		             (and (listp cursor-type)
		                  (eq (car cursor-type) 'bar))))
        (overlay-put (setq ov (make-overlay pos pos))
                     'before-string
                     (propertize "​"  ; ZERO WIDTH SPACE
                                 'face 'macrursors-cursor-bar-face))
      (overlay-put (setq ov (make-overlay pos (1+ pos)))
                   'face 'macrursors-cursor-face))
    (overlay-put ov 'macrursors-type 'cursor)
    (push ov macrursors--overlays)))

(defun macrursors--remove-overlays (arg)
  "Remove ARG overlays from current buffer and start kmacro recording."
  (dotimes (_ (- arg))
    (and macrursors--overlays
         (delete-overlay (car macrursors--overlays)))
    (cl-callf cdr macrursors--overlays))
  (when (> (length macrursors--overlays) 0)
    (macrursors-start)))

(defun macrursors--remove-all-overlays ()
  "Remove all overlays from current buffer."
  (mapc #'delete-overlay macrursors--overlays)
  (setq macrursors--overlays nil)
  (when macrursors--hideshow-overlays
    (mapc #'delete-overlay macrursors--hideshow-overlays)
    (setq macrursors--hideshow-overlays nil)))

(defun macrursors--get-overlay-positions (&optional overlays)
  "Return a list with the position of all the cursors in `macrursors--overlays'.
If OVERLAYS in non-nil, return a list with the positions of OVERLAYS."
  (mapcar
   #'overlay-start
   (or overlays macrursors--overlays)))


;;;; Generic functions and commands for creating macrursors.
(defun macrursors--instance-with-bounds (&optional regexp)
  "Return an appropriate string or object-type (symbol) for
creating macrursors.

The returned format is a list of the string/symbol and its
beginning and ending positions."
  (cond
   ;; Provided regexp -- Use as instance
   (regexp
    (list regexp (point) (point)))
   ;; Region active -- Mark string from region
   ((use-region-p)
    (when (< (point) (mark))
      (exchange-point-and-mark))
    (list (regexp-quote
           (buffer-substring-no-properties
            (region-beginning) (region-end)))
          (region-beginning)
          (region-end)))
   ;; Cursors active -- reuse instance
   (macrursors-mode
    (let ((region macrursors--instance))
      (list region
            (cond
             ((stringp region) (- (point) (length region)))
             ((symbolp region) (car (bounds-of-thing-at-point region)))
             (t end))
            (point))))
   ;; Mark symbol at point
   ((when-let* ((symb     (thing-at-point 'symbol))
                (bounds   (bounds-of-thing-at-point 'symbol))
                (symb-beg (car bounds))
                (symb-end (cdr bounds)))
      (goto-char symb-end)
      (list (concat "\\_<" (regexp-quote (substring-no-properties symb)) "\\_>")
            symb-beg symb-end)))))

(defun macrursors--toggle-hideshow-overlay (begin end)
  (pcase-let ((`(,_ . ,ov) (get-char-property-and-overlay
                            (1+ begin) 'macrursors-hideshow)))
    (if ov
        (move-overlay ov begin end)
      (setq ov (make-overlay begin end))
      (overlay-put ov 'macrursors-hideshow t)
      (push ov macrursors--hideshow-overlays))
    (overlay-put ov 'display
                 (if (overlay-get ov 'display) nil
                   (propertize "⋮\n" 'face 'shadow)))))

(defun macrursors-hideshow (&optional context)
  (interactive "p")
  (unless executing-kbd-macro
    (save-excursion
      (cl-loop
       with context = (or (abs context) 1)
       with end = (point-max)
       for pos in (cl-sort (cons (point) (macrursors--get-overlay-positions))
                           #'>)
       for begin = (progn (goto-char pos)
                          (forward-line (1+ context))
                          (point))
       if (> end begin) do
       (macrursors--toggle-hideshow-overlay begin end)
       do
       (goto-char pos)
       (forward-line (- context))
       (setq end (point))
       finally do
       (beginning-of-line)
       (if (> (point) (point-min))
           (macrursors--toggle-hideshow-overlay (point-min) (point)))))))

(defun macrursors--mark-all-instances-of (string orig-point &optional end)
  (let ((case-fold-search))
    (while (re-search-forward string end t)
      (unless (= (point) orig-point)
        (macrursors--add-overlay-at-point (point))))))

;;;###autoload
(defun macrursors-mark-all-instances-of (&optional regexp)
  (interactive)
  (pcase-let* ((selection-p (macrursors--inside-secondary-selection))
               (start (if selection-p
	                        (overlay-start mouse-secondary-overlay)
                        0))
               (end (and selection-p
                         (overlay-end mouse-secondary-overlay)))
               (`(,region ,_ ,orig-point) (macrursors--instance-with-bounds regexp)))
    (goto-char orig-point)
    (save-excursion
      (goto-char start)
      (cond
       ((stringp region)
        (macrursors--mark-all-instances-of region orig-point end))
       ((symbolp region)
        (funcall (intern (concat "macrursors-mark-all-"
                                 (symbol-name region) "s"))))))
    (when (use-region-p) (deactivate-mark))
    (setq macrursors--instance region)
    (macrursors-start)))

(defun macrursors--mark-next-instance-of (string &optional end)
  (let ((case-fold-search)
        (cursor-positions (macrursors--get-overlay-positions))
        (matched-p))
    (while (and (setq matched-p
                      (re-search-forward string end t 1))
                (member (point) cursor-positions)))
    (if (or (not matched-p)
            (> (point) (or end (point-max)))
            (member (point) cursor-positions))
        (message "No more matches.")
      (macrursors--add-overlay-at-point (point)))))

;;;###autoload
(defun macrursors-mark-next-instance-of (&optional arg)
  (interactive "p")
  (when defining-kbd-macro (end-kbd-macro))
  (pcase-let ((search-end (and (macrursors--inside-secondary-selection)
                               (overlay-end mouse-secondary-overlay)))
              (`(,region ,_ ,end) (macrursors--instance-with-bounds)))
    (save-excursion
      (cond
       ((< arg 0)  ; Remove cursors
        (macrursors--remove-overlays arg))
       ((stringp region) ; Mark next instance of some string
        (goto-char end)
        (dotimes (_ arg)
          (macrursors--mark-next-instance-of region search-end))
        (setq macrursors--instance region)
        (macrursors-start))
       ;; No region or symbol-name, mark line
       (t (macrursors-mark-next-line arg search-end))))))

(defun macrursors--mark-previous-instance-of (string &optional start)
  (let ((case-fold-search)
        (cursor-positions (macrursors--get-overlay-positions))
        (matched))
    (while (and (setq matched
                      (re-search-forward string start t -1))
                (member (match-end 0) cursor-positions)))
    (if (or (not matched)
            (<= (point) (or start (point-min)))
            (member (match-end 0) cursor-positions))
        (message "No more matches.")
      (macrursors--add-overlay-at-point (match-end 0)))))

;;;###autoload
(defun macrursors-mark-previous-instance-of (&optional arg)
  (interactive "p")
  (when defining-kbd-macro (end-kbd-macro))
  (pcase-let ((search-start (if (macrursors--inside-secondary-selection)
		                            (overlay-start mouse-secondary-overlay)
		                          0))
              (`(,region ,beg ,end) (macrursors--instance-with-bounds)))
    (save-excursion
      (cond
       ((< arg 0) ; Remove cursors
        (macrursors--remove-overlays arg))
       ((stringp region) ; Mark next instance of some string
        (goto-char beg)
        (dotimes (_ arg)
          (macrursors--mark-previous-instance-of region search-start))
        (setq macrursors--instance region)
        (macrursors-start))
       ;; No region or symbol-name, mark line
       (t (macrursors-mark-previous-line arg search-start))))))

(defun macrursors--forward-number ()
  (interactive)
  (let ((closest-ahead (save-excursion (search-forward-regexp "[0-9]*\\.?[0-9]+" nil t))))
    (when closest-ahead
      (push-mark)
      (goto-char closest-ahead))))


;;;; Commands to create macrursors from Isearch
(defun macrursors--isearch-regexp ()
  (or isearch-success (user-error "Nothing to match"))
  (prog1
      (cond
       ((functionp isearch-regexp-function)
        (funcall isearch-regexp-function isearch-string))
       (isearch-regexp-function (word-search-regexp isearch-string))
       (isearch-regexp isearch-string)
       (t (regexp-quote isearch-string)))))

;;;###autoload
(defun macrursors-mark-from-isearch ()
  (interactive)
  (let* ((regexp (macrursors--isearch-regexp))
         (selection-p (macrursors--inside-secondary-selection))
         (search-start (if selection-p
		                       (overlay-start mouse-secondary-overlay)
                         0))
         (search-end (and selection-p
                          (overlay-end mouse-secondary-overlay)))
         orig-point)
    (goto-char (max (point) isearch-other-end))
    (isearch-exit)
    (setq orig-point (point))
    (save-excursion
      (goto-char search-start)
      (macrursors--mark-all-instances-of regexp orig-point search-end))
    (setq macrursors--instance regexp)
    (macrursors-start)))

;;;###autoload
(defun macrursors-mark-next-from-isearch (&optional arg)
  (interactive "p")
  (when defining-kbd-macro (end-kbd-macro))
  (let* ((regexp (macrursors--isearch-regexp))
         (search-end (and (macrursors--inside-secondary-selection)
                          (overlay-end mouse-secondary-overlay))))
    (goto-char (max (point) isearch-other-end))
    (isearch-exit)
    (save-excursion
      (dotimes (_ arg)
        (macrursors--mark-next-instance-of regexp search-end)))
    (setq macrursors--instance regexp)
    (macrursors-start)))

;;;###autoload
(defun macrursors-mark-previous-from-isearch (&optional arg)
  (interactive "p")
  (when defining-kbd-macro (end-kbd-macro))
  (let* ((regexp (macrursors--isearch-regexp))
         (search-start (and (macrursors--inside-secondary-selection)
                            (overlay-start mouse-secondary-overlay)))
         orig-point)
    (setq orig-point (min (point) isearch-other-end))
    (goto-char (max (point) isearch-other-end))
    (isearch-exit)
    (save-excursion
      (goto-char orig-point)
      (dotimes (_ arg)
        (macrursors--mark-previous-instance-of regexp search-start)))
    (setq macrursors--instance regexp)
    (macrursors-start)))


;;;; Commands to create macrursors at syntactic units ("things")
(defun macrursors--mark-all (thing func)
  (lambda ()
    (when mark-active (deactivate-mark))
    (let ((end-of-thing (cdr (bounds-of-thing-at-point thing))))
      (if end-of-thing
          (goto-char end-of-thing)
        (funcall func)))
    (let ((orig-point (point))
          (start (if (macrursors--inside-secondary-selection)
                     (overlay-start mouse-secondary-overlay)
                   0))
          (end (if (macrursors--inside-secondary-selection)
                   (overlay-end mouse-secondary-overlay)
                 (point-max))))
      (save-excursion
        (goto-char start)
        (while (and (let ((curr (point)))
                      (funcall func)
                      (not (= (point) curr)))
                    (<= (point) end))
          (unless (= (point) orig-point)
            (macrursors--add-overlay-at-point (point)))))
      (setq macrursors--instance thing)
      (macrursors-start))))

;;;###autoload
(defun macrursors-mark-all-words ()
  (interactive)
  (funcall (macrursors--mark-all 'word #'forward-word)))

;;;###autoload
(defun macrursors-mark-all-symbols ()
  (interactive)
  (funcall
   (macrursors--mark-all
    'symbol
		(lambda ()
			(call-interactively #'forward-symbol)))))

;;;###autoload
(defun macrursors-mark-all-lists ()
  (interactive)
  (funcall (macrursors--mark-all 'list #'forward-list)))

;;;###autoload
(defun macrursors-mark-all-sexps ()
  (interactive)
  (funcall (macrursors--mark-all 'sexp #'forward-sexp)))

;;;###autoload
(defun macrursors-mark-all-defuns ()
  (interactive)
  (funcall (macrursors--mark-all 'defun #'end-of-defun)))

;;;###autoload
(defun macrursors-mark-all-numbers ()
  (interactive)
  (funcall (macrursors--mark-all 'number #'macrursors--forward-number)))

;;;###autoload
(defun macrursors-mark-all-sentences ()
  (interactive)
  (funcall (macrursors--mark-all 'sentence #'forward-sentence)))

;; FIXME there is no forward-url function
;; (defun macrursors-mark-all-urls ()
;;   (interactive)
;;   (funcall (macrursors--mark-all 'url #'forward-url)))

;; FIXME there is no forward-email function
;; (defun macrursors-mark-all-mails ()
;;   (interactive)
;;   (funcall(macrursors--mark-all 'mail #'forward-mail)))

;;;###autoload
(defun macrursors-mark-next-line (arg &optional search-end)
  (interactive (list (prefix-numeric-value current-prefix-arg)
                     (and (macrursors--inside-secondary-selection)
                          (overlay-end mouse-secondary-overlay))))
  (when defining-kbd-macro (end-kbd-macro))
  (let ((col (current-column))
        bounded)
    (save-excursion
      (if (< arg 0)
          (macrursors--remove-overlays arg)
        (dotimes (_ arg)
          (while (and (setq bounded
                            (and (line-move-1 1 'no-error)
                                 (move-to-column col)
                                 (<= (point) (or search-end (point-max)))))
                      (member (point) (macrursors--get-overlay-positions))))
          (if bounded
              (macrursors--add-overlay-at-point (point))
            (message "No more lines below."))))
      (when bounded
        (setq macrursors--instance 'line)
        (macrursors-start)))))

;;;###autoload
(defun macrursors-mark-previous-line (arg &optional search-beg)
  (interactive (list (prefix-numeric-value current-prefix-arg)
                     (and (macrursors--inside-secondary-selection)
                          (overlay-start mouse-secondary-overlay))))
  (when defining-kbd-macro (end-kbd-macro))
  (let ((col (current-column))
        bounded)
    (save-excursion
      (if (< arg 0)
          (macrursors--remove-overlays arg)
        (dotimes (_ arg)
          (while (and (setq bounded
                            (and (line-move-1 -1 'no-error)
                                 (move-to-column col)
                                 (>= (point) (or search-beg (point-min)))))
                      (member (point) (macrursors--get-overlay-positions))))
          (if bounded
              (macrursors--add-overlay-at-point (point))
            (message "No more lines above."))))
      (when bounded
        (setq macrursors--instance 'line)
        (macrursors-start)))))

;;;###autoload
(defun macrursors-mark-all-lines ()
  (interactive)
  (when mark-active (deactivate-mark))
  (let ((start (if (macrursors--inside-secondary-selection)
		               (overlay-start mouse-secondary-overlay)
		             (point-min)))
	      (end (if (macrursors--inside-secondary-selection)
		             (overlay-end mouse-secondary-overlay)
	             (point-max)))
	      (col (current-column)))
    (save-excursion
      (while (and (let ((curr (point)))
                    (forward-line -1)
		                (move-to-column col)
		                (not (= (point) curr)))
                  (>= (point) start))
	      (macrursors--add-overlay-at-point (point))))
    (save-excursion
      (while (and (let ((curr (point)))
		                (forward-line 1)
		                (move-to-column col)
		                (not (= (point) curr)))
		              (< (point) end))
	      (macrursors--add-overlay-at-point (point))))
    (setq macrursors--instance 'line)
    (macrursors-start)))

;;;###autoload
(defun macrursors-mark-all-lines-or-instances ()
  "If a selection exists, mark all instances of the selection.
Else, mark all lines."
  (interactive)
  (if (and transient-mark-mode mark-active (not (eq (mark) (point))))
      (macrursors-mark-all-instances-of)
    (macrursors-mark-all-lines)))

;;;###autoload
(defun macrursors-add-cursor-on-click (event)
  "Add or remove a cursor on click EVENT."
  (interactive "e")
  (mouse-minibuffer-check event)
  (when defining-kbd-macro (end-kbd-macro))
  (let ((position (event-end event)))
    (if (not (windowp (posn-window position)))
        (error "Position not in text area of window"))
    (select-window (posn-window position))
    (let ((pt (posn-point position))
          (cursor-positions (macrursors--get-overlay-positions)))
      (if (numberp pt)
          (let ((existing (member pt cursor-positions)))
            ;; Check if there exists cursor at point
            (if existing
                (progn
                  (remove-overlays pt (1+ pt))
                  (setq macrursors--overlays
                        (seq-remove (lambda (ov)
                                      (null (overlay-buffer ov)))
                                    macrursors--overlays))
                  ;; Start defining macro if there are still active cursors
                  (when (> (length macrursors--overlays) 0)
                    (macrursors-start)))
              (save-excursion
                (macrursors--add-overlay-at-point pt)
                (setq macrursors--instance 'point)
                (macrursors-start))))))))


;;;; Functions that apply the defined macro across all macrursors
(defun macrursors-start ()
  "Start kmacro recording, apply to all cursors with `macrursors-end'."
  (interactive)
  (macrursors-mode 1)
  (call-interactively #'kmacro-start-macro))

(defmacro macrursors--wrap-collapse-undo (&rest body)
  "Like `progn' but perform BODY with undo collapsed."
  (declare (indent 0) (debug t))
  (let ((handle (make-symbol "--change-group-handle--"))
        (success (make-symbol "--change-group-success--")))
    `(let ((,handle (prepare-change-group))
           ;; Don't truncate any undo data in the middle of this.
           (undo-outer-limit nil)
           (undo-limit most-positive-fixnum)
           (undo-strong-limit most-positive-fixnum)
           (,success nil))
       (unwind-protect
           (progn
             (activate-change-group ,handle)
             (prog1 ,(macroexp-progn body)
               (setq ,success t)))
         (if ,success
             (progn
               (accept-change-group ,handle)
               (undo-amalgamate-change-group ,handle))
           (cancel-change-group ,handle))))))

(defun macrursors--apply-command (overlays cmd &optional args)
  (when overlays
    (save-excursion
      (dolist (ov overlays)
        (goto-char (overlay-start ov))
        (if (commandp cmd)
            (call-interactively cmd)
          (apply cmd args))))))

(defun macrursors-apply-command (cmd &rest args)
  (macrursors--wrap-collapse-undo
    (macrursors--apply-command
     macrursors--overlays
     cmd args)))

(defun macrursors--apply-kmacros ()
  "Apply kmacros."
  (interactive)
  (macrursors-apply-command #'execute-kbd-macro
                            last-kbd-macro))

(defun macrursors--toggle-modes (func &rest args)
  (cond
   ((not (symbolp func)) (funcall func))
   ((and (fboundp func)
         (string-suffix-p "-mode" (symbol-name func)))
    (apply func args)))
  ;; Return nil to continue hook processing.
  nil)

;; NOTE DOES NOT WORK WHEN CALLED FROM M-x!!!
;; FIXME applying time
;;;###autoload
(defun macrursors-end ()
  "Finish recording macro and apply it to all cursors."
  (interactive)
  (if (not defining-kbd-macro)
      (error "Not defining a macro")
    (end-kbd-macro)
    (run-hook-wrapped 'macrursors-pre-finish-hook
                      #'macrursors--toggle-modes -1)
    (macrursors--apply-kmacros)
    (run-hook-wrapped 'macrursors-post-finish-hook
                      #'macrursors--toggle-modes +1)
    (macrursors--remove-all-overlays)
    (macrursors-mode -1)))

;;;###autoload
(defun macrursors-early-quit ()
  "Abort recording macro and remove all cursors."
  (interactive)
  (if (region-active-p)
      (progn
	      (deactivate-mark)
	      (when defining-kbd-macro
	        (end-kbd-macro)
	        (macrursors-start)))
    (when defining-kbd-macro (end-kbd-macro))
    (macrursors--remove-all-overlays)
    (macrursors-mode -1)))

(provide 'macrursors)

;;; macrursors.el ends here
