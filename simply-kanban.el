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

(defcustom simply-kanban-auto-refresh t
  "When non-nil, refresh the board whenever its source Org buffer is saved."
  :type 'boolean
  :group 'simply-kanban)

(defface simply-kanban-column-header
  '((t :weight bold :inherit org-document-title))
  "Face for kanban column headers."
  :group 'simply-kanban)

;;; Board state (buffer-local in the board buffer)

(defvar-local simply-kanban--source-spec nil
  "Descriptor of where this board's tasks come from.
Either (buffer . BUFFER) for a single Org buffer, or (files . FILES)
for a list of Org files (e.g. the agenda files).  Re-resolved to live
buffers on every render so the board can pick up new files.")

(defvar-local simply-kanban--source-buffers nil
  "The live Org buffers this board last aggregated, for hook management.")

(defvar-local simply-kanban--keywords nil
  "Ordered list of TODO keywords forming the board's columns.")

(defvar simply-kanban--multi-source nil
  "Bound non-nil while rendering a board that spans more than one file.
When set, cards show their source file so they can be told apart.")

;;; Data collection

(defun simply-kanban--source-keywords (buffer)
  "Return the ordered TODO keywords (columns) for Org BUFFER."
  (with-current-buffer buffer
    (or (and (boundp 'org-todo-keywords-1) org-todo-keywords-1)
        '("TODO" "DONE"))))

(defun simply-kanban--collect-tasks (buffer)
  "Collect TODO entries from Org BUFFER as a list of card plists.
Each plist has :keyword :title :priority :tags :file :marker."
  (with-current-buffer buffer
    (let ((file (file-name-nondirectory (or (buffer-file-name) (buffer-name)))))
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
                              :file file
                              :marker (point-marker))
                        tasks))))))
         (nreverse tasks))))))

(defun simply-kanban--spec-buffers (spec)
  "Resolve SPEC to a list of live Org buffers."
  (pcase spec
    (`(buffer . ,buffer) (and (buffer-live-p buffer) (list buffer)))
    (`(files . ,files)
     (delq nil (mapcar (lambda (f)
                         (when (and f (file-exists-p f))
                           (find-file-noselect f)))
                       files)))))

