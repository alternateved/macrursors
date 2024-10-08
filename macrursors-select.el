;;; macrursors-select.el --- Secondary selection for macrursors -*- lexical-binding: t; -*-

;;; Commentary:
;; Utilities for creating, expanding and narrowing secondary selection in which
;; macrursors will be placed. When secondary selection is active, no additional
;; cursor can be placed outside of it.

;;; Code:

(require 'macrursors)
(require 'thingatpt)
(require 'cl-lib)
(require 'select)

(defun macrursors-select--set (beg end &optional type)
  "Set the boundaries of the secondary selection.

BEG and END are the boundaries. When TYPE (a symbol) is provided,
message the user about the type of object selected."
  (or mouse-secondary-start
      (setq mouse-secondary-start (make-marker)))
  (move-marker mouse-secondary-start beg)
  (move-overlay mouse-secondary-overlay beg end (current-buffer))
  (overlay-put mouse-secondary-overlay 'macrursors-select-type type)
  (when type (message "%S" type))

  ;; https://lists.gnu.org/archive/html/bug-gnu-emacs/2024-06/msg01192.html
  (let ((selection (buffer-substring
                    (overlay-start mouse-secondary-overlay)
                    (overlay-end mouse-secondary-overlay))))
    (condition-case nil
        (gui-set-selection 'SECONDARY selection)
      (error selection))))

(defun macrursors-select--region ()
  (macrursors-select--set (region-beginning) (region-end) 'region)
  (deactivate-mark))

(defun macrursors-select--type (type)
  (when-let* ((type)
              (bounds (bounds-of-thing-at-point type))
              (beg (car bounds))
              (end (cdr bounds)))
    (macrursors-select--set beg end type)))

(defcustom macrursors-select-types
  '((prog-mode defun list line)
    (text-mode page paragraph sentence line)
    (special-mode paragraph line))
  "Alist of things at point to set secondary selection.

Each element is of the form
(mode . (thing1 thing2 ...)),

where MODE is a major-mode and each THING is accessible via
`thing-at-point'. The entry corresponding to the first matching
derived-mode is used for cycling the secondary selection when
calling `macrursors-select'."
  :group 'macrursors
  :type 'list
  :local t)

(defun macrursors-select--filter-cursors ()
  "Remove macrursors outside the active secondary selection."
  (when (and macrursors--overlays
             (macrursors--inside-secondary-selection))
    (let ((beg (overlay-start mouse-secondary-overlay))
          (end (overlay-end mouse-secondary-overlay)))
      (setq macrursors--overlays
            (cl-loop for ov in macrursors--overlays
                     if (and (<= beg (overlay-start ov))
                             (>= end (overlay-end ov)))
                     collect ov into live-overlays
                     else do (delete-overlay ov)
                     finally return live-overlays))
      (when defining-kbd-macro
	      (end-kbd-macro)
	      (macrursors-start)))))

(defun macrursors-select--expand-cursors (&optional search-start search-end)
  "Expand macrursors inside bounds SEARCH-START and SEARCH-END.

Restart `macrursors-mode' if necessary."
  (when (and macrursors-mode
             search-start search-end
             (or (>= search-start (overlay-start mouse-secondary-overlay))
                 (<= search-end   (overlay-end mouse-secondary-overlay))))
    (macrursors-early-quit)
    (pcase macrursors--instance
      ((pred stringp) (macrursors-mark-all-instances-of macrursors--instance))
      ((pred symbolp) (funcall
                       (intern
                        (concat "macrursors-mark-all-"
                                (symbol-name macrursors--instance)
                                "s")))))))

;;;###autoload
(defun macrursors-select ()
  "Create a secondary selection from an active region.

Without an active region, cycle through secondary selections of
objects around point listed in `macrursors-select-types'.

This command activates a transient keymap so it can be invoked
repeatedly by pressing `\\<macrursors-mark-map>\\[macrursors-select]'."
  (interactive)
  (let (search-start search-end)
    (if (use-region-p)
        (progn
          (setq search-start (region-beginning)
                search-end   (region-end))
          (macrursors-select--region))
      (let ((types (cl-some (lambda (entry) (and (derived-mode-p (car entry))
                                                 (cdr entry)))
                            macrursors-select-types)))
        (setq search-start  (overlay-start mouse-secondary-overlay)
              search-end    (overlay-end mouse-secondary-overlay))
        (cl-loop with sel-type =
                 (or
                  (get-char-property (max (1- (point)) (point-min)) 'macrursors-select-type)
                  (get-char-property (min (1+ (point)) (point-max)) 'macrursors-select-type))
                 for (head . tail) on (cons nil types)
                 when (eq sel-type head)
                 if (macrursors-select--type (or (car tail) (car types)))
                 return t
                 else do (setq sel-type (car tail)))))
    ;; Remove cursors outside
    (macrursors-select--filter-cursors)
    ;; Add new cursors inside
    (macrursors-select--expand-cursors search-start search-end)
    ;; Start cycling
    (set-transient-map macrursors-select-map)))

(defvar macrursors-select-map
  (let ((map (make-sparse-keymap)))
    (define-key map " " 'macrursors-select)
    (define-key map [remap keyboard-quit] 'macrursors-select-clear)
    map))

(defun macrursors-select-clear ()
  "Remove secondary selection."
  (interactive)
  (and mouse-secondary-overlay
       (eq (overlay-buffer mouse-secondary-overlay) (current-buffer))
       (delete-overlay mouse-secondary-overlay)))

;;;###autoload
(defun macrursors-select-toggle ()
  "Remove existings secondary selection or create a new one from an active region."
  (interactive)
  (if (secondary-selection-exist-p)
      (macrursors-select-clear)
    (macrursors-select)))

(define-key macrursors-mark-map (kbd "SPC") #'macrursors-select)
(define-key macrursors-mark-map (kbd "C-g") #'macrursors-select-clear)

(provide 'macrursors-select)

;;; macrursors-select.el ends here
