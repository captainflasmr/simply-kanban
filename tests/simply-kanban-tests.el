;;; simply-kanban-tests.el --- Tests for simply-kanban -*- lexical-binding: t; -*-

;; Author: James Dyer <captainflasmr@gmail.com>
;; URL: https://github.com/captainflasmr/simply-kanban

;;; Commentary:

;; ERT suite for `simply-kanban'.  Run in batch with:
;;
;;   make test
;;
;; Tests that need Org's TODO-keyword parsing open a real temporary Org
;; file (via `sk-test-with-org'), because in-buffer `#+TODO:' settings are
;; only parsed when the file is loaded into `org-mode' -- not when text is
;; inserted into an already-initialised buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'simply-kanban)

(defmacro sk-test-with-org (content &rest body)
  "Open an Org file containing CONTENT and run BODY with `src' bound to it."
  (declare (indent 1))
  `(let* ((file (make-temp-file "sk-test" nil ".org" ,content))
          (src (find-file-noselect file)))
     (unwind-protect
         (with-current-buffer src
           (should (derived-mode-p 'org-mode))
           ,@body)
       (with-current-buffer src (set-buffer-modified-p nil))
       (kill-buffer src)
       (delete-file file))))

;;; Pure helpers

(ert-deftest sk-test-pad ()
  "`--pad' pads, truncates, and leaves exact-width strings alone."
  (should (string= (simply-kanban--pad "ab" 5) "ab   "))
  (should (= (string-width (simply-kanban--pad "ab" 5)) 5))
  (should (string= (simply-kanban--pad "abcdef" 4) "abcd"))
  (should (string= (simply-kanban--pad "abcd" 4) "abcd")))