(defun simply-kanban--collect-all (buffers)
  "Collect tasks from every buffer in BUFFERS, concatenated."
  (apply #'append (mapcar #'simply-kanban--collect-tasks buffers)))

(defun simply-kanban--merge-keywords (buffers)
  "Return the union of TODO keywords across BUFFERS, preserving order.
Keywords are taken in the order they first appear, so for a single
buffer (or buffers sharing a workflow) the natural order is kept."
  (let (result)
    (dolist (buffer buffers)
      (dolist (kw (simply-kanban--source-keywords buffer))
        (unless (member kw result)
          (push kw result))))
    (nreverse result)))

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
         (file (and simply-kanban--multi-source (plist-get task :file)))
         (title-lines (simply-kanban--wrap (plist-get task :title) inner))
         (meta (string-join
                (delq nil
                      (list (when prio (format "[#%c]" prio))
                            (when tags (concat ":" (string-join tags ":") ":"))
                            (when file (concat "» " file))))
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

(defun simply-kanban--render (board-buffer spec)
  "Render the kanban board described by SPEC into BOARD-BUFFER.
SPEC is resolved to a list of Org buffers via `simply-kanban--spec-buffers'."
  (with-current-buffer board-buffer
    (let* ((inhibit-read-only t)
           (buffers (simply-kanban--spec-buffers spec))
           (simply-kanban--multi-source (> (length buffers) 1))
           (tasks (simply-kanban--collect-all buffers))
           (keywords (simply-kanban--merge-keywords buffers))
           (width simply-kanban-column-width)
           (gap (make-string simply-kanban-column-gap ?\s))
           (columns (mapcar (lambda (kw) (simply-kanban--column-cells kw tasks width))
                            keywords))
           (nrows (apply #'max 0 (mapcar #'length columns))))
      (erase-buffer)
      (setq simply-kanban--source-spec spec
            simply-kanban--source-buffers buffers
            simply-kanban--keywords keywords)
      (if (null buffers)
          (insert "No source Org buffers.\n")
        (dotimes (row nrows)
          (let ((segments (mapcar (lambda (col)
                                    (or (nth row col)
                                        (simply-kanban--pad "" width)))
                                  columns)))
            (insert (string-join segments gap) "\n"))))
      (simply-kanban--install-hooks board-buffer buffers)
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
  "Set the TODO state of the heading at MARKER to KEYWORD.
KEYWORD must be valid in the heading's own Org file."
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
  "Move the card at point DELTA stages along its file's workflow.
Stages follow the card's own Org file keyword sequence, so a card never
lands in a state its file does not define -- important when aggregating
files that use different workflows."
  (let ((marker (simply-kanban--marker-at-point))
        (kw (simply-kanban--column-at-point)))
    (if (not (and marker (buffer-live-p (marker-buffer marker))))
        (message "Point is not on a card")
      (let* ((kws (simply-kanban--source-keywords (marker-buffer marker)))
             (idx (cl-position kw kws :test #'equal))
             (new-idx (and idx (+ idx delta))))
        (if (or (null idx) (< new-idx 0) (>= new-idx (length kws)))
            (message "No further stage")
          (let ((new-kw (nth new-idx kws)))
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
  "Rebuild the board, re-resolving its source spec."
  (interactive)
  (unless (derived-mode-p 'simply-kanban-mode)
    (user-error "Not in a kanban board"))
  (let ((spec simply-kanban--source-spec)
        (pt (point)))
    (unless spec
      (user-error "This board has no source"))
    (simply-kanban--render (current-buffer) spec)
    (goto-char (min pt (point-max)))))

;;; Auto-refresh

(defun simply-kanban--boards-for (source)
  "Return the live board buffers that aggregate SOURCE."
  (seq-filter (lambda (buf)
                (memq source (buffer-local-value 'simply-kanban--source-buffers buf)))
              (buffer-list)))

(defun simply-kanban--after-source-save ()
  "Refresh any board built from the just-saved Org buffer.
Installed buffer-locally on each source buffer's `after-save-hook'."
  (dolist (board (simply-kanban--boards-for (current-buffer)))
    (with-current-buffer board
      (simply-kanban-refresh))))

(defun simply-kanban--on-board-kill ()
  "Drop each source's refresh hook when this board was its last consumer.
Installed buffer-locally on the board buffer's `kill-buffer-hook'."
  (let ((this (current-buffer)))
    (dolist (source simply-kanban--source-buffers)
      (when (buffer-live-p source)
        (unless (seq-some (lambda (buf) (not (eq buf this)))
                          (simply-kanban--boards-for source))
          (with-current-buffer source
            (remove-hook 'after-save-hook #'simply-kanban--after-source-save t)))))))

(defun simply-kanban--install-hooks (board sources)
  "Wire up auto-refresh between BOARD and its SOURCES (a list of buffers)."
  (with-current-buffer board
    (add-hook 'kill-buffer-hook #'simply-kanban--on-board-kill nil t))
  (when simply-kanban-auto-refresh
    (dolist (source sources)
      (with-current-buffer source
        (add-hook 'after-save-hook #'simply-kanban--after-source-save nil t)))))

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

(defun simply-kanban--open (spec)
  "Build and display a kanban board for SPEC."
  (let ((buffer (get-buffer-create simply-kanban-buffer-name)))
    (with-current-buffer buffer
      (simply-kanban-mode)
      (simply-kanban--render buffer spec))
    (pop-to-buffer buffer)))

;;;###autoload
(defun simply-kanban ()
  "Open a kanban board for the current Org buffer.
Columns are the buffer's Org TODO keywords; cards are the headings
carrying those keywords."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (simply-kanban--open (cons 'buffer (current-buffer))))

;;;###autoload
(defun simply-kanban-agenda ()
  "Open a kanban board aggregating every Org agenda file.
Columns are the union of the agenda files' TODO keywords; each card
shows which file it comes from.  Moving a card follows its own file's
workflow and is written back to that file."
  (interactive)
  (let ((files (org-agenda-files)))
    (unless files
      (user-error "No agenda files (see `org-agenda-files')"))
    (simply-kanban--open (cons 'files files))))

(provide 'simply-kanban)
;;; simply-kanban.el ends here
