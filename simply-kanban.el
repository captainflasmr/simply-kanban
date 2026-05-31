;;; simply-kanban.el --- Org-linked kanban board -*- lexical-binding: t; -*-

;; Author: James Dyer <captainflasmr@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.2"))
;; Keywords: outlines, convenience, tools, org
;; URL: https://github.com/captainflasmr/simply-kanban

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.

;;; Commentary:

;; A lightweight kanban board for Org files.  The board is a live view of
;; the current Org buffer:
;;
;; - Columns are the buffer's Org TODO keywords (the `#+TODO:' workflow,
;;   e.g. TODO NEXT DOING | DONE).
;; - Cards are the headings carrying those keywords.
;; - Moving a card to the next/previous column changes the heading's TODO
;;   state via `org-todo', written straight back to the Org buffer -- the
;;   Org file is the single source of truth, there is no separate database.
;;
;; The rendering and navigation are modelled on the kanban view in
;; `simply-annotate'.
;;
;; Usage: open an Org file and M-x simply-kanban.
;;
;;   n / p          next / previous card
;;   TAB / S-TAB    next / previous column   (also f / b)
;;   } / S-right    advance card to the next stage
;;   { / S-left     send card back a stage
;;   RET            jump to the heading in the Org buffer
;;   g              refresh
;;   q              quit

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;; Customization

(defgroup simply-kanban nil
  "Org-linked kanban board."
  :group 'org
  :prefix "simply-kanban-")

(defcustom simply-kanban-column-width 30
  "Width in characters of each kanban column."
  :type 'integer
  :group 'simply-kanban)

(defcustom simply-kanban-column-gap 2
  "Number of spaces between columns."
  :type 'integer
  :group 'simply-kanban)

(defcustom simply-kanban-buffer-name "*Simply Kanban*"
  "Name of the kanban board buffer."
  :type 'string
  :group 'simply-kanban)

(defface simply-kanban-column-header
  '((t :weight bold :inherit org-document-title))
  "Face for kanban column headers."
  :group 'simply-kanban)

;;; Board state (buffer-local in the board buffer)

(defvar-local simply-kanban--source-buffer nil
  "The Org buffer this board was built from.")

(defvar-local simply-kanban--keywords nil
  "Ordered list of TODO keywords forming the board's columns.")

;;; Data collection

(defun simply-kanban--source-keywords (buffer)
  "Return the ordered TODO keywords (columns) for Org BUFFER."
  (with-current-buffer buffer
    (or (and (boundp 'org-todo-keywords-1) org-todo-keywords-1)
        '("TODO" "DONE"))))

(defun simply-kanban--collect-tasks (buffer)
  "Collect TODO entries from Org BUFFER as a list of card plists.
Each plist has :keyword :title :priority :tags :marker."
  (with-current-buffer buffer
    (org-with-wide-buffer
     (let (tasks)
       (org-map-entries
        (lambda ()
          (let ((kw (org-get-todo-state)))
            (when kw
              (let ((comps (org-heading-components)))
                (push (list :keyword kw
                            :title (or (org-get-heading t t t t) "")
                            :priority (nth 3 comps)
                            :tags (org-get-tags nil t)
                            :marker (point-marker))
                      tasks))))))
       (nreverse tasks)))))

;;; Rendering

(defun simply-kanban--pad (string width)
  "Pad or truncate STRING to exactly WIDTH display columns."
  (let ((len (string-width string)))
    (cond ((= len width) string)
          ((< len width) (concat string (make-string (- width len) ?\s)))
          (t (truncate-string-to-width string width)))))

(defun simply-kanban--wrap (text width)
  "Word-wrap TEXT to WIDTH columns, returning a list of lines."
  (if (<= (string-width text) width)
      (list text)
    (with-temp-buffer
      (insert text)
      (let ((fill-column width))
        (fill-region (point-min) (point-max)))
      (split-string (buffer-string) "\n"))))

(defun simply-kanban--format-card (task width)
  "Return a list of card lines for TASK fitting in WIDTH columns."
  (let* ((inner (max 1 (- width 4)))
         (prio (plist-get task :priority))
         (tags (plist-get task :tags))
         (title-lines (simply-kanban--wrap (plist-get task :title) inner))
         (meta (string-join
                (delq nil
                      (list (when prio (format "[#%c]" prio))
                            (when tags (concat ":" (string-join tags ":") ":"))))
                " "))
         (box (lambda (s)
                (format "│ %s │"
                        (simply-kanban--pad (truncate-string-to-width s inner)
                                            inner))))
         lines)
    (push (concat "┌" (make-string (- width 2) ?─) "┐") lines)
    (dolist (tl title-lines)
      (push (funcall box tl) lines))
    (unless (string-empty-p meta)
      (push (funcall box meta) lines))
    (push (concat "└" (make-string (- width 2) ?─) "┘") lines)
    (nreverse lines)))

(defun simply-kanban--column-cells (keyword tasks width)
  "Return the propertized line-strings for the KEYWORD column.
TASKS is the full task list; only those matching KEYWORD are shown.
Each returned string is exactly WIDTH columns wide."
  (let* ((col-tasks (seq-filter (lambda (tk) (equal (plist-get tk :keyword) keyword))
                                tasks))
         (header (propertize (format " %s · %d" keyword (length col-tasks))
                             'face 'simply-kanban-column-header
                             'simply-kanban-keyword keyword))
         (cells (list (simply-kanban--pad header width)
                      (simply-kanban--pad "" width))))
    (dolist (task col-tasks)
      (let ((marker (plist-get task :marker))
            (first t))
        (dolist (line (simply-kanban--format-card task width))
          (let ((props (append (list 'simply-kanban-marker marker
                                     'simply-kanban-keyword keyword)
                               (when first
                                 (list 'simply-kanban-card-anchor marker)))))
            (push (apply #'propertize (simply-kanban--pad line width) props) cells))
          (setq first nil)))
      (push (simply-kanban--pad "" width) cells))
    (nreverse cells)))

(defun simply-kanban--render (board-buffer source-buffer)
  "Render the kanban board for SOURCE-BUFFER into BOARD-BUFFER."
  (with-current-buffer board-buffer
    (let* ((inhibit-read-only t)
           (tasks (simply-kanban--collect-tasks source-buffer))
           (keywords (simply-kanban--source-keywords source-buffer))
           (width simply-kanban-column-width)
           (gap (make-string simply-kanban-column-gap ?\s))
           (columns (mapcar (lambda (kw) (simply-kanban--column-cells kw tasks width))
                            keywords))
           (nrows (apply #'max 0 (mapcar #'length columns))))
      (erase-buffer)
      (setq simply-kanban--source-buffer source-buffer
            simply-kanban--keywords keywords)
      (dotimes (row nrows)
        (let ((segments (mapcar (lambda (col)
                                  (or (nth row col)
                                      (simply-kanban--pad "" width)))
                                columns)))
          (insert (string-join segments gap) "\n")))
      (goto-char (point-min))
      (simply-kanban-next-card))))

;;; Navigation helpers

(defun simply-kanban--anchors ()
  "Return an ordered list of (POSITION . MARKER) for each card on the board."
  (let ((pos (point-min))
        acc)
    (while pos
      (let ((m (get-text-property pos 'simply-kanban-card-anchor)))
        (when m (push (cons pos m) acc)))
      (setq pos (next-single-property-change pos 'simply-kanban-card-anchor)))
    (nreverse acc)))

(defun simply-kanban--column-at-point ()
  "Return the column keyword at point, or nil."
  (get-text-property (point) 'simply-kanban-keyword))

(defun simply-kanban--marker-at-point ()
  "Return the source marker for the card at point, or nil."
  (get-text-property (point) 'simply-kanban-marker))

;;; Navigation commands

(defun simply-kanban-next-card ()
  "Move point to the next card."
  (interactive)
  (let ((next (seq-find (lambda (a) (> (car a) (point)))
                        (simply-kanban--anchors))))
    (if next (goto-char (car next)) (message "No next card"))))

(defun simply-kanban-prev-card ()
  "Move point to the previous card."
  (interactive)
  (let ((prev (seq-find (lambda (a) (< (car a) (point)))
                        (reverse (simply-kanban--anchors)))))
    (if prev (goto-char (car prev)) (message "No previous card"))))

(defun simply-kanban--column-header-pos (keyword)
  "Return the buffer position of KEYWORD's column header, or nil."
  (let ((pos (point-min)) found)
    (while (and (not found) pos)
      (when (equal keyword (get-text-property pos 'simply-kanban-keyword))
        (setq found pos))
      (setq pos (next-single-property-change pos 'simply-kanban-keyword)))
    found))

(defun simply-kanban--goto-column (keyword)
  "Move point to the first card of KEYWORD's column, or its header."
  (let ((card (seq-find (lambda (a)
                          (equal keyword
                                 (get-text-property (car a) 'simply-kanban-keyword)))
                        (simply-kanban--anchors))))
    (cond (card (goto-char (car card)))
          ((simply-kanban--column-header-pos keyword)
           (goto-char (simply-kanban--column-header-pos keyword))
           (message "No cards in %s" keyword))
          (t (message "No such column")))))

(defun simply-kanban-next-column ()
  "Move to the first card of the next column."
  (interactive)
  (let* ((cur (or (simply-kanban--column-at-point) (car simply-kanban--keywords)))
         (idx (cl-position cur simply-kanban--keywords :test #'equal))
         (next (and idx (nth (1+ idx) simply-kanban--keywords))))
    (if next (simply-kanban--goto-column next) (message "Last column"))))

(defun simply-kanban-prev-column ()
  "Move to the first card of the previous column."
  (interactive)
  (let* ((cur (or (simply-kanban--column-at-point) (car (last simply-kanban--keywords))))
         (idx (cl-position cur simply-kanban--keywords :test #'equal))
         (prev (and idx (> idx 0) (nth (1- idx) simply-kanban--keywords))))
    (if prev (simply-kanban--goto-column prev) (message "First column"))))

;;; Actions

(defun simply-kanban-goto ()
  "Jump to the Org heading for the card at point."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (marker-buffer marker)))
        (message "Point is not on a card")
      (pop-to-buffer (marker-buffer marker))
      (goto-char marker)
      (org-back-to-heading t)
      (cond ((fboundp 'org-fold-show-entry) (org-fold-show-entry))
            ((fboundp 'org-show-entry) (org-show-entry))))))

(defun simply-kanban--set-state (marker keyword)
  "Set the TODO state of the heading at MARKER to KEYWORD."
  (with-current-buffer (marker-buffer marker)
    (org-with-wide-buffer
     (goto-char marker)
     (org-back-to-heading t)
     (org-todo keyword))))

(defun simply-kanban--goto-marker (marker)
  "Move point to the card whose source position matches MARKER."
  (let ((target (seq-find
                 (lambda (a)
                   (let ((m (cdr a)))
                     (and (marker-buffer m)
                          (eq (marker-buffer m) (marker-buffer marker))
                          (= (marker-position m) (marker-position marker)))))
                 (simply-kanban--anchors))))
    (when target (goto-char (car target)))))

(defun simply-kanban--move (delta)
  "Move the card at point DELTA stages along the workflow."
  (let ((marker (simply-kanban--marker-at-point))
        (kw (simply-kanban--column-at-point)))
    (if (not marker)
        (message "Point is not on a card")
      (let* ((idx (cl-position kw simply-kanban--keywords :test #'equal))
             (new-idx (and idx (+ idx delta))))
        (if (or (null new-idx) (< new-idx 0)
                (>= new-idx (length simply-kanban--keywords)))
            (message "No further stage")
          (let ((new-kw (nth new-idx simply-kanban--keywords)))
            (simply-kanban--set-state marker new-kw)
            (simply-kanban-refresh)
            (simply-kanban--goto-marker marker)
            (message "%s" new-kw)))))))

(defun simply-kanban-advance ()
  "Advance the card at point to the next stage."
  (interactive)
  (simply-kanban--move 1))

(defun simply-kanban-retreat ()
  "Send the card at point back a stage."
  (interactive)
  (simply-kanban--move -1))

(defun simply-kanban-refresh ()
  "Rebuild the board from its source buffer."
  (interactive)
  (unless (derived-mode-p 'simply-kanban-mode)
    (user-error "Not in a kanban board"))
  (let ((source simply-kanban--source-buffer)
        (pt (point)))
    (unless (buffer-live-p source)
      (user-error "Source Org buffer is gone"))
    (simply-kanban--render (current-buffer) source)
    (goto-char (min pt (point-max)))))

;;; Mode

(defvar simply-kanban-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'simply-kanban-next-card)
    (define-key map (kbd "p") #'simply-kanban-prev-card)
    (define-key map (kbd "f") #'simply-kanban-next-column)
    (define-key map (kbd "b") #'simply-kanban-prev-column)
    (define-key map (kbd "TAB") #'simply-kanban-next-column)
    (define-key map (kbd "<backtab>") #'simply-kanban-prev-column)
    (define-key map (kbd "RET") #'simply-kanban-goto)
    (define-key map (kbd "}") #'simply-kanban-advance)
    (define-key map (kbd "{") #'simply-kanban-retreat)
    (define-key map (kbd "<S-right>") #'simply-kanban-advance)
    (define-key map (kbd "<S-left>") #'simply-kanban-retreat)
    (define-key map (kbd "g") #'simply-kanban-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `simply-kanban-mode'.")

(define-derived-mode simply-kanban-mode special-mode "Kanban"
  "Major mode for the Org-linked kanban board.

\\{simply-kanban-mode-map}"
  (setq-local truncate-lines t)
  (setq-local cursor-type 'box)
  (hl-line-mode 1))

;;;###autoload
(defun simply-kanban ()
  "Open a kanban board for the current Org buffer.
Columns are the buffer's Org TODO keywords; cards are the headings
carrying those keywords."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (let ((source (current-buffer))
        (buffer (get-buffer-create simply-kanban-buffer-name)))
    (with-current-buffer buffer
      (simply-kanban-mode)
      (simply-kanban--render buffer source))
    (pop-to-buffer buffer)))

(provide 'simply-kanban)
;;; simply-kanban.el ends here
