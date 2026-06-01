;;; simply-kanban.el --- Org-linked kanban board -*- lexical-binding: t; -*-

;; Author: James Dyer <captainflasmr@gmail.com>
;; Version: 0.4.0
;; Package-Requires: ((emacs "27.2") (transient "0.4"))
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
;; A single Org file may also define several boards: make each board a
;; level-1 heading (with no TODO keyword) and put its cards as TODO
;; headings in that subtree.  `simply-kanban' then prompts for which board
;; to open, and `B' switches between them.  Any loose level-1 TODO headings
;; at the top of such a file are still offered as a flat board named by
;; `simply-kanban-toplevel-name'.
;;
;; Usage: open an Org file and M-x simply-kanban.
;;
;; From inside the Org file, M-x `simply-kanban-show-card' is the inverse of
;; the board's `v'/RET: it finds the heading at point among the board's cards
;; and selects it, showing the board in another window while focus stays in the
;; Org buffer.  When no board is open it creates one first, so it always tries
;; to take you to a card.
;;
;;   n / p          next / previous card
;;   TAB / S-TAB    next / previous column   (also f / b)
;;   } / S-right    advance card to the next stage
;;   { / S-left     send card back a stage
;;   s              set status (choose any stage)
;;   RET            reveal the heading (focus stays on the board)
;;   v              jump to the heading in another window
;;   k              delete the heading (with confirmation)
;;   t              filter board by tag
;;   T              clear tag filter
;;   S              filter board by sprint (SPRINT property)
;;   :              set the Org tags on the card at point
;;   ,              set the Org priority of the card at point
;;   ;              set the Org effort estimate on the card at point
;;   #              set the sprint (SPRINT property) on the card at point
;;   e              toggle the body of the card at point
;;   E              toggle the body of every card
;;   F              toggle follow mode
;;   B              switch board (multi-board files only)
;;   g              refresh
;;   SPC / ?        open the transient menu
;;   q              quit

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'pulse)
(require 'transient)

;;; Customization

(defgroup simply-kanban nil
  "Org-linked kanban board."
  :group 'org
  :prefix "simply-kanban-")

(defcustom simply-kanban-min-column-width 16
  "Minimum width in characters of each kanban column.
Columns otherwise expand to fill the board window, divided evenly."
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

(defcustom simply-kanban-sort-by-priority nil
  "When non-nil, sort cards within each column by priority (A > B > C > none)."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-effort t
  "When non-nil, show each card's Org effort estimate and a per-column total.
The estimate is read from the card heading's `Effort' property (the value
Org's \\[org-set-effort] sets); cards without one show nothing.  The column
header then appends the summed effort of its cards in brackets."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-default-sprint nil
  "Sprint number a board filters to when first opened, or nil for all sprints.
A card's sprint is its `SPRINT' property (an integer, inherited from parent
headings); set it from the board with \\[simply-kanban-set-sprint].  When this
is an integer, opening a board shows only cards in that sprint; change the
displayed sprint at any time with \\[simply-kanban-set-sprint-filter] (empty
input clears the filter).  When nil, boards open showing every sprint."
  :type '(choice (const :tag "All sprints" nil) integer)
  :group 'simply-kanban)

(defcustom simply-kanban-show-sprint t
  "When non-nil, show a card's SPRINT number on the board.
The badge is shown only while no sprint filter is active: once filtered to a
single sprint every visible card shares it, so the badge would be redundant."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-save-after-change t
  "When non-nil, save a source Org buffer after the board edits it.
Edits include changing a card's status and deleting a heading."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-toplevel-name "Top Level"
  "Name of the flat board holding a file's loose level-1 TODO headings.
In a multi-board file (one with level-1 container headings), this board
gathers the TODO headings that sit directly at the top level rather than
inside a container."
  :type 'string
  :group 'simply-kanban)

(defcustom simply-kanban-all-boards t
  "When non-nil, the board chooser offers an aggregate of every board in a file.
In a multi-board Org file, `simply-kanban' and \\[simply-kanban-switch-board]
then include an extra entry (named by `simply-kanban-all-boards-name') showing
the cards from all the file's boards at once, each card denoting which board it
belongs to."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-all-boards-name "All Boards"
  "Name of the synthetic board aggregating every board in a multi-board file.
Offered in the board chooser when `simply-kanban-all-boards' is non-nil."
  :type 'string
  :group 'simply-kanban)

(defface simply-kanban-column-header
  '((t :weight bold :inherit org-document-title))
  "Face for kanban column headers."
  :group 'simply-kanban)

(defface simply-kanban-current-card
  '((t :weight bold))
  "Face used to highlight the card at point."
  :group 'simply-kanban)

(defface simply-kanban-tag
  '((t :inherit shadow))
  "Face for the tags shown on a card.
Deliberately does not inherit `org-tag': that face is commonly scaled to a
height other than 1.0, which would break the board's monospace alignment."
  :group 'simply-kanban)

(defface simply-kanban-effort
  '((t :inherit org-special-keyword))
  "Face for the effort estimate badge shown on a card and column total."
  :group 'simply-kanban)

(defface simply-kanban-sprint
  '((t :inherit org-special-keyword))
  "Face for the sprint badge shown on a card."
  :group 'simply-kanban)

(defcustom simply-kanban-pulse-on-goto t
  "When non-nil, briefly pulse the Org heading when revealing it from the board.
Applies both to \\[simply-kanban-goto] and to follow mode."
  :type 'boolean
  :group 'simply-kanban)

(defface simply-kanban-flash
  '((t :inherit highlight))
  "Face used to briefly pulse a heading when jumping to it from the board."
  :group 'simply-kanban)

(defface simply-kanban-mark
  '((t :inherit highlight))
  "Face filling the card matched by \\[simply-kanban-show-card].
A temporary cue marking the card that relates to the Org buffer; it is cleared
as soon as you navigate to another card."
  :group 'simply-kanban)

(defun simply-kanban--keyword-face (keyword)
  "Return the face for TODO KEYWORD, using Org's native face lookup."
  (org-get-todo-face keyword))

;;; Board state (buffer-local in the board buffer)

(defvar-local simply-kanban--source-spec nil
  "Descriptor of where this board's tasks come from.
One of:
  (buffer . BUFFER)        -- every TODO heading in a single Org buffer;
  (board BUFFER MARKER)    -- the TODO headings in the subtree of the
                              level-1 board heading at MARKER;
  (files . FILES)          -- a list of Org files (e.g. the agenda files).
Re-resolved to live buffers on every render so the board can pick up
new files.")

(defvar-local simply-kanban--source-buffers nil
  "The live Org buffers this board last aggregated, for hook management.")

(defvar-local simply-kanban--keywords nil
  "Ordered list of TODO keywords forming the board's columns.")

(defvar-local simply-kanban--follow nil
  "When non-nil, navigating cards also shows the heading in its file.")

(defvar-local simply-kanban--highlight-overlays nil
  "Overlays bolding the regions of the card at point.")

(defvar-local simply-kanban--current-card nil
  "The marker identifying the currently highlighted card.")

(defvar-local simply-kanban--mark-overlays nil
  "Overlays filling the card flagged by `simply-kanban-show-card'.
A temporary cue showing which card matches the Org buffer; cleared as soon
as point moves to another card.")

(defvar-local simply-kanban--mark-marker nil
  "Source marker of the card currently filled by `simply-kanban-show-card'.")

(defvar-local simply-kanban--tag-filter nil
  "When non-nil, only show cards carrying this tag.")

(defvar-local simply-kanban--sprint-filter nil
  "When non-nil (an integer), only show cards in that sprint.
A card's sprint is its `SPRINT' property.  Initialised from
`simply-kanban-default-sprint' when a board is opened.")

(defvar-local simply-kanban--expanded-cards nil
  "Markers of cards whose Org body is currently shown on the board.")

(defvar simply-kanban--multi-source nil
  "Bound non-nil while rendering a board that spans more than one file.
When set, cards show their source file so they can be told apart.")

(defvar simply-kanban--show-board nil
  "Bound non-nil while rendering an aggregate of every board in one file.
When set, cards show which board they belong to (their `:board' field).")

;;; Data collection

(defun simply-kanban--source-keywords (buffer)
  "Return the ordered TODO keywords (columns) for Org BUFFER."
  (with-current-buffer buffer
    (or (and (boundp 'org-todo-keywords-1) org-todo-keywords-1)
        '("TODO" "DONE"))))

(defun simply-kanban--entry-body ()
  "Return the body text of the Org entry at point, or nil when empty.
Excludes the heading, its planning line, and any property/logbook drawer;
text belonging to child headings is not included."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point))))
      (org-end-of-meta-data t)
      ;; For an empty entry `org-end-of-meta-data' can land on the next
      ;; heading; clamp so its text is never swept into the body.
      (let ((beg (min (point) end)))
        (when (< beg end)
          (let ((body (string-trim (buffer-substring-no-properties beg end))))
            (unless (string-empty-p body) body)))))))

(defun simply-kanban--read-sprint ()
  "Return the SPRINT property of the Org entry at point as an integer, or nil.
The property is read with inheritance, so a SPRINT set on a parent (e.g. a
board container) applies to its cards.  Non-numeric values yield nil."
  (let ((s (org-entry-get nil "SPRINT" t)))
    (when (and s (string-match-p "\\`[ \t]*[0-9]+[ \t]*\\'" s))
      (string-to-number s))))

(defun simply-kanban--collect-tasks (buffer &optional restrict)
  "Collect TODO entries from Org BUFFER as a list of card plists.
Each plist has :keyword :title :body :priority :tags :effort :sprint :file
:board :marker.  :sprint is the heading's `SPRINT' property as an integer (nil
when unset or non-numeric), inherited from parent headings.  :board is filled
in only by `simply-kanban--collect-boards'.
RESTRICT limits which entries become cards:
  nil          -- every TODO heading in the buffer;
  a marker     -- only TODO headings in that heading's subtree;
  the symbol `toplevel' -- only the loose level-1 TODO headings."
  (with-current-buffer buffer
    (let ((file (if (buffer-file-name)
                    (file-name-nondirectory (buffer-file-name))
                  (buffer-name)))
          tasks)
      (org-with-wide-buffer
       (let ((collect
              (lambda ()
                (let ((kw (org-get-todo-state)))
                  (when (and kw
                             (or (not (eq restrict 'toplevel))
                                 (= (org-current-level) 1)))
                    (let ((comps (org-heading-components)))
                      (push (list :keyword kw
                                  :title (substring-no-properties
                                          (or (org-get-heading t t t t) ""))
                                  :body (simply-kanban--entry-body)
                                  :priority (nth 3 comps)
                                  :tags (org-get-tags nil t)
                                  :effort (org-entry-get nil "Effort")
                                  :sprint (simply-kanban--read-sprint)
                                  :file file
                                  :board nil
                                  :marker (point-marker))
                            tasks)))))))
         (if (markerp restrict)
             (progn
               (goto-char restrict)
               (org-map-entries collect nil 'tree))
           (org-map-entries collect)))
       (nreverse tasks)))))

(defun simply-kanban--subtree-has-todo-p ()
  "Non-nil if the subtree of the heading at point holds any TODO entry."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t))))
      (catch 'found
        (while (re-search-forward org-heading-regexp end t)
          (save-excursion
            (goto-char (match-beginning 0))
            (when (org-get-todo-state) (throw 'found t))))
        nil))))

(defun simply-kanban--scan-boards (buffer)
  "Return ((NAME . MARKER) ...) for the kanban boards defined in BUFFER.
A board is a level-1 heading without a TODO keyword whose subtree contains
at least one TODO entry; its cards are those TODO entries.  Order follows
the file.  When the buffer has no such headings the list is empty and the
whole buffer is treated as a single flat board."
  (with-current-buffer buffer
    (org-with-wide-buffer
     (goto-char (point-min))
     (let (boards)
       (while (re-search-forward "^\\*[ \t]" nil t)
         (save-excursion
           (beginning-of-line)
           (when (and (null (org-get-todo-state))
                      (simply-kanban--subtree-has-todo-p))
             (push (cons (substring-no-properties
                          (or (org-get-heading t t t t) ""))
                         (point-marker))
                   boards))))
       (nreverse boards)))))

(defun simply-kanban--board-name (marker)
  "Return the heading text of the board at MARKER, or nil."
  (when (and (markerp marker) (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (goto-char marker)
       (substring-no-properties (or (org-get-heading t t t t) "?"))))))

(defun simply-kanban--has-toplevel-todos-p (buffer)
  "Non-nil if BUFFER has any level-1 heading carrying a TODO keyword."
  (with-current-buffer buffer
    (org-with-wide-buffer
     (goto-char (point-min))
     (catch 'yes
       (while (re-search-forward "^\\*[ \t]" nil t)
         (save-excursion
           (beginning-of-line)
           (when (org-get-todo-state) (throw 'yes t))))
       nil))))

(defun simply-kanban--file-boards (buffer)
  "Return ((NAME . SPEC) ...) for every board selectable in BUFFER.
When BUFFER has container headings (see `simply-kanban--scan-boards') the
list holds one entry per container, preceded by a `simply-kanban-toplevel-name'
entry for the loose level-1 TODO headings when any exist.  Returns nil for a
plain flat file, signalling the caller to use the whole-buffer board."
  (let ((containers (simply-kanban--scan-boards buffer)))
    (when containers
      (append
       (when (simply-kanban--has-toplevel-todos-p buffer)
         (list (cons simply-kanban-toplevel-name (cons 'toplevel buffer))))
       (mapcar (lambda (b) (cons (car b) (list 'board buffer (cdr b))))
               containers)))))

(defun simply-kanban--file-boards-with-all (buffer)
  "Like `simply-kanban--file-boards', plus an \"all boards\" aggregate entry.
When BUFFER defines more than one board and `simply-kanban-all-boards' is
non-nil, the returned list is prefixed with a (NAME . (all-boards . BUFFER))
entry named by `simply-kanban-all-boards-name'.  Otherwise it is identical to
`simply-kanban--file-boards'."
  (let ((boards (simply-kanban--file-boards buffer)))
    (if (and boards (cdr boards) simply-kanban-all-boards)
        (cons (cons simply-kanban-all-boards-name (cons 'all-boards buffer))
              boards)
      boards)))

(defun simply-kanban--collect-boards (buffer)
  "Collect tasks from every board in BUFFER, tagging each card with its :board.
The board name is the container heading's text (or `simply-kanban-toplevel-name'
for the loose top-level cards), set on each card's :board field so the render
can denote it."
  (let (result)
    (dolist (entry (simply-kanban--file-boards buffer))
      (let* ((name (car entry))
             (tasks (pcase (cdr entry)
                      (`(board ,buf ,marker)
                       (and (buffer-live-p buf)
                            (simply-kanban--collect-tasks buf marker)))
                      (`(toplevel . ,buf)
                       (and (buffer-live-p buf)
                            (simply-kanban--collect-tasks buf 'toplevel))))))
        (dolist (task tasks)
          (push (plist-put task :board name) result))))
    (nreverse result)))

(defun simply-kanban--read-spec (boards)
  "Prompt for one of BOARDS (a list of (NAME . SPEC)) and return that pair."
  (let* ((names (mapcar #'car boards))
         (choice (completing-read "Kanban: " names nil t)))
    (assoc choice boards)))

(defun simply-kanban--spec-buffers (spec)
  "Resolve SPEC to a list of live Org buffers."
  (pcase spec
    (`(buffer . ,buffer) (and (buffer-live-p buffer) (list buffer)))
    (`(board ,buffer ,_marker) (and (buffer-live-p buffer) (list buffer)))
    (`(toplevel . ,buffer) (and (buffer-live-p buffer) (list buffer)))
    (`(all-boards . ,buffer) (and (buffer-live-p buffer) (list buffer)))
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

(defun simply-kanban--same-card-p (m1 m2)
  "Non-nil when markers M1 and M2 point at the same heading."
  (and (markerp m1) (markerp m2)
       (marker-buffer m1) (marker-buffer m2)
       (eq (marker-buffer m1) (marker-buffer m2))
       (= (marker-position m1) (marker-position m2))))

(defun simply-kanban--card-expanded-p (marker)
  "Non-nil when the card identified by MARKER should show its body."
  (and marker
       (seq-some (lambda (m) (simply-kanban--same-card-p m marker))
                 simply-kanban--expanded-cards)))

(defun simply-kanban--effort-minutes (effort)
  "Return EFFORT (an Org effort string such as \"1:30\") in minutes, or nil.
Returns nil when EFFORT is empty or cannot be parsed."
  (when (and effort (not (string-empty-p effort))
             (fboundp 'org-duration-to-minutes))
    (ignore-errors (org-duration-to-minutes effort))))

(defun simply-kanban--format-effort (minutes)
  "Return MINUTES formatted as an Org duration string."
  (if (fboundp 'org-duration-from-minutes)
      (org-duration-from-minutes minutes)
    (format "%dm" (round minutes))))

(defun simply-kanban--column-effort (tasks)
  "Return the summed effort of TASKS as a duration string, or nil when none set."
  (let ((total (cl-reduce
                (lambda (acc tk)
                  (+ acc (or (simply-kanban--effort-minutes (plist-get tk :effort)) 0)))
                tasks :initial-value 0)))
    (when (> total 0) (simply-kanban--format-effort total))))

(defun simply-kanban--format-card (task width)
  "Return compact card lines for TASK fitting WIDTH.
A card shows its title prefixed by a priority cookie when one is set, then
its tags (when any), its sprint (when no sprint filter is active), its effort
estimate, and -- in an aggregated board -- its board (when showing all boards
in a file) or source file.  When the card is expanded (see
`simply-kanban--expanded-cards') the Org body follows below a divider."
  (let* ((inner (max 1 (- width 4)))
         (keyword (plist-get task :keyword))
         (border-face (simply-kanban--keyword-face keyword))
         (prio (plist-get task :priority))
         (prio-cookie (pcase prio (?A "[#A]") (?B "[#B]") (?C "[#C]") (_ nil)))
         (title (or (plist-get task :title) ""))
         (title-text (if prio-cookie (concat prio-cookie " " title) title))
         (title-lines (simply-kanban--wrap title-text inner))
         (marker (plist-get task :marker))
         (tags (plist-get task :tags))
         (tags-lines (when tags
                       (simply-kanban--wrap
                        (propertize (concat ":" (mapconcat #'identity tags ":") ":")
                                    'face 'simply-kanban-tag)
                        inner)))
         (sprint (and simply-kanban-show-sprint
                      (not simply-kanban--sprint-filter)
                      (plist-get task :sprint)))
         (sprint-line (when sprint
                        (propertize (format "Sprint: %d" sprint)
                                    'face 'simply-kanban-sprint)))
         (effort (and simply-kanban-show-effort (plist-get task :effort)))
         (effort-line (when (and effort (not (string-empty-p effort)))
                        (propertize (concat "Effort: " effort)
                                    'face 'simply-kanban-effort)))
         (board-line (when simply-kanban--show-board
                       (let ((b (plist-get task :board)))
                         (when b (propertize (concat "▸ " b) 'face 'shadow)))))
         (file-line (when simply-kanban--multi-source
                      (propertize (concat "» " (or (plist-get task :file) "org"))
                                  'face 'shadow)))
         (body (and (simply-kanban--card-expanded-p marker)
                    (plist-get task :body)))
         (box (lambda (s)
                (concat (propertize "│" 'face border-face)
                        " "
                        (simply-kanban--pad s inner)
                        " "
                        (propertize "│" 'face border-face))))
         (rule (lambda (l r)
                 (concat (propertize l 'face border-face)
                         (propertize (make-string (- width 2) ?─) 'face border-face)
                         (propertize r 'face border-face))))
         lines)
    (push (funcall rule "┌" "┐") lines)
    (dolist (tl title-lines)
      (push (funcall box tl) lines))
    (dolist (tline tags-lines)
      (push (funcall box tline) lines))
    (when sprint-line
      (push (funcall box sprint-line) lines))
    (when effort-line
      (push (funcall box effort-line) lines))
    (when board-line
      (push (funcall box board-line) lines))
    (when file-line
      (push (funcall box file-line) lines))
    (when body
      (push (funcall rule "├" "┤") lines)
      (dolist (raw (split-string body "\n"))
        (if (string-empty-p raw)
            (push (funcall box "") lines)
          (dolist (bl (simply-kanban--wrap raw inner))
            (push (funcall box bl) lines)))))
    (push (funcall rule "└" "┘") lines)
    (nreverse lines)))

(defun simply-kanban--priority-order (prio)
  "Return a sort key for priority character PRIO.
Lower numbers sort first: A=0, B=1, C=2, nil=3."
  (pcase prio
    (?A 0)
    (?B 1)
    (?C 2)
    (_ 3)))

(defun simply-kanban--column-cells (keyword tasks width)
  "Return the propertized line-strings for the KEYWORD column.
TASKS is the full task list; only those matching KEYWORD are shown.
Each returned string is exactly WIDTH columns wide."
  (let* ((col-tasks (seq-filter (lambda (tk) (equal (plist-get tk :keyword) keyword))
                                tasks))
         (col-tasks (if simply-kanban-sort-by-priority
                        (sort col-tasks
                              (lambda (a b)
                                (< (simply-kanban--priority-order (plist-get a :priority))
                                   (simply-kanban--priority-order (plist-get b :priority)))))
                      col-tasks))
         (header-face (simply-kanban--keyword-face keyword))
         (effort-total (and simply-kanban-show-effort
                            (simply-kanban--column-effort col-tasks)))
         (header (propertize (concat (format " %s (%d)" keyword (length col-tasks))
                                     (when effort-total (format " [%s]" effort-total)))
                             'face header-face
                             'simply-kanban-keyword keyword))
         (divider (propertize (make-string width ?─)
                              'face 'shadow
                              'simply-kanban-keyword keyword))
         ;; Built bottom-up: the whole list is `nreverse'd below, so these
         ;; sit reversed here to render as header, divider, then a blank gap.
         (cells (list (simply-kanban--pad "" width)
                      divider
                      (simply-kanban--pad header width))))
    (dolist (task col-tasks)
      (let ((marker (plist-get task :marker))
            (first t))
        (dolist (line (simply-kanban--format-card task width))
          (let ((props (append (list 'simply-kanban-marker marker
                                     'simply-kanban-keyword keyword)
                               (when first
                                 (list 'simply-kanban-card-anchor marker)))))
            (push (apply #'propertize (simply-kanban--pad line width) props) cells))
          (setq first nil))))
    (nreverse cells)))

(defun simply-kanban--available-width ()
  "Return the usable character width for laying out columns."
  (let ((win (or (get-buffer-window simply-kanban-buffer-name)
                 (selected-window))))
    (if (window-live-p win)
        (max 20 (window-width win))
      80)))

(defun simply-kanban--column-width (ncols)
  "Return the per-column width for NCOLS columns filling the board window."
  (if (<= ncols 0)
      simply-kanban-min-column-width
    (max simply-kanban-min-column-width
         (/ (- (simply-kanban--available-width)
               (* (1- ncols) simply-kanban-column-gap))
            ncols))))

(defun simply-kanban--render (spec)
  "Render the kanban board described by SPEC into the current buffer.
SPEC is resolved to a list of Org buffers via `simply-kanban--spec-buffers'.
Columns expand to fill the board window (see `simply-kanban-min-column-width').
Must be called with the board buffer current and its window selected."
  (let* ((inhibit-read-only t)
         (buffers (simply-kanban--spec-buffers spec))
         (simply-kanban--multi-source (> (length buffers) 1))
         (simply-kanban--show-board (eq (car-safe spec) 'all-boards))
         (tasks (pcase spec
                  (`(board ,buf ,marker)
                   (and (buffer-live-p buf)
                        (simply-kanban--collect-tasks buf marker)))
                  (`(toplevel . ,buf)
                   (and (buffer-live-p buf)
                        (simply-kanban--collect-tasks buf 'toplevel)))
                  (`(all-boards . ,buf)
                   (and (buffer-live-p buf)
                        (simply-kanban--collect-boards buf)))
                  (_ (simply-kanban--collect-all buffers))))
         (tasks (if simply-kanban--tag-filter
                    (cl-remove-if-not
                     (lambda (tk) (member simply-kanban--tag-filter (plist-get tk :tags)))
                     tasks)
                  tasks))
         (tasks (if simply-kanban--sprint-filter
                    (cl-remove-if-not
                     (lambda (tk) (eql simply-kanban--sprint-filter (plist-get tk :sprint)))
                     tasks)
                  tasks))
         (keywords (simply-kanban--merge-keywords buffers))
         (width (simply-kanban--column-width (length keywords)))
         (gap (make-string simply-kanban-column-gap ?\s))
         (columns (mapcar (lambda (kw) (simply-kanban--column-cells kw tasks width))
                          keywords))
         (nrows (apply #'max 0 (mapcar #'length columns))))
    (simply-kanban--clear-mark)
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
    (simply-kanban--install-hooks (current-buffer) buffers)
    (goto-char (point-min))
    (simply-kanban-next-card)))

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

;;; Grid navigation
;;
;; Cards form a 2D grid: columns are TODO keywords, rows are the cards
;; stacked within a column.  `n'/`p' move vertically within a column and
;; `f'/`b' (TAB/S-TAB) move horizontally across columns, keeping the row.

(defun simply-kanban--grid ()
  "Return a vector of columns, each a list of (POS . MARKER) in row order."
  (let* ((ncols (length simply-kanban--keywords))
         (grid (make-vector (max 1 ncols) nil)))
    (dolist (a (simply-kanban--anchors))
      (let* ((kw (get-text-property (car a) 'simply-kanban-keyword))
             (col (cl-position kw simply-kanban--keywords :test #'equal)))
        (when col (push a (aref grid col)))))
    (dotimes (c (length grid))
      (aset grid c (nreverse (aref grid c))))
    grid))

(defun simply-kanban--coord (grid)
  "Return (COLUMN . ROW) of the card at point within GRID, or nil."
  (let ((card (simply-kanban--marker-at-point)))
    (when card
      (catch 'hit
        (dotimes (c (length grid))
          (let ((row 0))
            (dolist (a (aref grid c))
              (when (eq (cdr a) card) (throw 'hit (cons c row)))
              (setq row (1+ row)))))
        nil))))

(defun simply-kanban--first-anchor (grid)
  "Return the first card anchor in GRID, or nil."
  (catch 'hit
    (dotimes (c (length grid))
      (when (aref grid c) (throw 'hit (car (aref grid c)))))
    nil))

(defun simply-kanban--goto-card (anchor)
  "Move point to ANCHOR and update the highlight and follow view."
  (when anchor
    (goto-char (car anchor))
    (simply-kanban--highlight-card)
    (simply-kanban--follow-card)))

(defun simply-kanban-next-card ()
  "Move down to the next card in the same column."
  (interactive)
  (let* ((grid (simply-kanban--grid))
         (coord (simply-kanban--coord grid)))
    (if (null coord)
        (simply-kanban--goto-card (simply-kanban--first-anchor grid))
      (let* ((column (aref grid (car coord)))
             (row (1+ (cdr coord))))
        (if (< row (length column))
            (simply-kanban--goto-card (nth row column))
          (message "Bottom of column"))))))

(defun simply-kanban-prev-card ()
  "Move up to the previous card in the same column."
  (interactive)
  (let* ((grid (simply-kanban--grid))
         (coord (simply-kanban--coord grid)))
    (if (null coord)
        (simply-kanban--goto-card (simply-kanban--first-anchor grid))
      (let* ((column (aref grid (car coord)))
             (row (1- (cdr coord))))
        (if (>= row 0)
            (simply-kanban--goto-card (nth row column))
          (message "Top of column"))))))

(defun simply-kanban--move-column (dir)
  "Move to the nearest card DIR columns away, wrapping around.
Keeps the current row where possible."
  (let* ((grid (simply-kanban--grid))
         (ncols (length grid))
         (coord (simply-kanban--coord grid)))
    (if (null coord)
        (simply-kanban--goto-card (simply-kanban--first-anchor grid))
      (let ((col (car coord))
            (row (cdr coord)))
        (cl-loop for i from 1 below ncols
                 for c = (mod (+ col (* dir i)) ncols)
                 for column = (aref grid c)
                 when column
                 do (simply-kanban--goto-card
                     (nth (min row (1- (length column))) column))
                 and return t
                 finally (message "No other column"))))))

(defun simply-kanban-next-column ()
  "Move to the same row in the next column, wrapping around."
  (interactive)
  (simply-kanban--move-column 1))

(defun simply-kanban-prev-column ()
  "Move to the same row in the previous column, wrapping around."
  (interactive)
  (simply-kanban--move-column -1))

;;; Actions

(defun simply-kanban--flash-heading ()
  "Briefly pulse the Org heading line at point as a visual cue.
Does nothing when `simply-kanban-pulse-on-goto' is nil.  Pulsing uses an
overlay, so it animates regardless of which window has focus."
  (when simply-kanban-pulse-on-goto
    (let ((pulse-flag t))
      (pulse-momentary-highlight-one-line (point) 'simply-kanban-flash))))

(defun simply-kanban-goto ()
  "Reveal the Org heading for the card at point without leaving the board.
The heading's file is shown in another window and the heading line is briefly
pulsed; focus stays in the board."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (marker-buffer marker)))
        (message "Point is not on a card")
      (let* ((buf (marker-buffer marker))
             (win (display-buffer buf '(nil (inhibit-same-window . t)))))
        (when (window-live-p win)
          (with-selected-window win
            (goto-char marker)
            (org-back-to-heading t)
            (cond ((fboundp 'org-fold-show-entry) (org-fold-show-entry))
                  ((fboundp 'org-show-entry) (org-show-entry)))
            (recenter)
            (simply-kanban--flash-heading)))))))

(defun simply-kanban--maybe-save (buffer)
  "Save BUFFER if it visits a file and `simply-kanban-save-after-change' is set."
  (when (and simply-kanban-save-after-change
             (buffer-live-p buffer)
             (buffer-file-name buffer)
             (buffer-modified-p buffer))
    (with-current-buffer buffer
      (save-buffer))))

(defun simply-kanban--set-state (marker keyword)
  "Set the TODO state of the heading at MARKER to KEYWORD.
KEYWORD must be valid in the heading's own Org file."
  (with-current-buffer (marker-buffer marker)
    (org-with-wide-buffer
     (goto-char marker)
     (org-back-to-heading t)
     (org-todo keyword))
    (simply-kanban--maybe-save (current-buffer))))

(defun simply-kanban--goto-marker (marker)
  "Move point to the card whose source position matches MARKER."
  (let ((target (seq-find
                 (lambda (a)
                   (let ((m (cdr a)))
                     (and (marker-buffer m)
                          (eq (marker-buffer m) (marker-buffer marker))
                          (= (marker-position m) (marker-position marker)))))
                 (simply-kanban--anchors))))
    (when target
      (goto-char (car target))
      (simply-kanban--highlight-card))))

(defun simply-kanban--anchor-for-marker (marker)
  "Return the board card anchor (POS . MARKER) matching source MARKER, or nil.
Must be called with the board buffer current."
  (seq-find (lambda (a) (simply-kanban--same-card-p (cdr a) marker))
            (simply-kanban--anchors)))

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

(defun simply-kanban-set-status ()
  "Set the card at point to a stage chosen with `completing-read'.
Candidates are the keywords of the card's own Org file."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (buffer-live-p (marker-buffer marker))))
        (message "Point is not on a card")
      (let* ((kws (simply-kanban--source-keywords (marker-buffer marker)))
             (new (completing-read "Status: " kws nil t)))
        (when (and new (not (string-empty-p new)))
          (simply-kanban--set-state marker new)
          (simply-kanban-refresh)
          (simply-kanban--goto-marker marker)
          (message "%s" new))))))

(defun simply-kanban-set-tags ()
  "Set the Org tags on the card at point using Org's native tag prompt."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (buffer-live-p (marker-buffer marker))))
        (message "Point is not on a card")
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (org-back-to-heading t)
         (call-interactively #'org-set-tags-command)))
      (simply-kanban--maybe-save (marker-buffer marker))
      (simply-kanban-refresh)
      (simply-kanban--goto-marker marker))))

(defun simply-kanban-set-priority ()
  "Set the Org priority of the card at point using Org's native prompt."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (buffer-live-p (marker-buffer marker))))
        (message "Point is not on a card")
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (org-back-to-heading t)
         (call-interactively #'org-priority)))
      (simply-kanban--maybe-save (marker-buffer marker))
      (simply-kanban-refresh)
      (simply-kanban--goto-marker marker))))

(defun simply-kanban-set-effort ()
  "Set the Org effort estimate of the card at point using Org's native prompt."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (buffer-live-p (marker-buffer marker))))
        (message "Point is not on a card")
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (org-back-to-heading t)
         (call-interactively #'org-set-effort)))
      (simply-kanban--maybe-save (marker-buffer marker))
      (simply-kanban-refresh)
      (simply-kanban--goto-marker marker))))

(defun simply-kanban-set-tag-filter ()
  "Filter the board to show only cards with a given tag."
  (interactive)
  (let* ((buffers (simply-kanban--spec-buffers simply-kanban--source-spec))
         (tasks (simply-kanban--collect-all buffers))
         (all-tags (delete-dups
                    (apply #'append (mapcar (lambda (tk) (plist-get tk :tags)) tasks))))
         (selection (completing-read "Filter by tag: " all-tags nil t)))
    (setq simply-kanban--tag-filter (unless (string-empty-p selection) selection))
    (simply-kanban-refresh)
    (if simply-kanban--tag-filter
        (message "Tag filter: %s" simply-kanban--tag-filter)
      (message "Cleared tag filter"))))

(defun simply-kanban-clear-tag-filter ()
  "Clear the active tag filter."
  (interactive)
  (setq simply-kanban--tag-filter nil)
  (simply-kanban-refresh)
  (message "Cleared tag filter"))

(defun simply-kanban-set-sprint ()
  "Set the SPRINT property of the card at point to a chosen integer.
Empty input removes the property, taking the card out of every sprint."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (buffer-live-p (marker-buffer marker))))
        (message "Point is not on a card")
      (let ((input (string-trim (read-string "Sprint number (empty = remove): "))))
        (unless (or (string-empty-p input) (string-match-p "\\`[0-9]+\\'" input))
          (user-error "Sprint must be a whole number"))
        (with-current-buffer (marker-buffer marker)
          (org-with-wide-buffer
           (goto-char marker)
           (org-back-to-heading t)
           (if (string-empty-p input)
               (org-delete-property "SPRINT")
             (org-set-property "SPRINT" input))))
        (simply-kanban--maybe-save (marker-buffer marker))
        (simply-kanban-refresh)
        (simply-kanban--goto-marker marker)
        (message (if (string-empty-p input) "Sprint cleared" "Sprint %s") input)))))

(defun simply-kanban-set-sprint-filter ()
  "Display only cards in a chosen sprint (their SPRINT property).
Offers the sprint numbers present on the board for completion; empty input
clears the filter and shows every sprint."
  (interactive)
  (let* ((buffers (simply-kanban--spec-buffers simply-kanban--source-spec))
         (tasks (simply-kanban--collect-all buffers))
         (sprints (sort (delete-dups
                         (delq nil (mapcar (lambda (tk) (plist-get tk :sprint)) tasks)))
                        #'<))
         (input (string-trim
                 (completing-read "Show sprint (empty = all): "
                                  (mapcar #'number-to-string sprints) nil nil))))
    (cond
     ((string-empty-p input)
      (setq simply-kanban--sprint-filter nil))
     ((string-match-p "\\`[0-9]+\\'" input)
      (setq simply-kanban--sprint-filter (string-to-number input)))
     (t (user-error "Sprint must be a whole number")))
    (simply-kanban-refresh)
    (if simply-kanban--sprint-filter
        (message "Sprint filter: %d" simply-kanban--sprint-filter)
      (message "Cleared sprint filter"))))

(defun simply-kanban-clear-sprint-filter ()
  "Clear the active sprint filter, showing every sprint."
  (interactive)
  (setq simply-kanban--sprint-filter nil)
  (simply-kanban-refresh)
  (message "Cleared sprint filter"))

(defun simply-kanban-delete ()
  "Delete the Org heading for the card at point."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (marker-buffer marker)))
        (message "Point is not on a card")
      (when (y-or-n-p "Delete this heading? ")
        (let ((buf (marker-buffer marker)))
          (with-current-buffer buf
            (org-with-wide-buffer
             (goto-char marker)
             (org-back-to-heading t)
             (delete-region (point) (org-end-of-subtree t t))))
          (simply-kanban--maybe-save buf))
        (simply-kanban-refresh)
        (message "Deleted")))))

(defun simply-kanban-jump-other-window ()
  "Jump to the Org heading for the card at point in another window."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (marker-buffer marker)))
        (message "Point is not on a card")
      (let ((buf (marker-buffer marker))
            (pos marker))
        (display-buffer buf '(display-buffer-pop-up-window (inhibit-same-window . t)))
        (with-selected-window (get-buffer-window buf)
          (goto-char pos)
          (org-back-to-heading t)
          (cond ((fboundp 'org-fold-show-entry) (org-fold-show-entry))
                ((fboundp 'org-show-entry) (org-show-entry))))))))

(defun simply-kanban--heading-markers-upward ()
  "Return markers for the Org heading at point and its ancestors, innermost first.
Each marker sits at the start of a heading, so it can be matched against a
board card's source marker.  Empty when point precedes the first heading."
  (save-excursion
    (let (markers)
      (when (ignore-errors (org-back-to-heading t) t)
        (push (point-marker) markers)
        (while (ignore-errors (org-up-heading-safe))
          (push (point-marker) markers)))
      (nreverse markers))))

(defun simply-kanban--org-board-spec ()
  "Return a board spec for the current Org buffer that holds every card.
A flat file yields the whole-buffer board; a multi-board file yields the
all-boards aggregate, so the heading at point is present whichever board it
belongs to.  Must be called with the Org buffer current."
  (if (simply-kanban--file-boards (current-buffer))
      (cons 'all-boards (current-buffer))
    (cons 'buffer (current-buffer))))

;;;###autoload
(defun simply-kanban-show-card ()
  "Select, on the kanban board, the card for the Org heading at point.
The inverse of \\[simply-kanban-goto]: run it from an Org buffer to locate the
heading at -- or enclosing -- point among the board's cards and select that
card.  The board is shown in another window but focus stays in the Org buffer.
The matched card is filled with `simply-kanban-mark' to flag it; that fill is
cleared the moment you navigate to another card on the board.
When the heading itself is not a card (e.g. point is on a non-TODO parent), the
nearest enclosing card is used.

When no board is open a board for this file is created first -- in a split to
the right, keeping the Org file visible on the left -- so the command always
tries to take you to a card.  The card must be currently visible (not hidden by
an active tag or sprint filter)."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (let ((candidates (simply-kanban--heading-markers-upward))
        (orig-win (selected-window)))
    (unless candidates
      (user-error "No Org heading at point"))
    (let ((board (get-buffer simply-kanban-buffer-name)))
      ;; Create a board for this file if none is open yet, in a split to the
      ;; right so the original Org file stays visible on the left.
      (unless (buffer-live-p board)
        (let ((display-buffer-overriding-action
               '((display-buffer-in-direction)
                 (direction . right)
                 (window-width . 0.5))))
          (simply-kanban--open (simply-kanban--org-board-spec)))
        (setq board (get-buffer simply-kanban-buffer-name)))
      (let ((match (and (buffer-live-p board)
                        (with-current-buffer board
                          (seq-some #'simply-kanban--anchor-for-marker candidates)))))
        (if (not match)
            (message "No matching card on the board for this heading")
          ;; Reuse the board's own window when it already has one (e.g. the
          ;; right split we just created); otherwise show it without stealing
          ;; the Org file's window.
          (let ((win (or (get-buffer-window board)
                         (display-buffer board '(nil (inhibit-same-window . t))))))
            (when (window-live-p win)
              ;; Select and fill the card in the board window.
              (with-selected-window win
                (goto-char (car match))
                (simply-kanban--highlight-card)
                (simply-kanban--mark-card)))))
        ;; Keep focus in the Org buffer, even when we had to create the board.
        (when (window-live-p orig-win)
          (select-window orig-win))))))

(defun simply-kanban-refresh ()
  "Rebuild the board, re-resolving its source spec.
The card at point is kept selected across the rebuild."
  (interactive)
  (unless (derived-mode-p 'simply-kanban-mode)
    (user-error "Not in a kanban board"))
  (let ((spec simply-kanban--source-spec)
        (card (simply-kanban--marker-at-point))
        (win (get-buffer-window (current-buffer))))
    (unless spec
      (user-error "This board has no source"))
    (if win
        (with-selected-window win
          (simply-kanban--render spec)
          (when card (simply-kanban--goto-marker card)))
      (simply-kanban--render spec)
      (when card (simply-kanban--goto-marker card)))))

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

;;; Follow mode and card highlighting

(defun simply-kanban--follow-card ()
  "When follow mode is on, show the heading of the card at point."
  (when simply-kanban--follow
    (let ((marker (simply-kanban--marker-at-point)))
      (when (and marker (buffer-live-p (marker-buffer marker)))
        (save-selected-window
          (let ((win (display-buffer (marker-buffer marker))))
            (when (window-live-p win)
              (with-selected-window win
                (goto-char marker)
                (org-back-to-heading t)
                (cond ((fboundp 'org-fold-show-entry) (org-fold-show-entry))
                      ((fboundp 'org-show-entry) (org-show-entry)))
                (recenter)
                (simply-kanban--flash-heading)))))))))

(defun simply-kanban-toggle-follow ()
  "Toggle follow mode for the board.
When enabled, navigating between cards also reveals the heading in its file."
  (interactive)
  (setq simply-kanban--follow (not simply-kanban--follow))
  (force-mode-line-update)
  (message "Follow mode %s" (if simply-kanban--follow "enabled" "disabled"))
  (when simply-kanban--follow (simply-kanban--follow-card)))

(defun simply-kanban-toggle-expand ()
  "Toggle showing the Org body of the card at point."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (unless marker
      (user-error "Point is not on a card"))
    (if (simply-kanban--card-expanded-p marker)
        (setq simply-kanban--expanded-cards
              (cl-remove-if (lambda (m) (simply-kanban--same-card-p m marker))
                            simply-kanban--expanded-cards))
      (push (copy-marker marker) simply-kanban--expanded-cards))
    (simply-kanban-refresh)))

(defun simply-kanban-toggle-expand-all ()
  "Expand the body of every card, or collapse them all if any are expanded."
  (interactive)
  (unless (derived-mode-p 'simply-kanban-mode)
    (user-error "Not in a kanban board"))
  (setq simply-kanban--expanded-cards
        (unless simply-kanban--expanded-cards
          (delq nil (mapcar (lambda (tk) (plist-get tk :marker))
                            (simply-kanban--collect-all
                             (simply-kanban--spec-buffers
                              simply-kanban--source-spec))))))
  (simply-kanban-refresh))

(defun simply-kanban--card-regions (card)
  "Return a list of (BEG . END) cons cells covering CARD on the board.
A card occupies a rectangular area, so it spans several disjoint regions that
share the same `simply-kanban-marker' text property."
  (let (regions)
    (when card
      (save-excursion
        (goto-char (point-min))
        (while (< (point) (point-max))
          (let ((end (or (next-single-property-change (point) 'simply-kanban-marker)
                         (point-max))))
            (when (eq (get-text-property (point) 'simply-kanban-marker) card)
              (push (cons (point) end) regions))
            (goto-char end)))))
    (nreverse regions)))

(defun simply-kanban--highlight-card ()
  "Bold every region of the card at point, clearing any previous highlight."
  (when (derived-mode-p 'simply-kanban-mode)
    (let ((card (get-text-property (point) 'simply-kanban-marker)))
      (unless (eq card simply-kanban--current-card)
        (setq simply-kanban--current-card card)
        (mapc #'delete-overlay simply-kanban--highlight-overlays)
        (setq simply-kanban--highlight-overlays nil)
        (dolist (region (simply-kanban--card-regions card))
          (let ((ov (make-overlay (car region) (cdr region))))
            ;; Using a face list merges over any pre-existing text faces
            ;; without clearing their colors.
            (overlay-put ov 'face '(:weight bold :inherit simply-kanban-current-card))
            (overlay-put ov 'priority 100)
            (push ov simply-kanban--highlight-overlays)))))))

(defun simply-kanban--clear-mark ()
  "Remove the temporary card-fill overlays left by `simply-kanban-show-card'."
  (mapc #'delete-overlay simply-kanban--mark-overlays)
  (setq simply-kanban--mark-overlays nil
        simply-kanban--mark-marker nil))

(defun simply-kanban--mark-card ()
  "Fill every region of the card at point with `simply-kanban-mark'.
Flags the card matching the Org heading for `simply-kanban-show-card';
`simply-kanban--clear-mark-on-move' removes the fill once point leaves it.
The fill sits above the focus highlight, so it shows even on the current card."
  (simply-kanban--clear-mark)
  (let ((card (get-text-property (point) 'simply-kanban-marker)))
    (when card
      (setq simply-kanban--mark-marker card)
      (dolist (region (simply-kanban--card-regions card))
        (let ((ov (make-overlay (car region) (cdr region))))
          (overlay-put ov 'face 'simply-kanban-mark)
          (overlay-put ov 'priority 101)
          (push ov simply-kanban--mark-overlays))))))

(defun simply-kanban--clear-mark-on-move ()
  "Clear the temporary card fill once point leaves the flagged card.
Installed on `post-command-hook' so the cue set by `simply-kanban-show-card'
persists only until you navigate to another card."
  (when (and simply-kanban--mark-overlays
             (not (simply-kanban--same-card-p (simply-kanban--marker-at-point)
                                              simply-kanban--mark-marker)))
    (simply-kanban--clear-mark)))

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
    (define-key map (kbd "v") #'simply-kanban-jump-other-window)
    (define-key map (kbd "}") #'simply-kanban-advance)
    (define-key map (kbd "{") #'simply-kanban-retreat)
    (define-key map (kbd "s") #'simply-kanban-set-status)
    (define-key map (kbd "k") #'simply-kanban-delete)
    (define-key map (kbd "t") #'simply-kanban-set-tag-filter)
    (define-key map (kbd "T") #'simply-kanban-clear-tag-filter)
    (define-key map (kbd "S") #'simply-kanban-set-sprint-filter)
    (define-key map (kbd ":") #'simply-kanban-set-tags)
    (define-key map (kbd ",") #'simply-kanban-set-priority)
    (define-key map (kbd ";") #'simply-kanban-set-effort)
    (define-key map (kbd "#") #'simply-kanban-set-sprint)
    (define-key map (kbd "F") #'simply-kanban-toggle-follow)
    (define-key map (kbd "e") #'simply-kanban-toggle-expand)
    (define-key map (kbd "E") #'simply-kanban-toggle-expand-all)
    (define-key map (kbd "B") #'simply-kanban-switch-board)
    (define-key map (kbd "g") #'simply-kanban-refresh)
    (define-key map (kbd "SPC") #'simply-kanban-transient)
    (define-key map (kbd "?") #'simply-kanban-transient)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `simply-kanban-mode'.")

(defun simply-kanban--header-source ()
  "Return a description of the board's source for the header-line.
Uses the plain header-line foreground so it reads well on any theme."
  (pcase simply-kanban--source-spec
    (`(buffer . ,buf)
     (if (buffer-live-p buf) (buffer-name buf) "?"))
    (`(board ,buf ,marker)
     (format "%s ▸ %s"
             (if (buffer-live-p buf) (buffer-name buf) "?")
             (or (simply-kanban--board-name marker) "?")))
    (`(toplevel . ,buf)
     (format "%s ▸ %s"
             (if (buffer-live-p buf) (buffer-name buf) "?")
             simply-kanban-toplevel-name))
    (`(all-boards . ,buf)
     (format "%s ▸ %s"
             (if (buffer-live-p buf) (buffer-name buf) "?")
             simply-kanban-all-boards-name))
    (`(files . ,files)
     (format "agenda (%d)" (length files)))
    (_ "—")))

(define-derived-mode simply-kanban-mode special-mode "Kanban"
  "Major mode for the Org-linked kanban board.

\\{simply-kanban-mode-map}"
  (setq-local truncate-lines t)
  (setq-local cursor-type 'box)
  (setq header-line-format
        '(" Kanban  "
          (:eval (simply-kanban--header-source))
          (:eval (if simply-kanban--tag-filter
                     (propertize (format " [tag: %s]" simply-kanban--tag-filter) 'face 'success)
                   ""))
          (:eval (if simply-kanban--sprint-filter
                     (propertize (format " [sprint: %d]" simply-kanban--sprint-filter)
                                 'face 'warning)
                   ""))
          "   "
          (:eval (propertize "F" 'face 'help-key-binding)) " follow"
          (:eval (if simply-kanban--follow "[ON]" ""))
          "  "
          (:eval (propertize "RET" 'face 'help-key-binding)) " goto  "
          (:eval (propertize "{}" 'face 'help-key-binding)) " move  "
          (:eval (propertize "s" 'face 'help-key-binding)) " status  "
          (:eval (propertize "e/E" 'face 'help-key-binding)) " expand  "
          (:eval (propertize ":" 'face 'help-key-binding)) " tags  "
          (:eval (propertize ";" 'face 'help-key-binding)) " effort  "
          (:eval (propertize "#" 'face 'help-key-binding)) " sprint  "
          (:eval (propertize "t" 'face 'help-key-binding)) " tag  "
          (:eval (propertize "S" 'face 'help-key-binding)) " sprint-filter  "
          (:eval (propertize "q" 'face 'help-key-binding)) " quit"))
  (add-hook 'post-command-hook #'simply-kanban--highlight-card nil t)
  (add-hook 'post-command-hook #'simply-kanban--clear-mark-on-move nil t))

;;; Transient menu

(defun simply-kanban--transient-description ()
  "Header string for the `simply-kanban' transient menu."
  (format "Simply Kanban   source: %s%s%s"
          (simply-kanban--header-source)
          (if simply-kanban--tag-filter
              (format "   tag: %s" simply-kanban--tag-filter)
            "")
          (if simply-kanban--sprint-filter
              (format "   sprint: %d" simply-kanban--sprint-filter)
            "")))

;;;###autoload (autoload 'simply-kanban-transient "simply-kanban" nil t)
(transient-define-prefix simply-kanban-transient ()
  "Transient menu for `simply-kanban'."
  [:description simply-kanban--transient-description
   ["Navigate"
    ("n" "next card"       simply-kanban-next-card :transient t)
    ("p" "previous card"   simply-kanban-prev-card :transient t)
    ("f" "next column"     simply-kanban-next-column :transient t)
    ("b" "previous column" simply-kanban-prev-column :transient t)]
   ["Move / Edit"
    ("}" "advance stage"   simply-kanban-advance :transient t)
    ("{" "retreat stage"   simply-kanban-retreat :transient t)
    ("s" "set status"      simply-kanban-set-status)
    ("," "set priority"    simply-kanban-set-priority)
    (":" "set tags"        simply-kanban-set-tags)
    (";" "set effort"      simply-kanban-set-effort)
    ("#" "set sprint"      simply-kanban-set-sprint)
    ("k" "delete card"     simply-kanban-delete)]
   ["Reveal"
    ("RET" "reveal heading" simply-kanban-goto)
    ("v" "other window"     simply-kanban-jump-other-window)
    ("e" "expand card"      simply-kanban-toggle-expand :transient t)
    ("E" "expand all"       simply-kanban-toggle-expand-all :transient t)
    ("F" "follow mode"      simply-kanban-toggle-follow :transient t)]]
  [["Board"
    ("t" "filter by tag"    simply-kanban-set-tag-filter)
    ("T" "clear tag filter" simply-kanban-clear-tag-filter :transient t)
    ("S" "filter by sprint" simply-kanban-set-sprint-filter)
    ("C" "clear sprint"     simply-kanban-clear-sprint-filter :transient t)
    ("B" "switch board"     simply-kanban-switch-board)
    ("g" "refresh"          simply-kanban-refresh :transient t)
    ("q" "quit board"       quit-window)]])

(defun simply-kanban--open (spec)
  "Build and display a kanban board for SPEC.
The buffer is displayed before rendering so columns size to the window."
  (let ((buffer (get-buffer-create simply-kanban-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'simply-kanban-mode)
        (simply-kanban-mode))
      (setq simply-kanban--sprint-filter simply-kanban-default-sprint))
    (pop-to-buffer buffer)
    (simply-kanban--render spec)))

;;;###autoload
(defun simply-kanban ()
  "Open a kanban board for the current Org buffer.
Columns are the buffer's Org TODO keywords; cards are the headings
carrying those keywords.

If the buffer defines several boards -- level-1 headings whose subtrees
hold the TODO cards (see `simply-kanban--scan-boards') -- you are prompted
for which one to open, and \\[simply-kanban-switch-board] switches between
them."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (let ((boards (simply-kanban--file-boards-with-all (current-buffer))))
    (if boards
        (let ((choice (if (cdr boards)
                          (simply-kanban--read-spec boards)
                        (car boards))))
          (when choice
            (simply-kanban--open (cdr choice))))
      (simply-kanban--open (cons 'buffer (current-buffer))))))

(defun simply-kanban-switch-board ()
  "Switch to another board defined in the same Org file.
Only available when the current board came from a multi-board file."
  (interactive)
  (let ((buf (pcase simply-kanban--source-spec
               (`(board ,b ,_) b)
               (`(toplevel . ,b) b)
               (`(all-boards . ,b) b))))
    (unless buf
      (user-error "Not a multi-board kanban"))
    (unless (buffer-live-p buf)
      (user-error "Source Org buffer is gone"))
    (let ((boards (simply-kanban--file-boards-with-all buf)))
      (unless boards
        (user-error "No boards found in %s" (buffer-name buf)))
      (let ((choice (simply-kanban--read-spec boards)))
        (when choice
          (setq simply-kanban--source-spec (cdr choice)
                simply-kanban--tag-filter nil
                simply-kanban--expanded-cards nil)
          (simply-kanban-refresh)
          (message "Board: %s" (car choice)))))))

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

;;; Org-mode binding

(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c ;") #'simply-kanban-show-card))

(provide 'simply-kanban)
;;; simply-kanban.el ends here
