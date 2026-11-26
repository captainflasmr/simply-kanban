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
;; to open, and `B' switches between them.  Each board lives in its own buffer
;; named after its source (and board name), so several boards can stay open at
;; once.  Any loose level-1 TODO headings
;; at the top of such a file are still offered as a flat board named by
;; `simply-kanban-toplevel-name'.
;;
;; Usage: open an Org file and M-x simply-kanban.
;;
;; From inside the Org file, M-x `simply-kanban-show-card' is the inverse of
;; the board's RET: it finds the heading at point among the board's cards
;; and selects it, showing the board in another window while focus stays in the
;; Org buffer.  With a prefix argument, or M-x `simply-kanban-jump-to-card',
;; focus moves to the card on the board instead.  When no open board contains
;; the heading it creates one first, so it always tries to take you to a card.
;;
;;   n / p          next / previous card
;;   TAB / S-TAB    next / previous column   (also f / b)
;;   }              advance card to the next stage
;;   {              send card back a stage
;;   s              set status (choose any stage)
;;   RET            reveal the heading (focus stays on the board)
;;   C-u RET        jump to the heading in its Org file
;;   k              delete the heading (with confirmation)
;;   t              filter board by tag
;;   T              clear tag filter
;;   S              filter board by sprint (SPRINT property)
;;   C              clear sprint filter
;;   :              set the Org tags on the card at point
;;   ,              set the Org priority of the card at point
;;   ;              set the Org effort estimate on the card at point
;;   P              set the story points on the card at point
;;   #              set the sprint (SPRINT property) on the card at point
;;   i / o          clock in the card at point / clock out
;;   e              toggle the body of the card at point
;;   E              toggle the body of every card
;;   N              add a timestamped note to the card at point
;;   L              toggle the card's LOGBOOK drawer
;;   c              toggle compact (single-line metadata) cards
;;   l              set the max card-title length (empty = no limit)
;;   F              toggle follow mode
;;   B              switch board (multi-board files only)
;;   g              refresh
;;   SPC / ?        open the transient menu
;;   q              quit

;;; Code:

(require 'org)
(require 'org-clock)
(require 'org-duration)
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

(defcustom simply-kanban-max-title-length nil
  "Maximum number of characters of a card title shown on the board, or nil.
When an integer, titles longer than this are truncated with an ellipsis so the
board stays compact; the full title is restored when the card is expanded with
\\[simply-kanban-toggle-expand] (alongside its body text).  Adjust it live for
the current board with \\[simply-kanban-set-title-length] when it feels too
verbose."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'simply-kanban)

(defcustom simply-kanban-compact-cards t
  "When non-nil, condense each card's metadata onto a single line.
The line lists the board and source-file markers when present, then effort,
remaining (or over-budget) time, sprint value, and tags, omitting values the
card does not have.  Story points and clocked time are omitted from this
line and appear in the detailed layout instead.  Numeric values carry no
labels; their order and face identify them.  Durations use colon-separated
units (for example 1d:1h:23m), the sprint value appears without a label, and
the line is truncated with an ellipsis when it does not fit.  The title and
progress bar keep their own lines.  Toggle the current board with
\\[simply-kanban-toggle-compact]."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-buffer-name "*Simply Kanban*"
  "Base name of kanban board buffers.
Each board lives in its own buffer named from this base and the board's
source, e.g. \"*Simply Kanban: tasks.org*\" or
\"*Simply Kanban: tasks.org ▸ Project Alpha*\", so several boards can stay
open at once."
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

(defcustom simply-kanban-show-story-points t
  "When non-nil, show each card's story points and a per-column total.
Story points are read from the card heading's `STORY_POINTS' property; cards
without one show nothing.  The detailed card layout shows them as a
`Points: N' badge, while compact cards omit the value; the column header
always appends the summed story points of its cards."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-clock t
  "When non-nil, show each card's clocked time from its Org clock entries.
The detailed card layout shows a `Clocked: H:MM' badge when the card has
clocked time or a running clock.  The active clock is included while it runs,
and is marked as `(run)'.  Compact cards omit the clocked value but still show
remaining or over-budget time.  Set this to nil to omit clock data entirely."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-clock-total nil
  "When non-nil, append each column's summed clocked time to its header.
The total is shown in braces after the effort total, and requires
`simply-kanban-show-clock' to be non-nil."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-remaining t
  "When non-nil, show the estimated time remaining on started cards.
Remaining is the card's Effort minus its clocked time, floored at zero.
Cards with no Effort or no clocked time show no remaining badge.  Requires
`simply-kanban-show-clock' to be non-nil."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-remaining-total nil
  "When non-nil, append each column's summed remaining time to its header.
The total is shown in angle brackets after the effort and clock totals, and
requires `simply-kanban-show-clock' and `simply-kanban-show-remaining'."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-over-total nil
  "When non-nil, append each column's summed over-budget time to its header.
The total is shown after an exclamation mark, and requires
`simply-kanban-show-clock' and `simply-kanban-show-remaining'."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-column-progress t
  "When non-nil, replace each column divider with a progress bar.
The filled portion is the completed share of the column's estimated effort:
DONE cards count fully, while in-progress cards count their clocked time
capped at their estimate.  If no effort estimates are set, the done-card
count is used instead.  The empty portion uses the `shadow' face."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-card-progress t
  "When non-nil, show a progress bar on each card.
The bar uses the same filled and empty blocks as the column progress
indicators.  A DONE card is fully filled; any other card is filled by its
clocked time against its effort estimate, capped at fully complete.  Cards
without an effort estimate, or without clocked time, show no bar unless they
are DONE.  The filled portion uses the card's TODO-keyword face and the empty
portion uses the `shadow' face."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-ticket-types t
  "When non-nil, show ticket types and hierarchy on each card.
A TODO heading with TODO descendants is a STORY; leaf TODO headings are
TASKs.  A childless heading with a `TICKET_TYPE' property of `STORY' is also
a STORY.  Cards show their type, their parent when they have one, and a
story's child count.  Set this to nil to omit the extra relationship line."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-stories nil
  "When non-nil, show STORY cards on kanban boards.
A STORY is a TODO heading with TODO descendants, or a childless heading with
a `TICKET_TYPE' property of `STORY'.  When nil, only TASK cards are shown,
but task cards still name their parent story.  Toggle the current board with
\\[simply-kanban-toggle-stories]."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-jira-number-regexp
  "\\`\\([A-Z][A-Z0-9]*-[0-9]+\\)\\b"
  "Regexp matching a Jira issue number at the start of a card title.
Group 1 is the issue key, for example MM-1472.  The default accepts an
uppercase project prefix followed by a hyphen and digits."
  :type 'regexp
  :group 'simply-kanban)

(defcustom simply-kanban-default-sprint nil
  "Sprint a board filters to when first opened, or nil for all sprints.
A card's sprint is its `SPRINT' property, a string inherited from parent
headings; set it from the board with \\[simply-kanban-set-sprint].  When this
is non-nil, opening a board shows only cards in that sprint; change the
displayed sprint at any time with \\[simply-kanban-set-sprint-filter] (empty
input clears the filter).  When nil, boards open showing every sprint."
  :type '(choice (const :tag "All sprints" nil) string)
  :group 'simply-kanban)

(defcustom simply-kanban-sprint-from-heading nil
  "When non-nil, derive a card's sprint from its nearest ancestor heading.
The heading must not carry a TODO keyword, and its text becomes the sprint
when the card has no `SPRINT' property.  This lets a file define sprints by
section without adding properties to every card, for example:

* Sprint 1
** TODO Write the parser
* Sprint 2
** TODO Write the tests

The nearest ancestor wins: a `SPRINT' property on a heading takes precedence
over that heading's text, and a `SPRINT' property on the card itself always
takes precedence."
  :type 'boolean
  :group 'simply-kanban)

(defcustom simply-kanban-show-sprint t
  "When non-nil, show a card's sprint on the board.
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

(defface simply-kanban-story
  '((t :inherit font-lock-type-face :weight bold))
  "Face for STORY ticket labels and double-line outlines."
  :group 'simply-kanban)

(defface simply-kanban-task
  '((t :inherit shadow))
  "Face for the TASK ticket-type label shown on a card."
  :group 'simply-kanban)

(defface simply-kanban-jira
  '((t :weight bold))
  "Face for the Jira issue number shown on a card."
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

(defface simply-kanban-points
  '((t :inherit org-special-keyword))
  "Face for the story-points badge shown on a card and column total."
  :group 'simply-kanban)

(defface simply-kanban-clock
  '((t :inherit org-special-keyword))
  "Face for the clocked-time badge shown on a card."
  :group 'simply-kanban)

(defface simply-kanban-remaining
  '((t :inherit org-special-keyword))
  "Face for the remaining-time badge shown on a card."
  :group 'simply-kanban)

(defface simply-kanban-over
  '((t :inherit warning))
  "Face for the over-budget badge shown on a card."
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

(defvar-local simply-kanban--running-card nil
  "The marker identifying the card with the running clock.")

(defvar-local simply-kanban--running-clock-state nil
  "Last observed active clock, as (BUFFER . POSITION), or nil.")

(defvar-local simply-kanban--running-overlays nil
  "Overlays drawing the running card's block outline.")

(defvar-local simply-kanban--tag-filter nil
  "When non-nil, only show cards carrying this tag.")

(defvar-local simply-kanban--sprint-filter nil
  "When non-nil (a string), only show cards in that sprint.
A card's sprint is its `SPRINT' property, or an ancestor heading when
`simply-kanban-sprint-from-heading' is non-nil.  Initialised from
`simply-kanban-default-sprint' when a board is opened.")

(defvar-local simply-kanban--expanded-cards nil
  "Markers of cards whose Org body and story children are shown on the board.")

(defvar-local simply-kanban--logbook-cards nil
  "Markers of cards whose LOGBOOK drawer is currently shown on the board.")

(defvar-local simply-kanban--title-length nil
  "Maximum characters of a card title shown on this board, or nil for no limit.
Initialised from `simply-kanban-max-title-length' when the board opens; change
it live with \\[simply-kanban-set-title-length].")

(defvar-local simply-kanban--compact-cards t
  "When non-nil, this board shows each card's metadata on a single line.
Initialised from `simply-kanban-compact-cards' when the board opens; toggle
it live with \\[simply-kanban-toggle-compact].")

(defvar-local simply-kanban--show-stories nil
  "When non-nil, this board shows STORY cards.
Initialised from `simply-kanban-show-stories' when the board opens; toggle
it live with \\[simply-kanban-toggle-stories].")

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

(defun simply-kanban--strip-logbook (text)
  "Remove LOGBOOK drawers and CLOCK lines from TEXT."
  (let ((in-logbook nil)
        result)
    (dolist (line (split-string text "\n"))
      (cond
       ((string-match-p "^[ \t]*:LOGBOOK:[ \t]*$" line)
        (setq in-logbook t))
       ((and in-logbook (string-match-p "^[ \t]*:END:[ \t]*$" line))
        (setq in-logbook nil))
       (in-logbook nil)
       ((string-match-p "^[ \t]*CLOCK:" line) nil)
       (t (push line result))))
    (string-trim (mapconcat #'identity (nreverse result) "\n"))))

(defun simply-kanban--entry-body ()
  "Return the body text of the Org entry at point, or nil when empty.
Excludes the heading, its planning line, any property/logbook drawer, and
clock lines; text belonging to child headings is not included."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point))))
      (org-end-of-meta-data t)
      ;; For an empty entry `org-end-of-meta-data' can land on the next
      ;; heading; clamp so its text is never swept into the body.
      (let ((beg (min (point) end)))
        (when (< beg end)
          (let ((body (simply-kanban--strip-logbook
                       (buffer-substring-no-properties beg end))))
            (unless (string-empty-p body) body)))))))

(defun simply-kanban--entry-logbook ()
  "Return the LOGBOOK drawer text of the Org entry at point, or nil."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point))))
      (when (re-search-forward "^[ \t]*:LOGBOOK:[ \t]*$" end t)
        (let ((drawer-start (line-beginning-position)))
          (when (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
            (let ((contents-start (save-excursion
                                    (goto-char drawer-start)
                                    (forward-line 1)
                                    (point)))
                  (contents-end (line-beginning-position)))
              (when (< contents-start contents-end)
                (string-trim
                 (buffer-substring-no-properties
                  contents-start contents-end))))))))))

(defun simply-kanban--local-sprint ()
  "Return the SPRINT property set directly on the entry at point, or nil."
  (let ((prop (org-entry-get nil "SPRINT")))
    (when (and prop (not (string-empty-p (string-trim prop))))
      (string-trim prop))))

(defun simply-kanban--sprint-from-ancestors ()
  "Return the nearest ancestor's sprint property or heading text, or nil.
Walks upward, preferring a SPRINT property set directly on each ancestor
over that ancestor's heading text.  Only headings without a TODO keyword
can supply their text."
  (save-excursion
    (let (sprint)
      (while (and (not sprint)
                  (ignore-errors (org-up-heading-safe)))
        (setq sprint
              (or (simply-kanban--local-sprint)
                  (let ((title (string-trim
                                (substring-no-properties
                                 (or (org-get-heading t t t t) "")))))
                    (and (not (org-get-todo-state))
                         (not (string-empty-p title))
                         title)))))
      sprint)))

(defun simply-kanban--read-sprint ()
  "Return the sprint of the Org entry at point as a string, or nil.
A SPRINT property set on the entry itself wins.  Otherwise the property is
read with inheritance, so a SPRINT set on a parent (e.g. a board container)
applies to its cards.  When `simply-kanban-sprint-from-heading' is non-nil,
the nearest ancestor heading without a TODO keyword supplies the sprint
instead, unless that ancestor carries a SPRINT property of its own."
  (or (simply-kanban--local-sprint)
      (and simply-kanban-sprint-from-heading
           (simply-kanban--sprint-from-ancestors))
      (let ((prop (org-entry-get nil "SPRINT" t)))
        (when (and prop (not (string-empty-p (string-trim prop))))
          (string-trim prop)))))

(defun simply-kanban--story-points ()
  "Return the STORY_POINTS property of the entry at point as a number, or nil."
  (let ((s (org-entry-get nil "STORY_POINTS")))
    (when (and s (string-match-p
                  "\\`[ \t]*[0-9]+\\(?:\\.[0-9]+\\)?[ \t]*\\'" s))
      (string-to-number s))))

(defun simply-kanban--active-clock-heading-position ()
  "Return the position of the heading with the running clock, or nil."
  (when (and (org-clock-is-active)
             (markerp org-clock-marker)
             (marker-buffer org-clock-marker))
    (with-current-buffer (marker-buffer org-clock-marker)
      (save-excursion
        (goto-char org-clock-marker)
        (ignore-errors (org-back-to-heading t))
        (when (org-at-heading-p) (point))))))

(defun simply-kanban--clock-state ()
  "Return the active clock's source buffer and heading position, or nil."
  (let ((pos (simply-kanban--active-clock-heading-position)))
    (when pos
      (cons (marker-buffer org-clock-marker) pos))))

(defun simply-kanban--clocking-p ()
  "Return non-nil when the heading at point has the running clock."
  (let ((pos (simply-kanban--active-clock-heading-position)))
    (and pos
         (eq (marker-buffer org-clock-marker) (current-buffer))
         (= pos (point)))))

(defun simply-kanban--card-clocking-p (marker)
  "Return non-nil when the card at MARKER has the running clock."
  (let ((pos (simply-kanban--active-clock-heading-position)))
    (and pos
         marker
         (marker-buffer marker)
         (eq (marker-buffer org-clock-marker) (marker-buffer marker))
         (= pos (marker-position marker)))))

(defun simply-kanban--clocked-minutes ()
  "Return clocked minutes for the heading at point.
The value includes the currently running clock interval, if any."
  (if (simply-kanban--clocking-p)
      (round (org-clock-get-clocked-time))
    (or (get-text-property (point) :org-clock-minutes) 0)))

(defun simply-kanban--collect-tasks (buffer &optional restrict)
  "Collect TODO entries from Org BUFFER as a list of card plists.
Each plist has :keyword :title :jira :body :logbook :priority :tags :effort
:points :clocked :clocking :remaining :over :done :type :parent
:parent-jira :children :children-done :child-tasks :sprint :file :board
:marker.  :points is the heading's `STORY_POINTS' as a number.  :jira is the
issue key parsed from the start of the title.  :clocked is the heading's
clocked minutes (including a running clock), and :clocking is non-nil for the
active clock when clock display is enabled.  :type is `story' or `task',
:parent is the title of the nearest ancestor ticket heading, and :parent-jira
is its parsed issue key.  :children and :children-done count the TODO
descendants of a story, and :child-tasks lists them as plists with :keyword,
:jira, :title, and :done.  :remaining is the estimate left after clocked
time, :over is the clocked time beyond the estimate, and :done is non-nil for
a done keyword.  :sprint is the heading's sprint as a string (nil when
unset), from the inherited `SPRINT' property or, when
`simply-kanban-sprint-from-heading' is non-nil, the nearest ancestor
heading.  :board is filled in only by `simply-kanban--collect-boards'.
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
       (when simply-kanban-show-clock (save-excursion (org-clock-sum)))
       (let ((collect
              (lambda ()
                (let ((kw (org-get-todo-state)))
                  (when (and kw
                             (or (not (eq restrict 'toplevel))
                                 (= (org-current-level) 1)))
                    (let* ((comps (org-heading-components))
                           (title (substring-no-properties
                                   (or (org-get-heading t t t t) "")))
                           (jira (simply-kanban--jira-number title))
                           (effort (org-entry-get nil "Effort"))
                           (points (and simply-kanban-show-story-points
                                        (simply-kanban--story-points)))
                           (clocked (and simply-kanban-show-clock
                                         (simply-kanban--clocked-minutes)))
                           (running (simply-kanban--clocking-p))
                           (done (and kw (member kw org-done-keywords) t))
                           (remaining (and simply-kanban-show-clock
                                           simply-kanban-show-remaining
                                           (simply-kanban--remaining-minutes
                                            effort clocked done)))
                           (over (and simply-kanban-show-clock
                                      simply-kanban-show-remaining
                                      (simply-kanban--over-minutes
                                       effort clocked)))
                           (child-tasks (simply-kanban--subtree-todo-tasks))
                           (children (length child-tasks))
                           (children-done
                            (seq-count (lambda (ct) (plist-get ct :done))
                                       child-tasks))
                           (parent (simply-kanban--ancestor-ticket-title))
                           (parent-jira (simply-kanban--jira-number parent))
                           (type (simply-kanban--ticket-type children)))
                      (push (list :keyword kw
                                  :title title
                                  :jira jira
                                  :body (simply-kanban--entry-body)
                                  :logbook (simply-kanban--entry-logbook)
                                  :priority (nth 3 comps)
                                  :tags (org-get-tags nil t)
                                  :effort effort
                                  :points points
                                  :clocked clocked
                                  :clocking (and simply-kanban-show-clock running)
                                  :remaining remaining
                                  :over over
                                  :done done
                                  :type type
                                  :parent parent
                                  :parent-jira parent-jira
                                  :children children
                                  :children-done children-done
                                  :child-tasks child-tasks
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

(defun simply-kanban--subtree-todo-tasks ()
  "Return TODO entries below the heading at point.
Each entry is a plist with :keyword, :jira, :title, and :done."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t)))
          tasks)
      (forward-line 1)
      (while (re-search-forward org-heading-regexp end t)
        (save-excursion
          (goto-char (match-beginning 0))
          (let ((kw (org-get-todo-state)))
            (when kw
              (let ((title (substring-no-properties
                            (or (org-get-heading t t t t) ""))))
                (push (list :keyword kw
                            :jira (simply-kanban--jira-number title)
                            :title title
                            :done (and (member kw org-done-keywords) t))
                      tasks))))))
      (nreverse tasks))))

(defun simply-kanban--ancestor-ticket-title ()
  "Return the title of the nearest ancestor ticket heading, or nil.
A ticket heading is a TODO heading or a heading whose `TICKET_TYPE'
property is `STORY'."
  (save-excursion
    (catch 'found
      (while (org-up-heading-safe)
        (let ((type (org-entry-get nil "TICKET_TYPE")))
          (when (or (org-get-todo-state)
                    (and type (string= "story" (downcase type))))
            (throw 'found
                   (substring-no-properties (or (org-get-heading t t t t) ""))))))
      nil)))

(defun simply-kanban--ticket-type (children)
  "Return `story' or `task' for the heading at point.
A heading with CHILDREN TODO entries is a STORY.  A childless heading with a
`TICKET_TYPE' property of `STORY' is also a STORY; everything else is a TASK."
  (let ((prop (org-entry-get nil "TICKET_TYPE")))
    (if (or (> (or children 0) 0)
            (and prop (string= "story" (downcase prop))))
        'story
      'task)))

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

(defun simply-kanban--card-logbook-p (marker)
  "Non-nil when the card identified by MARKER should show its LOGBOOK."
  (and marker
       (seq-some (lambda (m) (simply-kanban--same-card-p m marker))
                 simply-kanban--logbook-cards)))

(defun simply-kanban--effort-minutes (effort)
  "Return EFFORT (an Org effort string such as \"1:30\") in minutes, or nil.
Returns nil when EFFORT is empty or cannot be parsed."
  (when (and effort (not (string-empty-p effort))
             (fboundp 'org-duration-to-minutes))
    (ignore-errors (org-duration-to-minutes effort))))

(defun simply-kanban--remaining-minutes (effort clocked done)
  "Return remaining minutes for EFFORT, CLOCKED, and DONE.
EFFORT is an Org duration string and CLOCKED is minutes.  Returns nil when
EFFORT is missing or invalid.  A DONE task has zero remaining minutes;
otherwise the result is EFFORT minus CLOCKED, floored at zero."
  (let ((effort-minutes (simply-kanban--effort-minutes effort)))
    (when effort-minutes
      (if done
          0
        (max 0 (- effort-minutes (or clocked 0)))))))

(defun simply-kanban--over-minutes (effort clocked)
  "Return over-budget minutes for EFFORT and CLOCKED.
EFFORT is an Org duration string and CLOCKED is minutes.  Returns nil when
EFFORT is missing or invalid; otherwise the result is CLOCKED minus EFFORT,
floored at zero."
  (let ((effort-minutes (simply-kanban--effort-minutes effort)))
    (when effort-minutes
      (max 0 (- (or clocked 0) effort-minutes)))))

(defun simply-kanban--format-effort (minutes)
  "Return MINUTES formatted as an Org duration string."
  (if (fboundp 'org-duration-from-minutes)
      (org-duration-from-minutes minutes)
    (format "%dm" (round minutes))))

(defun simply-kanban--format-jira-duration (minutes)
  "Return MINUTES formatted as a Jira-style duration such as \"1d 3h 42m\".
The day length comes from `org-duration-units'.  Zero components are omitted;
zero minutes is \"0m\"."
  (let* ((day (max 1 (round (or (cdr (assoc "d" org-duration-units)) 1440))))
         (total (max 0 (round (or minutes 0))))
         (days (/ total day))
         (remainder (% total day))
         (hours (/ remainder 60))
         (mins (% remainder 60))
         parts)
    (when (> days 0) (push (format "%dd" days) parts))
    (when (> hours 0) (push (format "%dh" hours) parts))
    (when (or (> mins 0) (null parts)) (push (format "%dm" mins) parts))
    (mapconcat #'identity (nreverse parts) " ")))

(defun simply-kanban--format-compact-duration (minutes)
  "Return MINUTES as a compact duration such as \"1d:1h:23m\".
The day length comes from `org-duration-units'.  Zero components are omitted;
zero minutes is \"0m\"."
  (replace-regexp-in-string
   " " ":"
   (simply-kanban--format-jira-duration minutes)))

(defun simply-kanban--format-points (points)
  "Return POINTS formatted without a trailing .0."
  (if (and (floatp points) (= points (truncate points)))
      (number-to-string (truncate points))
    (number-to-string points)))

(defun simply-kanban--column-points (tasks)
  "Return the summed story points of TASKS as a string, or nil when none set."
  (let ((total 0)
        (any nil))
    (dolist (task tasks)
      (let ((points (plist-get task :points)))
        (when points
          (setq any t
                total (+ total points)))))
    (when any (simply-kanban--format-points total))))

(defun simply-kanban--column-effort (tasks)
  "Return the summed effort of TASKS as a duration string, or nil when none set."
  (let ((total (cl-reduce
                (lambda (acc tk)
                  (+ acc (or (simply-kanban--effort-minutes (plist-get tk :effort)) 0)))
                tasks :initial-value 0)))
    (when (> total 0) (simply-kanban--format-effort total))))

(defun simply-kanban--column-clock (tasks)
  "Return the summed clocked time of TASKS, or nil when none is clocked."
  (let ((total (cl-reduce (lambda (acc tk)
                            (+ acc (or (plist-get tk :clocked) 0)))
                          tasks :initial-value 0)))
    (when (> total 0) (simply-kanban--format-effort total))))

(defun simply-kanban--column-remaining (tasks)
  "Return the summed remaining time of TASKS, or nil when none remains."
  (let ((total (cl-reduce (lambda (acc tk)
                            (+ acc (or (plist-get tk :remaining) 0)))
                          tasks :initial-value 0)))
    (when (> total 0) (simply-kanban--format-jira-duration total))))

(defun simply-kanban--column-over (tasks)
  "Return the summed over-budget time of TASKS, or nil when none is over."
  (let ((total (cl-reduce (lambda (acc tk)
                            (+ acc (or (plist-get tk :over) 0)))
                          tasks :initial-value 0)))
    (when (> total 0) (simply-kanban--format-jira-duration total))))

(defun simply-kanban--column-progress (tasks)
  "Return the completed fraction of TASKS, or nil when there is no data.
Completed effort counts a DONE task as fully complete and an in-progress
task as its clocked time, capped at its estimate.  Falls back to the
done-card count when no efforts are set."
  (let ((effort-total 0)
        (burned-total 0))
    (dolist (task tasks)
      (let ((effort (simply-kanban--effort-minutes (plist-get task :effort))))
        (when effort
          (setq effort-total (+ effort-total effort))
          (setq burned-total
                (+ burned-total
                   (if (plist-get task :done)
                       effort
                     (min effort (or (plist-get task :clocked) 0))))))))
    (cond
     ((> effort-total 0) (/ burned-total (float effort-total)))
     ((> (length tasks) 0)
      (/ (seq-count (lambda (task) (plist-get task :done)) tasks)
         (float (length tasks))))
     (t nil))))

(defun simply-kanban--card-progress (task)
  "Return TASK's completed fraction of its effort estimate, or nil.
A DONE task is fully complete.  Any other task is its clocked time divided
by its effort estimate, capped at 1.0.  Tasks without an effort estimate or
without any clocked time have no progress data unless they are DONE, so they
show no empty progress bar."
  (let ((effort (simply-kanban--effort-minutes (plist-get task :effort)))
        (clocked (plist-get task :clocked)))
    (cond
     ((plist-get task :done) 1.0)
     ((and effort clocked (> clocked 0))
      (/ (min effort clocked) (float effort)))
     (t nil))))

(defun simply-kanban--progress-bar (fraction width face)
  "Return a progress bar of WIDTH characters for FRACTION, filled with FACE."
  (let* ((fraction (max 0.0 (min 1.0 (or fraction 0.0))))
         (filled (round (* fraction width)))
         (empty (- width filled)))
    (concat
     (propertize (make-string filled ?█) 'face face)
     (propertize (make-string empty ?░) 'face 'shadow))))

(defun simply-kanban--truncate-title (title expanded)
  "Return TITLE shortened to `simply-kanban--title-length' characters.
Returns TITLE unchanged when EXPANDED is non-nil, when no limit is set, or when
it already fits; otherwise it is cut to the limit with an ellipsis appended."
  (let ((limit simply-kanban--title-length))
    (if (and limit (not expanded) (> (length title) limit))
        (concat (substring title 0 limit) "…")
      title)))

(defun simply-kanban--fit-line (text width)
  "Return TEXT fitting WIDTH columns, truncating with an ellipsis if needed."
  (if (<= (string-width text) width)
      text
    (concat (truncate-string-to-width text (max 0 (1- width))) "…")))

(defun simply-kanban--short-title (title)
  "Return the first token of TITLE, or TITLE when it has none."
  (or (car (split-string title)) title))

(defun simply-kanban--jira-number (title)
  "Return the Jira issue number at the start of TITLE, or nil."
  (when (and title
             (string-match simply-kanban-jira-number-regexp title))
    (or (match-string 1 title) (match-string 0 title))))

(defun simply-kanban--bold-jira-number (text)
  "Return a copy of TEXT with its Jira issue number in bold."
  (let ((jira (simply-kanban--jira-number text)))
    (if (and jira (string-match (regexp-quote jira) text))
        (let ((text (copy-sequence text)))
          (add-face-text-property (match-beginning 0) (match-end 0)
                                  'simply-kanban-jira nil text)
          text)
      text)))

(defun simply-kanban--ticket-relation-line (task)
  "Return a propertized type and hierarchy line for TASK, or nil.
The line names the card's STORY or TASK type, its parent story when it has
one, and the number of children when it is a story.  Controlled by
`simply-kanban-show-ticket-types'."
  (when simply-kanban-show-ticket-types
    (let* ((type (plist-get task :type))
           (parent (plist-get task :parent))
           (children (plist-get task :children))
           (done (or (plist-get task :children-done) 0))
           (type-label
            (pcase type
              ('story (propertize "STORY" 'face 'simply-kanban-story))
              ('task (propertize "TASK" 'face 'simply-kanban-task))
              (_ nil)))
           (parts
            (delq nil
                  (list
                   type-label
                   (when parent
                     (if simply-kanban--compact-cards
                         (let ((key (plist-get task :parent-jira)))
                           (concat
                            (propertize "parent " 'face 'shadow)
                            (if key
                                (simply-kanban--bold-jira-number key)
                              (propertize (simply-kanban--short-title parent)
                                          'face 'shadow))))
                       (let ((text (concat "child of " parent)))
                         (add-face-text-property 0 (length text)
                                                 'shadow nil text)
                         (simply-kanban--bold-jira-number text))))
                   (when (and children (> children 0))
                     (propertize
                      (if simply-kanban--compact-cards
                          (if (> done 0)
                              (format "%d child%s (%d done)"
                                      children (if (= children 1) "" "ren")
                                      done)
                            (format "%d child%s"
                                    children (if (= children 1) "" "ren")))
                        (format "parent of %d child%s (%d done)"
                                children (if (= children 1) "" "ren") done))
                      'face 'shadow)))))
           (separator
            (if simply-kanban--compact-cards
                " "
              (propertize " · " 'face 'shadow))))
      (when parts
        (mapconcat #'identity parts separator)))))

(defun simply-kanban--format-card (task width)
  "Return card lines for TASK fitting WIDTH.
A card shows its title prefixed by a priority cookie when one is set, then
its metadata and, when the card has progress data, a progress bar.  A
type/hierarchy line shows whether the card is a STORY or TASK, its parent
story, and its child count when
`simply-kanban-show-ticket-types' is non-nil.  By default the metadata is
condensed onto one line listing the board and source-file markers when
present, then effort, remaining or over-budget time, sprint, and tags,
omitting values the card lacks.  Numeric values are unlabelled and separated
by spaces; durations use colon-separated units and the sprint value appears
without a label.  Story points and clocked time are omitted from the compact
line.  With `simply-kanban--compact-cards' nil each value gets its own
labelled line instead.  The title is truncated to
`simply-kanban--title-length' unless the card is expanded.  When the card is
expanded (see `simply-kanban--expanded-cards') the full title is shown, the
Org body follows below a divider, and an expanded STORY also lists its
children."
  (let* ((inner (max 1 (- width 4)))
         (keyword (plist-get task :keyword))
         (border-face (simply-kanban--keyword-face keyword))
         (story (eq (plist-get task :type) 'story))
         (outline-face (if story 'simply-kanban-story border-face))
         (vbar (if story "║" "│"))
         (hbar (if story ?═ ?─))
         (top-left (if story "╔" "┌"))
         (top-right (if story "╗" "┐"))
         (bottom-left (if story "╚" "└"))
         (bottom-right (if story "╝" "┘"))
         (mid-left (if story "╠" "├"))
         (mid-right (if story "╣" "┤"))
         (prio (plist-get task :priority))
         (prio-cookie (pcase prio (?A "[#A]") (?B "[#B]") (?C "[#C]") (_ nil)))
         (marker (plist-get task :marker))
         (expanded (simply-kanban--card-expanded-p marker))
         (title (simply-kanban--bold-jira-number
                 (simply-kanban--truncate-title
                  (or (plist-get task :title) "")
                  expanded)))
         (title-text (if prio-cookie (concat prio-cookie " " title) title))
         (title-lines (simply-kanban--wrap title-text inner))
         (relations (simply-kanban--ticket-relation-line task))
         (relation-lines
          (when relations
            (if simply-kanban--compact-cards
                (list (simply-kanban--fit-line relations inner))
              (simply-kanban--wrap relations inner))))
         (child-tasks (and expanded
                           (eq (plist-get task :type) 'story)
                           (plist-get task :child-tasks)))
         (child-task-lines
          (when child-tasks
            (seq-mapcat
             (lambda (child)
               (let* ((kw (plist-get child :keyword))
                      (head (concat
                             "- "
                             (propertize kw 'face
                                         (simply-kanban--keyword-face kw))
                             " "))
                      (title (simply-kanban--bold-jira-number
                              (or (plist-get child :title) ""))))
                 (simply-kanban--wrap (concat head title) inner)))
             child-tasks)))
         (tags (plist-get task :tags))
         (tags-badge (when tags
                       (propertize (concat ":" (mapconcat #'identity tags ":") ":")
                                   'face 'simply-kanban-tag)))
         (tags-lines (when tags-badge
                       (simply-kanban--wrap tags-badge inner)))
         (sprint (and simply-kanban-show-sprint
                      (not simply-kanban--sprint-filter)
                      (plist-get task :sprint)))
         (sprint-badge (when sprint
                         (propertize (format "Sprint: %s" sprint)
                                     'face 'simply-kanban-sprint)))
         (sprint-compact (when sprint
                           (propertize sprint 'face 'simply-kanban-sprint)))
         (sprint-lines (when sprint-badge
                         (simply-kanban--wrap sprint-badge inner)))
         (effort (and simply-kanban-show-effort (plist-get task :effort)))
         (effort-value (and effort (not (string-empty-p effort)) effort))
         (effort-line (when effort-value
                        (propertize (concat "Effort: " effort-value)
                                    'face 'simply-kanban-effort)))
         (effort-compact (when effort-value
                           (propertize effort-value 'face 'simply-kanban-effort)))
         (points (and simply-kanban-show-story-points
                      (plist-get task :points)))
         (points-value (when points (simply-kanban--format-points points)))
         (points-line (when points-value
                        (propertize (concat "Points: " points-value)
                                    'face 'simply-kanban-points)))
         (clocked (and simply-kanban-show-clock (plist-get task :clocked)))
         (clocking (and simply-kanban-show-clock (plist-get task :clocking)))
         (clock-value (when (or clocking (> (or clocked 0) 0))
                        (concat (simply-kanban--format-effort (or clocked 0))
                                (when clocking " (run)"))))
         (clock-line (when clock-value
                       (propertize (concat "Clocked: " clock-value)
                                   'face 'simply-kanban-clock)))
         (over (and simply-kanban-show-remaining (plist-get task :over)))
         (over-value (when (and over (> over 0))
                       (simply-kanban--format-jira-duration over)))
         (over-lines (when over-value
                       (simply-kanban--wrap
                        (propertize (concat "Over: " over-value)
                                    'face 'simply-kanban-over)
                        inner)))
         (over-compact (when over-value
                         (propertize
                          (concat "+" (simply-kanban--format-compact-duration over))
                          'face 'simply-kanban-over)))
         (remaining (and simply-kanban-show-remaining
                         (plist-get task :remaining)))
         (remaining-value (when (and remaining
                                     (null over-value)
                                     (or clocking (> (or clocked 0) 0)))
                            (simply-kanban--format-jira-duration remaining)))
         (remaining-lines (when remaining-value
                            (simply-kanban--wrap
                             (propertize (concat "Remaining: " remaining-value)
                                         'face 'simply-kanban-remaining)
                             inner)))
         (remaining-compact (when remaining-value
                              (propertize
                               (simply-kanban--format-compact-duration remaining)
                               'face 'simply-kanban-remaining)))
         (progress (and simply-kanban-show-card-progress
                        (simply-kanban--card-progress task)))
         (progress-line (when progress
                          (simply-kanban--progress-bar progress inner border-face)))
         (board-line (when simply-kanban--show-board
                       (let ((b (plist-get task :board)))
                         (when b (propertize (concat "▸ " b) 'face 'shadow)))))
         (file-line (when simply-kanban--multi-source
                      (propertize (concat "» " (or (plist-get task :file) "org"))
                                  'face 'shadow)))
         (compact-meta
          (when simply-kanban--compact-cards
            (delq nil
                  (list board-line
                        file-line
                        effort-compact
                        (or over-compact remaining-compact)
                        sprint-compact
                        tags-badge))))
         (compact-line (when compact-meta
                         (simply-kanban--fit-line
                          (mapconcat #'identity compact-meta " ")
                          inner)))
         (body (and expanded (plist-get task :body)))
         (logbook (and (simply-kanban--card-logbook-p marker)
                       (plist-get task :logbook)))
         (box (lambda (s)
                (concat (propertize vbar 'face outline-face)
                        " "
                        (simply-kanban--pad s inner)
                        " "
                        (propertize vbar 'face outline-face))))
         (rule (lambda (l r)
                 (concat (propertize l 'face outline-face)
                         (propertize (make-string (- width 2) hbar)
                                     'face outline-face)
                         (propertize r 'face outline-face))))
         lines)
    (push (funcall rule top-left top-right) lines)
    (dolist (tl title-lines)
      (push (funcall box tl) lines))
    (dolist (rline relation-lines)
      (push (funcall box rline) lines))
    (if simply-kanban--compact-cards
        (when compact-line
          (push (funcall box compact-line) lines))
      (dolist (tline tags-lines)
        (push (funcall box tline) lines))
      (dolist (sline sprint-lines)
        (push (funcall box sline) lines))
      (when effort-line
        (push (funcall box effort-line) lines))
      (when points-line
        (push (funcall box points-line) lines))
      (when clock-line
        (push (funcall box clock-line) lines))
      (dolist (oline over-lines)
        (push (funcall box oline) lines))
      (dolist (rline remaining-lines)
        (push (funcall box rline) lines)))
    (when progress-line
      (push (funcall box progress-line) lines))
    (unless simply-kanban--compact-cards
      (when board-line
        (push (funcall box board-line) lines))
      (when file-line
        (push (funcall box file-line) lines)))
    (when body
      (push (funcall rule mid-left mid-right) lines)
      (dolist (raw (split-string body "\n"))
        (if (string-empty-p raw)
            (push (funcall box "") lines)
          (dolist (bl (simply-kanban--wrap raw inner))
            (push (funcall box bl) lines)))))
    (when child-task-lines
      (push (funcall rule mid-left mid-right) lines)
      (push (funcall box "Children") lines)
      (dolist (line child-task-lines)
        (push (funcall box line) lines)))
    (when logbook
      (push (funcall rule mid-left mid-right) lines)
      (push (funcall box "Logbook") lines)
      (dolist (raw (split-string logbook "\n"))
        (if (string-empty-p raw)
            (push (funcall box "") lines)
          (dolist (ll (simply-kanban--wrap raw inner))
            (push (funcall box ll) lines)))))
    (push (funcall rule bottom-left bottom-right) lines)
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
         (points-total (and simply-kanban-show-story-points
                            (simply-kanban--column-points col-tasks)))
         (effort-total (and simply-kanban-show-effort
                            (simply-kanban--column-effort col-tasks)))
         (clock-total (and simply-kanban-show-clock
                           simply-kanban-show-clock-total
                           (simply-kanban--column-clock col-tasks)))
         (remaining-total (and simply-kanban-show-clock
                               simply-kanban-show-remaining
                               simply-kanban-show-remaining-total
                               (simply-kanban--column-remaining col-tasks)))
         (over-total (and simply-kanban-show-clock
                          simply-kanban-show-remaining
                          simply-kanban-show-over-total
                          (simply-kanban--column-over col-tasks)))
         (progress (and simply-kanban-show-column-progress
                        (simply-kanban--column-progress col-tasks)))
         (header (propertize (concat (format " %s (%d)" keyword (length col-tasks))
                                     (when points-total (format " (%s pts)" points-total))
                                     (when effort-total (format " [%s]" effort-total))
                                     (when clock-total (format " {%s}" clock-total))
                                     (when remaining-total
                                       (format " <%s>" remaining-total))
                                     (when over-total
                                       (format " !%s" over-total)))
                             'face header-face
                             'simply-kanban-keyword keyword))
         (divider (if simply-kanban-show-column-progress
                      (propertize (simply-kanban--progress-bar
                                   progress width header-face)
                                  'simply-kanban-keyword keyword)
                    (propertize (make-string width ?─)
                                'face 'shadow
                                'simply-kanban-keyword keyword)))
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
  (let ((win (or (get-buffer-window (current-buffer))
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

(defun simply-kanban--inherit-duration-units (buffers)
  "Set `org-duration-units' from the first live buffer in BUFFERS.
This keeps duration badges on a board consistent with its source Org
file's buffer-local units."
  (let ((source (seq-find #'buffer-live-p buffers)))
    (when source
      (setq-local org-duration-units
                  (buffer-local-value 'org-duration-units source)))))

(defun simply-kanban--render (spec)
  "Render the kanban board described by SPEC into the current buffer.
SPEC is resolved to a list of Org buffers via `simply-kanban--spec-buffers'.
Columns expand to fill the board window (see `simply-kanban-min-column-width').
Must be called with the board buffer current and its window selected."
  (mapc #'delete-overlay simply-kanban--running-overlays)
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
                     (lambda (tk) (equal simply-kanban--sprint-filter
                                         (plist-get tk :sprint)))
                     tasks)
                  tasks))
         (tasks (if simply-kanban--show-stories
                    tasks
                  (cl-remove-if (lambda (tk)
                                  (eq (plist-get tk :type) 'story))
                                tasks)))
         (keywords (simply-kanban--merge-keywords buffers))
         (width (simply-kanban--column-width (length keywords)))
         (gap (make-string simply-kanban-column-gap ?\s))
         (columns (progn
                    (simply-kanban--inherit-duration-units buffers)
                    (mapcar (lambda (kw) (simply-kanban--column-cells kw tasks width))
                            keywords)))
         (nrows (apply #'max 0 (mapcar #'length columns))))
    (erase-buffer)
    (setq simply-kanban--source-spec spec
          simply-kanban--source-buffers buffers
          simply-kanban--keywords keywords
          simply-kanban--running-card nil
          simply-kanban--running-overlays nil)
    (if (null buffers)
        (insert "No source Org buffers.\n")
      (dotimes (row nrows)
        (let ((segments (mapcar (lambda (col)
                                  (or (nth row col)
                                      (simply-kanban--pad "" width)))
                                columns)))
          (insert (string-join segments gap) "\n"))))
    (simply-kanban--install-hooks (current-buffer) buffers)
    (simply-kanban--highlight-running-card)
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

(defun simply-kanban-goto (&optional select)
  "Reveal the Org heading for the card at point.
The heading's file is shown in another window and the heading line is briefly
pulsed.  Focus stays in the board unless SELECT is non-nil, in which case the
heading's window is selected so point lands in the Org file."
  (interactive "P")
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
            (simply-kanban--flash-heading))
          (when select
            (select-window win)))))))

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

(defun simply-kanban-set-story-points ()
  "Set the STORY_POINTS property of the card at point.
Empty input removes the property."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (buffer-live-p (marker-buffer marker))))
        (message "Point is not on a card")
      (let ((input (string-trim
                    (read-string "Story points (empty = remove): "))))
        (unless (or (string-empty-p input)
                    (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" input))
          (user-error "Story points must be a non-negative number"))
        (with-current-buffer (marker-buffer marker)
          (org-with-wide-buffer
           (goto-char marker)
           (org-back-to-heading t)
           (if (string-empty-p input)
               (org-delete-property "STORY_POINTS")
             (org-set-property "STORY_POINTS" input))))
        (simply-kanban--maybe-save (marker-buffer marker))
        (simply-kanban-refresh)
        (simply-kanban--goto-marker marker)
        (if (string-empty-p input)
            (message "Story points cleared")
          (message "Story points: %s" input))))))

(defun simply-kanban-clock-in ()
  "Clock in the card at point."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (unless (and marker (buffer-live-p (marker-buffer marker)))
      (user-error "Point is not on a card"))
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (goto-char marker)
       (org-back-to-heading t)
       (org-clock-in)))
    (simply-kanban--maybe-save (marker-buffer marker))
    (simply-kanban-refresh)
    (message "Clocked in")))

(defun simply-kanban-clock-out ()
  "Clock out the currently running Org clock."
  (interactive)
  (if (not (org-clock-is-active))
      (message "No active clock")
    (let ((buffer (marker-buffer org-clock-marker)))
      (org-clock-out)
      (when (buffer-live-p buffer)
        (simply-kanban--maybe-save buffer))
      (simply-kanban-refresh)
      (message "Clocked out"))))

(defun simply-kanban-toggle-clock ()
  "Clock in the card at point, or clock it out if it is already running."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (unless (and marker (buffer-live-p (marker-buffer marker)))
      (user-error "Point is not on a card"))
    (if (simply-kanban--card-clocking-p marker)
        (simply-kanban-clock-out)
      (simply-kanban-clock-in))))

(defvar simply-kanban--note-card nil
  "Marker for the card whose Org note is being edited, or nil.")

(defvar simply-kanban--note-board nil
  "Board buffer that initiated the current Org note, or nil.")

(defun simply-kanban--display-note-buffer (buffer alist)
  "Display note BUFFER without hiding the kanban board.
ALIST is passed to `display-buffer-in-side-window'."
  (if (string= (buffer-name buffer) "*Org Note*")
      (display-buffer-in-side-window
       buffer
       (append '((side . bottom) (slot . 0) (window-height . 0.3))
               alist))
    (display-buffer-in-side-window
     buffer
     (append '((side . right) (slot . 0) (window-width . 0.4))
             alist))))

(defun simply-kanban--org-add-log-note-around (orig &rest args)
  "Call ORIG with ARGS, displaying note buffers beside the kanban board."
  (if simply-kanban--note-card
      (let ((display-buffer-overriding-action
             (list (cons #'simply-kanban--display-note-buffer nil))))
        (apply orig args))
    (apply orig args)))

(defun simply-kanban--org-store-log-note-around (orig &rest args)
  "Call ORIG with ARGS and restore the annotated kanban card afterwards."
  (unwind-protect
      (apply orig args)
    (when simply-kanban--note-card
      (let ((card simply-kanban--note-card)
            (board simply-kanban--note-board))
        (setq simply-kanban--note-card nil
              simply-kanban--note-board nil)
        (when (and (buffer-live-p board) (marker-buffer card))
          (with-current-buffer board
            (simply-kanban-refresh)
            (simply-kanban--goto-marker card)))))))

(defun simply-kanban-add-note ()
  "Add a timestamped note to the card at point with Org's note prompt.
The board stays visible while the note is written, and returns to the
same card once the note is stored or cancelled."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (unless (and marker (buffer-live-p (marker-buffer marker)))
      (user-error "Point is not on a card"))
    (setq simply-kanban--note-card (copy-marker marker)
          simply-kanban--note-board (current-buffer))
    (condition-case err
        (with-current-buffer (marker-buffer marker)
          (org-with-wide-buffer
           (goto-char marker)
           (org-back-to-heading t)
           (org-add-note)))
      (error
       (setq simply-kanban--note-card nil
             simply-kanban--note-board nil)
       (signal (car err) (cdr err))))))

(advice-add 'org-add-log-note :around #'simply-kanban--org-add-log-note-around)
(advice-add 'org-store-log-note :around #'simply-kanban--org-store-log-note-around)

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

(defun simply-kanban--sprint-lessp (a b)
  "Return non-nil when sprint A should sort before sprint B.
Whole-number sprints compare numerically; other values compare
lexicographically."
  (let ((na (and (string-match-p "\\`[0-9]+\\'" a) (string-to-number a)))
        (nb (and (string-match-p "\\`[0-9]+\\'" b) (string-to-number b))))
    (if (and na nb) (< na nb) (string< a b))))

(defun simply-kanban-set-sprint ()
  "Set the SPRINT property of the card at point to chosen text.
Empty input removes the property; the card then falls back to an inherited
SPRINT property or, when `simply-kanban-sprint-from-heading' is non-nil, its
section heading."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (if (not (and marker (buffer-live-p (marker-buffer marker))))
        (message "Point is not on a card")
      (let ((input (string-trim (read-string "Card sprint (empty = remove): "))))
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
        (if (string-empty-p input)
            (message "Sprint property cleared")
          (message "Sprint %s" input))))))

(defun simply-kanban-set-sprint-filter ()
  "Display only cards in a chosen sprint.
Offers the sprint values present on the board for completion, and accepts
any text; empty input clears the filter and shows every sprint."
  (interactive)
  (let* ((buffers (simply-kanban--spec-buffers simply-kanban--source-spec))
         (tasks (simply-kanban--collect-all buffers))
         (sprints (sort (delete-dups
                         (delq nil (mapcar (lambda (tk) (plist-get tk :sprint)) tasks)))
                        #'simply-kanban--sprint-lessp))
         (input (string-trim
                 (completing-read "Show sprint (empty = all): " sprints nil nil))))
    (setq simply-kanban--sprint-filter (unless (string-empty-p input) input))
    (simply-kanban-refresh)
    (force-mode-line-update)
    (if simply-kanban--sprint-filter
        (message "Sprint filter: %s" simply-kanban--sprint-filter)
      (message "Cleared sprint filter"))))

(defun simply-kanban-clear-sprint-filter ()
  "Clear the active sprint filter, showing every sprint."
  (interactive)
  (setq simply-kanban--sprint-filter nil)
  (simply-kanban-refresh)
  (force-mode-line-update)
  (message "Cleared sprint filter"))

(defun simply-kanban-set-title-length ()
  "Set the maximum displayed card-title length for the current board.
Prompts for a number of characters; empty input removes the limit and shows
titles in full.  Affects only this board (the default is
`simply-kanban-max-title-length').  Truncated titles are restored in full when
a card is expanded with \\[simply-kanban-toggle-expand]."
  (interactive)
  (unless (derived-mode-p 'simply-kanban-mode)
    (user-error "Not in a kanban board"))
  (let ((input (string-trim (read-string "Max title length (empty = no limit): "))))
    (cond
     ((string-empty-p input)
      (setq simply-kanban--title-length nil))
     ((string-match-p "\\`[0-9]+\\'" input)
      (let ((n (string-to-number input)))
        (when (<= n 0)
          (user-error "Title length must be a positive number"))
        (setq simply-kanban--title-length n)))
     (t (user-error "Title length must be a whole number")))
    (simply-kanban-refresh)
    (if simply-kanban--title-length
        (message "Title length: %d" simply-kanban--title-length)
      (message "Title length: unlimited"))))

(defun simply-kanban-toggle-compact ()
  "Toggle single-line metadata on the current board's cards."
  (interactive)
  (unless (derived-mode-p 'simply-kanban-mode)
    (user-error "Not in a kanban board"))
  (setq simply-kanban--compact-cards (not simply-kanban--compact-cards))
  (simply-kanban-refresh)
  (message "Compact cards %s"
           (if simply-kanban--compact-cards "enabled" "disabled")))

(defun simply-kanban-toggle-stories ()
  "Toggle whether STORY cards are shown on this board."
  (interactive)
  (unless (derived-mode-p 'simply-kanban-mode)
    (user-error "Not in a kanban board"))
  (setq simply-kanban--show-stories (not simply-kanban--show-stories))
  (simply-kanban-refresh)
  (message "Stories %s" (if simply-kanban--show-stories "shown" "hidden")))

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
  "Return a board spec covering every card of the current Org buffer.
A flat file yields the whole-buffer board; a multi-board file yields the
all-boards aggregate, so the heading at point is present whichever board it
belongs to.  Must be called with the Org buffer current."
  (if (simply-kanban--file-boards (current-buffer))
      (cons 'all-boards (current-buffer))
    (cons 'buffer (current-buffer))))

;;;###autoload
(defun simply-kanban--board-with-card (candidates)
  "Return a live board buffer containing a card for one of CANDIDATES."
  (seq-some
   (lambda (board)
     (when (with-current-buffer board
             (and (derived-mode-p 'simply-kanban-mode)
                  (seq-some #'simply-kanban--anchor-for-marker candidates)))
       board))
   (simply-kanban--board-buffers)))

(defun simply-kanban--locate-org-card ()
  "Return (BOARD . ANCHOR) for the card of the Org heading at point.
ANCHOR is the board's card anchor (POS . MARKER) matching the heading at -- or
enclosing -- point.  Create a board for the current file when none is open.
Return nil when no matching card is visible, e.g. because a tag or sprint
filter hides it.  Must be called with the Org buffer current."
  (let ((candidates (simply-kanban--heading-markers-upward)))
    (unless candidates
      (user-error "No Org heading at point"))
    (let* ((default-spec (simply-kanban--org-board-spec))
           (board (or (simply-kanban--board-with-card candidates)
                      (simply-kanban--find-board default-spec))))
      ;; Create a board for this file if none is open yet, in a split to the
      ;; right so the original Org file stays visible on the left.
      (unless board
        (let ((display-buffer-overriding-action
               '((display-buffer-in-direction)
                 (direction . right)
                 (window-width . 0.5))))
          (setq board (simply-kanban--open default-spec))))
      (when (buffer-live-p board)
        (let ((match (with-current-buffer board
                       (seq-some #'simply-kanban--anchor-for-marker candidates))))
          (when match (cons board match)))))))

(defun simply-kanban-show-card (&optional focus)
  "Select, on the kanban board, the card for the Org heading at point.
The inverse of \\[simply-kanban-goto]: run it from an Org buffer to locate the
heading at -- or enclosing -- point among the board's cards and select that
card.  The board is shown in another window but focus stays in the Org buffer.
The matched card is selected and focused with the usual bold current-card
highlight, just as if you had navigated to it on the board.
When the heading itself is not a card (e.g. point is on a non-TODO parent), the
nearest enclosing card is used.

With a prefix argument FOCUS, select the board window and leave point on the
card instead of returning focus to the Org buffer; see also
`simply-kanban-jump-to-card'.

If no open board contains the card, a board for this file is created first --
in a split to the right, keeping the Org file visible on the left -- so the
command always tries to take you to a card.  The card must be currently
visible; an active tag or sprint filter can hide it."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (let ((orig-win (selected-window))
        (target (simply-kanban--locate-org-card)))
    (if (not target)
        (message "No matching card on the board for this heading")
      (let* ((board (car target))
             (match (cdr target))
             ;; Reuse the board's own window when it already has one (e.g. the
             ;; right split we just created); otherwise show it without
             ;; stealing the Org file's window.
             (win (or (get-buffer-window board)
                      (display-buffer board '(nil (inhibit-same-window . t))))))
        (when (window-live-p win)
          (if focus
              (progn
                (select-window win)
                (goto-char (car match))
                (recenter)
                (simply-kanban--highlight-card))
            ;; Select the card in the board window, focusing it with the usual
            ;; bold current-card highlight, but keep focus in the Org buffer.
            (with-selected-window win
              (goto-char (car match))
              (simply-kanban--highlight-card))
            (when (window-live-p orig-win)
              (select-window orig-win))))))))

;;;###autoload
(defun simply-kanban-jump-to-card ()
  "Jump from the Org heading at point to its card on the kanban board.
Unlike `simply-kanban-show-card', move focus to the board window and leave
point on the card.  Create a board for the current file when none is open.
The card must be visible; an active tag or sprint filter can hide it."
  (interactive)
  (simply-kanban-show-card t))

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

(defun simply-kanban--after-note-stored ()
  "Save the source buffer after an Org note is stored.
Runs from `org-after-note-stored-hook' in the source Org buffer."
  (when (simply-kanban--boards-for (current-buffer))
    (simply-kanban--maybe-save (current-buffer))))

(add-hook 'org-after-note-stored-hook #'simply-kanban--after-note-stored)

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
  "Toggle showing the Org body of the card at point.
For a STORY, expanding also lists its children."
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

(defun simply-kanban-toggle-logbook ()
  "Toggle showing the LOGBOOK drawer of the card at point."
  (interactive)
  (let ((marker (simply-kanban--marker-at-point)))
    (unless marker
      (user-error "Point is not on a card"))
    (if (simply-kanban--card-logbook-p marker)
        (setq simply-kanban--logbook-cards
              (cl-remove-if (lambda (m) (simply-kanban--same-card-p m marker))
                            simply-kanban--logbook-cards))
      (push (copy-marker marker) simply-kanban--logbook-cards))
    (simply-kanban-refresh)))

(defun simply-kanban-toggle-expand-all ()
  "Expand the body of every card, or collapse them all if any are expanded.
Expanded STORY cards also list their children."
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

(defun simply-kanban--running-card-marker ()
  "Return the marker of the card with the running clock, or nil."
  (let ((pos (simply-kanban--active-clock-heading-position)))
    (when pos
      (seq-some (lambda (anchor)
                  (let ((marker (cdr anchor)))
                    (and marker
                         (marker-buffer marker)
                         (eq (marker-buffer org-clock-marker) (marker-buffer marker))
                         (= pos (marker-position marker))
                         marker)))
                (simply-kanban--anchors)))))

(defun simply-kanban--running-block-overlay (beg end face)
  "Draw a solid block overlay from BEG to END in FACE."
  (let* ((width (string-width (buffer-substring-no-properties beg end)))
         (bar (propertize (make-string width ?█) 'face face))
         (ov (make-overlay beg end)))
    (overlay-put ov 'face face)
    (overlay-put ov 'display bar)
    (overlay-put ov 'priority 90)
    (push ov simply-kanban--running-overlays)))

(defun simply-kanban--highlight-running-card ()
  "Draw a solid block outline around the running card.
The blocks use the card's own outline colour.  Clear any previous running
highlight first."
  (mapc #'delete-overlay simply-kanban--running-overlays)
  (setq simply-kanban--running-overlays nil)
  (let* ((card (simply-kanban--running-card-marker))
         (regions (simply-kanban--card-regions card)))
    (setq simply-kanban--running-card card)
    (setq simply-kanban--running-clock-state (simply-kanban--clock-state))
    (when regions
      (let* ((top (car regions))
             (bottom (car (last regions)))
             (middle (butlast (cdr regions)))
             (face (or (get-text-property (car top) 'face)
                       'simply-kanban-column-header)))
        (simply-kanban--running-block-overlay (car top) (cdr top) face)
        (unless (equal top bottom)
          (simply-kanban--running-block-overlay
           (car bottom) (cdr bottom) face))
        (dolist (region middle)
          (when (< (car region) (cdr region))
            (simply-kanban--running-block-overlay
             (car region) (1+ (car region)) face)
            (simply-kanban--running-block-overlay
             (1- (cdr region)) (cdr region) face)))))))

(defun simply-kanban--sync-running-card ()
  "Refresh the board when the active clock changes."
  (unless (equal (simply-kanban--clock-state)
                 simply-kanban--running-clock-state)
    (simply-kanban-refresh)))

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
    (define-key map (kbd "C-m") #'simply-kanban-goto)
    (define-key map (kbd "}") #'simply-kanban-advance)
    (define-key map (kbd "{") #'simply-kanban-retreat)
    (define-key map (kbd "s") #'simply-kanban-set-status)
    (define-key map (kbd "k") #'simply-kanban-delete)
    (define-key map (kbd "t") #'simply-kanban-set-tag-filter)
    (define-key map (kbd "T") #'simply-kanban-clear-tag-filter)
    (define-key map (kbd "S") #'simply-kanban-set-sprint-filter)
    (define-key map (kbd "C") #'simply-kanban-clear-sprint-filter)
    (define-key map (kbd ":") #'simply-kanban-set-tags)
    (define-key map (kbd ",") #'simply-kanban-set-priority)
    (define-key map (kbd ";") #'simply-kanban-set-effort)
    (define-key map (kbd "P") #'simply-kanban-set-story-points)
    (define-key map (kbd "N") #'simply-kanban-add-note)
    (define-key map (kbd "L") #'simply-kanban-toggle-logbook)
    (define-key map (kbd "c") #'simply-kanban-toggle-compact)
    (define-key map (kbd "v") #'simply-kanban-toggle-stories)
    (define-key map (kbd "#") #'simply-kanban-set-sprint)
    (define-key map (kbd "i") #'simply-kanban-clock-in)
    (define-key map (kbd "o") #'simply-kanban-clock-out)
    (define-key map (kbd "F") #'simply-kanban-toggle-follow)
    (define-key map (kbd "e") #'simply-kanban-toggle-expand)
    (define-key map (kbd "E") #'simply-kanban-toggle-expand-all)
    (define-key map (kbd "B") #'simply-kanban-switch-board)
    (define-key map (kbd "l") #'simply-kanban-set-title-length)
    (define-key map (kbd "g") #'simply-kanban-refresh)
    (define-key map (kbd "SPC") #'simply-kanban-transient)
    (define-key map (kbd "?") #'simply-kanban-transient)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `simply-kanban-mode'.")

(defun simply-kanban--header-source ()
  "Return a human-readable description of the board's source.
Used to build the board buffer name."
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

(defun simply-kanban--same-spec-p (a b)
  "Return non-nil when board specs A and B describe the same source."
  (pcase (list a b)
    (`((buffer . ,b1) (buffer . ,b2)) (eq b1 b2))
    (`((board ,b1 ,m1) (board ,b2 ,m2))
     (and (eq b1 b2) (simply-kanban--same-card-p m1 m2)))
    (`((toplevel . ,b1) (toplevel . ,b2)) (eq b1 b2))
    (`((all-boards . ,b1) (all-boards . ,b2)) (eq b1 b2))
    (`((files . ,f1) (files . ,f2)) (equal f1 f2))
    (_ nil)))

(defun simply-kanban--board-buffers ()
  "Return all live kanban board buffers."
  (seq-filter (lambda (buf)
                (with-current-buffer buf
                  (derived-mode-p 'simply-kanban-mode)))
              (buffer-list)))

(defun simply-kanban--find-board (spec)
  "Return a live board buffer for SPEC, or nil."
  (seq-find (lambda (buf)
              (simply-kanban--same-spec-p
               (buffer-local-value 'simply-kanban--source-spec buf)
               spec))
            (simply-kanban--board-buffers)))

(defun simply-kanban--spec-buffer-name (spec)
  "Return the canonical buffer name for the board described by SPEC."
  (let* ((base (string-trim simply-kanban-buffer-name "\\*+" "\\*+"))
         (source (let ((simply-kanban--source-spec spec))
                   (simply-kanban--header-source))))
    (format "*%s: %s*" base source)))

(define-derived-mode simply-kanban-mode special-mode "Kanban"
  "Major mode for the Org-linked kanban board.

\\{simply-kanban-mode-map}"
  (setq-local truncate-lines t)
  (setq-local cursor-type 'box)
  (setq-local mode-line-buffer-identification
              (list (propertize "%b" 'face 'mode-line-buffer-id)
                    '(:eval
                      (when simply-kanban--sprint-filter
                        (concat " "
                                (propertize
                                 (format "[sprint: %s]"
                                         simply-kanban--sprint-filter)
                                 'face 'warning))))))
  (setq header-line-format
        '(" "
          ;; Status indicators lead the header line so a narrow window
          ;; never hides them behind the key reminders.  They are joined
          ;; with single spaces, and the whole group is followed by one.
          (:eval
           (let (parts)
             (when (org-clock-is-active)
               (push (propertize
                      (format "[clock: %s]"
                              (org-duration-from-minutes
                               (org-clock-get-clocked-time)))
                      'face 'warning)
                     parts))
             (when simply-kanban--tag-filter
               (push (propertize (format "[tag: %s]" simply-kanban--tag-filter)
                                 'face 'success)
                     parts))
             (when simply-kanban--show-stories
               (push (propertize "[stories]" 'face 'success) parts))
             (if parts
                 (concat (mapconcat #'identity (nreverse parts) " ") " ")
               "")))
          (:eval (propertize "?" 'face 'help-key-binding)) " menu  "
          (:eval (propertize "{}" 'face 'help-key-binding)) " move  "
          (:eval (propertize "e/E" 'face 'help-key-binding)) " expand  "
          (:eval (propertize "N" 'face 'help-key-binding)) " note  "
          (:eval (propertize "L" 'face 'help-key-binding)) " log  "
          (:eval (propertize "i/o" 'face 'help-key-binding)) " clock  "
          (:eval (propertize "#" 'face 'help-key-binding)) " card sprint  "
          (:eval (propertize "S" 'face 'help-key-binding)) " sprint"))
  (add-hook 'post-command-hook #'simply-kanban--highlight-card nil t)
  (add-hook 'post-command-hook #'simply-kanban--sync-running-card nil t))

;;; Transient menu

(defun simply-kanban--transient-description ()
  "Header string for the `simply-kanban' transient menu."
  (format "Simply Kanban   source: %s%s%s"
          (simply-kanban--header-source)
          (if simply-kanban--tag-filter
              (format "   tag: %s" simply-kanban--tag-filter)
            "")
          (if simply-kanban--sprint-filter
              (format "   sprint: %s" simply-kanban--sprint-filter)
            "")))

;;;###autoload (autoload 'simply-kanban-transient "simply-kanban" nil t)
(transient-define-prefix simply-kanban-transient ()
  "Transient menu for `simply-kanban'."
  [:description simply-kanban--transient-description
   ["Move / Edit"
    ("}" "advance stage"   simply-kanban-advance :transient t)
    ("{" "retreat stage"   simply-kanban-retreat :transient t)
    ("s" "set status"      simply-kanban-set-status)
    ("," "set priority"    simply-kanban-set-priority)
    (":" "set tags"        simply-kanban-set-tags)
    (";" "set effort"      simply-kanban-set-effort)
    ("P" "story points"    simply-kanban-set-story-points)
    ("N" "add note"        simply-kanban-add-note)
    ("#" "set card sprint" simply-kanban-set-sprint)
    ("k" "delete card"     simply-kanban-delete)]
   ["Clock"
    ("i" "clock in"        simply-kanban-clock-in)
    ("o" "clock out"       simply-kanban-clock-out)]
   ["Reveal"
    ("RET" "reveal heading" simply-kanban-goto)
    ("e" "expand card"      simply-kanban-toggle-expand :transient t)
    ("E" "expand all"       simply-kanban-toggle-expand-all :transient t)
    ("L" "show logbook"     simply-kanban-toggle-logbook :transient t)
    ("c" "compact cards"    simply-kanban-toggle-compact :transient t)
    ("v" "show stories"     simply-kanban-toggle-stories :transient t)
    ("F" "follow mode"      simply-kanban-toggle-follow :transient t)]
   ["Board"
    ("t" "filter by tag"    simply-kanban-set-tag-filter)
    ("T" "clear tag filter" simply-kanban-clear-tag-filter :transient t)
    ("S" "filter by sprint" simply-kanban-set-sprint-filter)
    ("C" "clear sprint filter" simply-kanban-clear-sprint-filter :transient t)
    ("B" "switch board"     simply-kanban-switch-board)
    ("l" "title length"     simply-kanban-set-title-length)
    ("g" "refresh"          simply-kanban-refresh :transient t)
    ("q" "quit board"       quit-window)]])

(defun simply-kanban--open (spec)
  "Build and display the kanban board for SPEC, returning its buffer.
Reuses an existing board for SPEC, or creates a buffer named after the
board's source.  The buffer is displayed before rendering so columns size
to the window."
  (let ((buffer (or (simply-kanban--find-board spec)
                    (get-buffer-create
                     (generate-new-buffer-name
                      (simply-kanban--spec-buffer-name spec))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'simply-kanban-mode)
        (simply-kanban-mode))
      (setq simply-kanban--sprint-filter
            (and simply-kanban-default-sprint
                 (string-trim (format "%s" simply-kanban-default-sprint)))
            simply-kanban--title-length simply-kanban-max-title-length
            simply-kanban--compact-cards simply-kanban-compact-cards
            simply-kanban--show-stories simply-kanban-show-stories))
    (pop-to-buffer buffer)
    (simply-kanban--render spec)
    buffer))

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
          (let ((existing (simply-kanban--find-board (cdr choice))))
            (if (and existing (not (eq existing (current-buffer))))
                (pop-to-buffer existing)
              (setq simply-kanban--source-spec (cdr choice)
                    simply-kanban--tag-filter nil
                    simply-kanban--expanded-cards nil)
              (simply-kanban-refresh)
              (let ((name (simply-kanban--spec-buffer-name
                           simply-kanban--source-spec)))
                (unless (string= name (buffer-name))
                  (rename-buffer name t)))
              (message "Board: %s" (car choice)))))))))

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

;;; Sprint summary

(defun simply-kanban--format-org-table (rows)
  "Return ROWS as an aligned Org table with a header separator."
  (let ((text (orgtbl-to-orgtbl rows nil)))
    (with-temp-buffer
      (org-mode)
      (insert text)
      (goto-char (point-min))
      (org-table-insert-hline)
      (org-table-align)
      (buffer-string))))

(defun simply-kanban--sprint-summary-entry ()
  "Return a sprint summary data row for the heading at point, or nil."
  (let ((sprint (simply-kanban--read-sprint))
        (state (org-get-todo-state)))
    (when (and state sprint)
      (let* ((effort (simply-kanban--effort-minutes
                      (org-entry-get nil "Effort" t)))
             (points (or (simply-kanban--story-points) 0))
             (done (and (member state org-done-keywords) t))
             (clocked (simply-kanban--clocked-minutes))
             (burned (if done
                         (or effort 0)
                       (min (or effort 0) clocked))))
        (list sprint
              (or effort 0)
              (if done 1 0)
              clocked
              burned
              points)))))

(defun simply-kanban--sprint-summary-rows (&optional scope)
  "Return sprint summary table rows for SCOPE.
SCOPE is `file' (the default) or `subtree'.  Each row is
\(SPRINT TASKS DONE POINTS PROGRESS ESTIMATE ACTUAL REMAINING)."
  (let ((scope (or scope 'file)))
    (org-with-wide-buffer
     (org-clock-sum)
     (let* ((data
             (delq nil
                   (org-map-entries
                    #'simply-kanban--sprint-summary-entry
                    nil
                    (if (eq scope 'subtree) 'tree 'file))))
            (by-sprint (seq-group-by #'car data)))
       (cons '("Sprint" "Tasks" "Done" "Points" "Progress" "Estimate"
               "Actual" "Remaining")
             (mapcar
              (lambda (entry)
                (let* ((sprint (car entry))
                       (rows (cdr entry))
                       (tasks (length rows))
                       (done (cl-reduce #'+ rows :key #'cl-third :initial-value 0))
                       (effort (cl-reduce #'+ rows :key #'cl-second :initial-value 0))
                       (clocked (cl-reduce #'+ rows :key #'cl-fourth :initial-value 0))
                       (burned (cl-reduce #'+ rows :key #'cl-fifth :initial-value 0))
                       (points (cl-reduce #'+ rows :key #'cl-sixth :initial-value 0)))
                  (list sprint tasks done
                        (simply-kanban--format-points points)
                        (format "%d%%"
                                (if (zerop effort) 0
                                  (round (* 100.0 (/ burned (float effort))))))
                        (simply-kanban--format-jira-duration effort)
                        (simply-kanban--format-jira-duration clocked)
                        (simply-kanban--format-jira-duration (- effort burned)))))
              (sort by-sprint
                    (lambda (a b)
                      (simply-kanban--sprint-lessp (car a) (car b))))))))))

;;;###autoload
(defun org-dblock-write:simply-kanban-sprint-summary (params)
  "Write a sprint summary table for the current Org buffer.
PARAMS may contain :scope with value \"file\" (the default) or \"subtree\"."
  (let ((scope (or (plist-get params :scope) "file")))
    (insert
     (simply-kanban--format-org-table
      (simply-kanban--sprint-summary-rows
       (if (member scope '("subtree" subtree)) 'subtree 'file))))))

(provide 'simply-kanban)
;;; simply-kanban.el ends here