(ert-deftest sk-test-wrap ()
  "`--wrap' returns the line unchanged when short, else wraps to width."
  (should (equal (simply-kanban--wrap "short" 20) '("short")))
  (let ((lines (simply-kanban--wrap "one two three four five six seven" 10)))
    (should (> (length lines) 1))
    (should (cl-every (lambda (l) (<= (string-width l) 10)) lines))))

(ert-deftest sk-test-format-card ()
  "`--format-card' produces box lines of exactly the column width."
  (let* ((task (list :keyword "TODO" :title "Hello world" :priority ?A :tags '("x")))
         (lines (simply-kanban--format-card task 20)))
    (should (cl-every (lambda (l) (= (string-width l) 20)) lines))
    (should (string-prefix-p "┌" (car lines)))
    (should (string-prefix-p "└" (car (last lines))))))

;;; Data collection

(ert-deftest sk-test-source-keywords ()
  "Columns come from the buffer's Org TODO workflow."
  (sk-test-with-org "#+TODO: TODO DOING | DONE\n\n* TODO a\n"
    (should (equal (simply-kanban--source-keywords src)
                   '("TODO" "DOING" "DONE")))))

(ert-deftest sk-test-collect-tasks ()
  "`--collect-tasks' returns one card per TODO heading with its fields."
  (sk-test-with-org (concat "#+TODO: TODO DOING | DONE\n\n"
                            "* TODO [#A] Parser :backend:\n"
                            "* DOING Render\n"
                            "* DONE Scaffold\n"
                            "* Not a task\n")
    (let* ((tasks (simply-kanban--collect-tasks src))
           (first (car tasks)))
      (should (= 3 (length tasks)))           ; the plain heading is excluded
      (should (string= (plist-get first :keyword) "TODO"))
      (should (string= (plist-get first :title) "Parser"))
      (should (equal (plist-get first :priority) ?A))
      (should (member "backend" (plist-get first :tags))))))

;;; Rendering / navigation

(defmacro sk-test-with-board (content &rest body)
  "Build a board for an Org file with CONTENT; bind `src' and `board'.
BODY runs with `board' current."
  (declare (indent 1))
  `(sk-test-with-org ,content
     (let ((board (get-buffer-create "*sk-test-board*")))
       (unwind-protect
           (with-current-buffer board
             (simply-kanban-mode)
             (simply-kanban--render board (cons 'buffer src))
             ,@body)
         (kill-buffer board)))))

(ert-deftest sk-test-anchors-count ()
  "The board has one card anchor per task."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO a\n* TODO b\n* DONE c\n"
    (should (= 3 (length (simply-kanban--anchors))))))

(ert-deftest sk-test-navigation ()
  "Next/previous card move forward and back through anchors."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO a\n* TODO b\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (let ((p1 (point)))
      (simply-kanban-next-card)
      (should (> (point) p1))
      (simply-kanban-prev-card)
      (should (= (point) p1)))))

(ert-deftest sk-test-grid-navigation ()
  "n/p move within a column (rows); f/b move across columns, wrapping."
  (sk-test-with-board "#+TODO: TODO DOING | DONE\n\n* TODO a\n* TODO b\n* DOING c\n* DONE d\n"
    (cl-flet ((coord () (simply-kanban--coord (simply-kanban--grid))))
      (goto-char (point-min))
      (simply-kanban-next-card)
      (should (equal (coord) '(0 . 0)))   ; first TODO card
      (simply-kanban-next-card)
      (should (equal (coord) '(0 . 1)))   ; n -> down the TODO column
      (simply-kanban-next-column)
      (should (equal (coord) '(1 . 0)))   ; f -> DOING column (row clamped)
      (simply-kanban-next-column)
      (should (equal (coord) '(2 . 0)))   ; f -> DONE column
      (simply-kanban-next-column)
      (should (equal (coord) '(0 . 0)))   ; f wraps back to TODO
      (simply-kanban-prev-card)
      (should (equal (coord) '(0 . 0))))))  ; p at top is a no-op

(ert-deftest sk-test-highlight-follows-point ()
  "Navigating cards moves the highlight onto the new card."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO a\n* TODO b\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (let ((card1 simply-kanban--current-card))
      (should card1)
      (should simply-kanban--highlight-overlays)
      (simply-kanban-next-card)
      (should-not (eq simply-kanban--current-card card1))   ; moved to a new card
      (should simply-kanban--highlight-overlays))))

;;; Window fitting

(ert-deftest sk-test-available-width-tracks-window ()
  "`--available-width' reflects the width of the board's window."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO a\n"
    (set-window-buffer (selected-window) (current-buffer))
    (should (= (simply-kanban--available-width)
               (max 20 (window-width (selected-window)))))))

(ert-deftest sk-test-column-width-fills-width ()
  "Columns divide the available width (minus gaps) between them."
  (let ((simply-kanban-min-column-width 10)
        (simply-kanban-column-gap 2))
    (cl-letf (((symbol-function 'simply-kanban--available-width)
               (lambda () 100)))
      ;; 4 columns, 3 gaps of 2 => (100 - 6) / 4 = 23.
      (should (= (simply-kanban--column-width 4) 23))
      ;; Narrow window clamps to the configured minimum.
      (should (= (simply-kanban--column-width 20) 10)))))

(ert-deftest sk-test-refresh-preserves-card ()
  "Refresh (e.g. on resize) keeps the same heading selected."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO a\n* TODO b\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (simply-kanban-next-card)            ; on the second card
    (let ((card (simply-kanban--marker-at-point)))
      (should card)
      (simply-kanban-refresh)
      (let ((now (simply-kanban--marker-at-point)))
        (should now)
        (should (eq (marker-buffer now) (marker-buffer card)))
        (should (= (marker-position now) (marker-position card)))))))

;;; Moving cards (write-back to Org)

(ert-deftest sk-test-set-state-changes-org ()
  "`--set-state' rewrites the heading's TODO keyword in the Org buffer."
  (sk-test-with-org "#+TODO: TODO DOING | DONE\n\n* TODO Parser\n"
    (let ((marker (plist-get (car (simply-kanban--collect-tasks src)) :marker)))
      (simply-kanban--set-state marker "DOING")
      (goto-char (point-min))
      (re-search-forward "Parser")
      (org-back-to-heading t)
      (should (string= (org-get-todo-state) "DOING")))))

(ert-deftest sk-test-advance-card ()
  "Advancing a card changes its Org state and moves it a column over."
  (sk-test-with-board "#+TODO: TODO DOING | DONE\n\n* TODO Parser\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (should (string= (simply-kanban--column-at-point) "TODO"))
    (simply-kanban-advance)
    ;; The Org buffer was updated...
    (with-current-buffer src
      (goto-char (point-min))
      (re-search-forward "Parser")
      (org-back-to-heading t)
      (should (string= (org-get-todo-state) "DOING")))
    ;; ...and the board re-rendered with the card now in the DOING column.
    (should (string= (simply-kanban--column-at-point) "DOING"))))

;;; Auto-refresh

(ert-deftest sk-test-auto-refresh-on-save ()
  "Saving the source Org buffer refreshes the board (`auto-refresh' on)."
  (sk-test-with-org "#+TODO: TODO | DONE\n\n* TODO a\n"
    (let ((simply-kanban-auto-refresh t)
          (simply-kanban-buffer-name "*sk-auto-test*"))
      (unwind-protect
          (progn
            (with-current-buffer src (simply-kanban))
            (let ((board (get-buffer "*sk-auto-test*")))
              (should board)
              (with-current-buffer board
                (should (= 1 (length (simply-kanban--anchors)))))
              ;; Add a task to the source and save it.
              (with-current-buffer src
                (goto-char (point-max))
                (insert "* TODO b\n")
                (save-buffer))
              ;; The board picked it up via the source's after-save hook.
              (with-current-buffer board
                (should (= 2 (length (simply-kanban--anchors)))))))
        (when (get-buffer "*sk-auto-test*")
          (kill-buffer "*sk-auto-test*"))))))

;;; Multi-file / agenda boards

(defun sk-test--cleanup-files (&rest files)
  "Kill any buffers visiting FILES and delete them."
  (dolist (f files)
    (let ((b (find-buffer-visiting f)))
      (when b
        (with-current-buffer b (set-buffer-modified-p nil))
        (kill-buffer b)))
    (when (file-exists-p f) (delete-file f))))

(ert-deftest sk-test-multi-file-aggregation ()
  "A files-spec board aggregates tasks and merges columns across files."
  (let ((f1 (make-temp-file "sk-a" nil ".org"
                            "#+TODO: TODO DOING | DONE\n\n* TODO Alpha\n* DOING Beta\n"))
        (f2 (make-temp-file "sk-b" nil ".org"
                            "#+TODO: TODO DONE\n\n* TODO Gamma\n"))
        (board (get-buffer-create "*sk-multi*")))
    (unwind-protect
        (with-current-buffer board
          (simply-kanban-mode)
          (simply-kanban--render board (list 'files f1 f2))
          (should (= 3 (length (simply-kanban--anchors))))
          ;; DOING comes only from f1, but the union keeps a column for it.
          (should (equal simply-kanban--keywords '("TODO" "DOING" "DONE")))
          ;; Multi-file boards label each card with its source file.
          (should (string-match-p (regexp-quote (file-name-nondirectory f1))
                                  (substring-no-properties (buffer-string)))))
      (kill-buffer board)
      (sk-test--cleanup-files f1 f2))))

(ert-deftest sk-test-multi-file-move-writes-correct-file ()
  "Advancing a card writes back to that card's own file only."
  (let ((f1 (make-temp-file "sk-a" nil ".org"
                            "#+TODO: TODO DOING | DONE\n\n* TODO Alpha\n"))
        (f2 (make-temp-file "sk-b" nil ".org"
                            "#+TODO: TODO DOING | DONE\n\n* TODO Beta\n"))
        (board (get-buffer-create "*sk-multi2*")))
    (unwind-protect
        (progn
          (with-current-buffer board
            (simply-kanban-mode)
            (simply-kanban--render board (list 'files f1 f2))
            ;; Two TODO cards stacked: Alpha (f1) then Beta (f2); advance Beta.
            (goto-char (car (nth 1 (simply-kanban--anchors))))
            (simply-kanban-advance))
          (with-current-buffer (find-file-noselect f2)
            (goto-char (point-min)) (re-search-forward "Beta") (org-back-to-heading t)
            (should (string= (org-get-todo-state) "DOING")))
          (with-current-buffer (find-file-noselect f1)
            (goto-char (point-min)) (re-search-forward "Alpha") (org-back-to-heading t)
            (should (string= (org-get-todo-state) "TODO"))))
      (kill-buffer board)
      (sk-test--cleanup-files f1 f2))))

;;; Keymap wiring

(ert-deftest sk-test-keymap ()
  "The board keymap binds the core commands, aligned with simply-annotate."
  (should (keymapp simply-kanban-mode-map))
  (should (eq (lookup-key simply-kanban-mode-map (kbd "RET")) 'simply-kanban-goto))
  (should (eq (lookup-key simply-kanban-mode-map "}") 'simply-kanban-advance))
  (should (eq (lookup-key simply-kanban-mode-map "{") 'simply-kanban-retreat))
  (should (eq (lookup-key simply-kanban-mode-map "s") 'simply-kanban-set-status))
  (should (eq (lookup-key simply-kanban-mode-map "F") 'simply-kanban-toggle-follow))
  (should (eq (lookup-key simply-kanban-mode-map "n") 'simply-kanban-next-card)))

;;; Dynamic column width

(ert-deftest sk-test-column-width ()
  "Columns fill the available width but never drop below the minimum."
  (let ((simply-kanban-min-column-width 24)
        (simply-kanban-column-gap 2))
    ;; Many columns -> clamped to the minimum.
    (should (= (simply-kanban--column-width 20) 24))
    ;; A couple of columns -> wider than the minimum on a normal frame.
    (should (>= (simply-kanban--column-width 2) 24))))

(ert-deftest sk-test-set-status ()
  "`simply-kanban-set-status' writes the chosen keyword back to Org."
  (sk-test-with-board "#+TODO: TODO DOING | DONE\n\n* TODO Parser\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "DONE")))
      (simply-kanban-set-status))
    (with-current-buffer src
      (goto-char (point-min))
      (re-search-forward "Parser")
      (org-back-to-heading t)
      (should (string= (org-get-todo-state) "DONE")))))

(provide 'simply-kanban-tests)
;;; simply-kanban-tests.el ends here
