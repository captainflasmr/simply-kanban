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

(ert-deftest sk-test-collect-ticket-types ()
  "`--collect-tasks' identifies stories, tasks, parents, and child counts."
  (sk-test-with-org (concat "#+TODO: TODO DOING | DONE\n\n"
                            "* TODO Epic\n"
                            ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                            "** TODO Child one\n"
                            "** DONE Child two\n"
                            "* TODO Leaf\n")
    (let* ((tasks (simply-kanban--collect-tasks src))
           (story (seq-find (lambda (tk) (string= "Epic" (plist-get tk :title)))
                            tasks))
           (child (seq-find (lambda (tk) (string= "Child one" (plist-get tk :title)))
                            tasks))
           (leaf (seq-find (lambda (tk) (string= "Leaf" (plist-get tk :title)))
                           tasks)))
      (should (eq 'story (plist-get story :type)))
      (should (= 2 (plist-get story :children)))
      (should (= 1 (plist-get story :children-done)))
      (should (= 2 (length (plist-get story :child-tasks))))
      (should (equal '("Child one" "Child two")
                     (mapcar (lambda (ct) (plist-get ct :title))
                             (plist-get story :child-tasks))))
      (should (eq t (plist-get (nth 1 (plist-get story :child-tasks)) :done)))
      (should-not (plist-get story :parent))
      (should (eq 'task (plist-get child :type)))
      (should (string= "Epic" (plist-get child :parent)))
      (should (zerop (plist-get child :children)))
      (should (eq 'task (plist-get leaf :type)))
      (should-not (plist-get leaf :parent)))))

(ert-deftest sk-test-jira-number ()
  "`--jira-number' parses an issue key at the start of a title."
  (should (string= "MM-1472" (simply-kanban--jira-number "MM-1472 Scenario")))
  (should-not (simply-kanban--jira-number "Scenario MM-1472"))
  (should-not (simply-kanban--jira-number "No number")))

(ert-deftest sk-test-bold-jira-number ()
  "`--bold-jira-number' adds the Jira face to the key only."
  (let* ((text (simply-kanban--bold-jira-number "MM-1472 Scenario"))
         (face (get-text-property 0 'face text)))
    (should (memq 'simply-kanban-jira
                  (if (listp face) face (list face)))))
  (should (string= "No number"
                   (simply-kanban--bold-jira-number "No number"))))

(ert-deftest sk-test-format-card-bold-jira ()
  "A card title shows its Jira number in bold."
  (let* ((lines (simply-kanban--format-card
                 (list :keyword "TODO" :title "MM-1472 Scenario")
                 40))
         (line (cl-find-if (lambda (l) (string-match-p "MM-1472" l))
                           lines)))
    (should line)
    (let ((face (get-text-property (string-match "MM-1472" line) 'face line)))
      (should (memq 'simply-kanban-jira
                    (if (listp face) face (list face)))))))

(ert-deftest sk-test-collect-jira-numbers ()
  "Cards carry their own and their parent's parsed Jira numbers."
  (sk-test-with-org (concat "#+TODO: TODO | DONE\n\n"
                            "* TODO MM-100 Story\n"
                            "** TODO MM-101 Task\n")
    (let* ((tasks (simply-kanban--collect-tasks src))
           (story (seq-find (lambda (tk) (string= "MM-100 Story"
                                                  (plist-get tk :title)))
                            tasks))
           (task (seq-find (lambda (tk) (string= "MM-101 Task"
                                                 (plist-get tk :title)))
                           tasks)))
      (should (string= "MM-100" (plist-get story :jira)))
      (should (string= "MM-101" (plist-get task :jira)))
      (should (string= "MM-100" (plist-get task :parent-jira)))
      (let ((child (car (plist-get story :child-tasks))))
        (should (string= "MM-101 Task" (plist-get child :title)))
        (should (string= "MM-101" (plist-get child :jira)))))))

(ert-deftest sk-test-ticket-type-property ()
  "A childless `TICKET_TYPE: STORY' heading is still a story."
  (sk-test-with-org (concat "#+TODO: TODO | DONE\n\n"
                            "* TODO Solo story\n"
                            ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                            "* TODO Leaf\n")
    (let ((tasks (simply-kanban--collect-tasks src)))
      (should (eq 'story (plist-get (cl-first tasks) :type)))
      (should (eq 'task (plist-get (cl-second tasks) :type))))))

(ert-deftest sk-test-non-todo-heading-not-shown ()
  "A non-TODO heading is not a card and does not label a parent."
  (sk-test-with-org (concat "#+TODO: TODO | DONE\n\n"
                            "* Story\n"
                            ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                            "** TODO Child\n")
    (let ((tasks (simply-kanban--collect-tasks src)))
      (should (= 1 (length tasks)))
      (should-not (plist-get (car tasks) :parent)))))

(ert-deftest sk-test-stories-only-top-level ()
  "Only the shallowest TODO heading can be a story."
  (sk-test-with-org (concat "#+TODO: TODO | DONE\n\n"
                            "* TODO Root\n"
                            "** TODO Nested\n"
                            ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                            "*** TODO Grandchild\n")
    (let* ((tasks (simply-kanban--collect-tasks src))
           (root (seq-find (lambda (tk) (string= "Root" (plist-get tk :title)))
                           tasks))
           (nested (seq-find (lambda (tk) (string= "Nested" (plist-get tk :title)))
                             tasks))
           (grandchild (seq-find (lambda (tk) (string= "Grandchild"
                                                       (plist-get tk :title)))
                                 tasks)))
      (should (eq 'story (plist-get root :type)))
      (should (eq 'task (plist-get nested :type)))
      (should (eq 'task (plist-get grandchild :type)))
      (should (= 2 (plist-get root :children)))
      (should (= 1 (plist-get nested :children))))))

(ert-deftest sk-test-format-card-ticket-relations ()
  "Tickets show their type, parent story, and child count."
  (let* ((simply-kanban--compact-cards nil)
         (story (simply-kanban--format-card
                 (list :keyword "TODO" :title "Epic" :type 'story
                       :children 3 :children-done 1)
                 60))
         (task (simply-kanban--format-card
                (list :keyword "TODO" :title "Leaf" :type 'task
                      :parent "Epic")
                60)))
    (should (cl-some (lambda (l) (string-match-p "STORY" l)) story))
    (should (cl-some (lambda (l) (string-match-p "parent of 3 children (1 done)" l))
                     story))
    (should (cl-some (lambda (l) (string-match-p "TASK" l)) task))
    (should (cl-some (lambda (l) (string-match-p "child of Epic" l)) task)))
  (let* ((simply-kanban--compact-cards t)
         (task (simply-kanban--format-card
                (list :keyword "TODO" :title "MM-2 Leaf" :type 'task
                      :parent "Some other story" :parent-jira "MM-1")
                60)))
    (should (cl-some (lambda (l) (string-match-p "TASK parent MM-1" l)) task))))

(ert-deftest sk-test-ticket-relations-hidden ()
  "`simply-kanban-show-ticket-types' hides the relationship line."
  (let* ((simply-kanban-show-ticket-types nil)
         (lines (simply-kanban--format-card
                 (list :keyword "TODO" :title "Leaf" :type 'task
                       :parent "Epic")
                 60)))
    (should-not (cl-some (lambda (l) (string-match-p "TASK" l)) lines))
    (should-not (cl-some (lambda (l) (string-match-p "child of Epic" l)) lines))))

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

(ert-deftest sk-test-collect-effort ()
  "`--collect-tasks' reads the heading's Effort property into `:effort'."
  (sk-test-with-org (concat "#+TODO: TODO | DONE\n\n"
                            "* TODO Parser\n"
                            ":PROPERTIES:\n:Effort:   2:00\n:END:\n"
                            "* TODO Render\n")
    (let ((tasks (simply-kanban--collect-tasks src)))
      (should (string= (plist-get (car tasks) :effort) "2:00"))
      (should (null (plist-get (cadr tasks) :effort))))))

(ert-deftest sk-test-column-effort ()
  "`--column-effort' sums the cards' efforts as a duration, nil when none set."
  (should (string= (simply-kanban--column-effort
                    (list (list :effort "1:30") (list :effort "0:30")
                          (list :effort nil)))
                   "2:00"))
  (should (null (simply-kanban--column-effort
                 (list (list :effort nil) (list :effort ""))))))

(ert-deftest sk-test-format-card-shows-effort ()
  "A card with an effort renders a badge line; one without does not."
  (let ((simply-kanban--compact-cards nil))
    (let ((with (simply-kanban--format-card
                 (list :keyword "TODO" :title "x" :effort "1:00") 20))
          (without (simply-kanban--format-card
                    (list :keyword "TODO" :title "x") 20)))
      (should (cl-some (lambda (l) (string-match-p "1:00" l)) with))
      (should-not (cl-some (lambda (l) (string-match-p "1:00" l)) without)))))

(ert-deftest sk-test-fit-line ()
  "`--fit-line' leaves fitting text alone and truncates the rest."
  (should (string= "abc" (simply-kanban--fit-line "abc" 5)))
  (let ((line (simply-kanban--fit-line "abcdef" 5)))
    (should (= 5 (string-width line)))
    (should (string-suffix-p "…" line))))

(ert-deftest sk-test-format-card-compact ()
  "Compact cards place unlabelled metrics on a single line."
  (let ((lines (simply-kanban--format-card
                (list :keyword "TODO" :title "x" :effort "2:00"
                      :points 5 :clocked 60 :remaining 90)
                30)))
    (should (cl-some (lambda (l)
                       (string-match-p
                        (regexp-quote "1h:30m") l))
                     lines))
    (should-not (cl-some (lambda (l) (string-match-p "2:00" l)) lines))
    (should-not (cl-some (lambda (l) (string-match-p " 5" l)) lines))
    (should-not (cl-some (lambda (l) (string-match-p "Effort:" l)) lines))
    (should-not (cl-some (lambda (l) (string-match-p "Points:" l)) lines))
    (should-not (cl-some (lambda (l) (string-match-p "Clocked:" l)) lines))
    (should-not (cl-some (lambda (l) (string-match-p "Remaining:" l))
                         lines))))

(ert-deftest sk-test-format-card-compact-durations ()
  "Compact cards render remaining time with colons but omit clocked time."
  (let ((org-duration-units '(("min" . 1) ("h" . 60) ("d" . 444))))
    (let* ((lines (simply-kanban--format-card
                   (list :keyword "TODO" :title "x" :clocked 527
                         :remaining 527)
                   40))
           (meta (cl-find-if (lambda (l) (string-match-p "1d:1h:23m" l))
                             lines)))
      (should meta)
      (should (string-match-p "1d:1h:23m" meta))
      (should-not (string-match-p "1d:1h:23m 1d:1h:23m" meta)))))

(ert-deftest sk-test-format-card-compact-context ()
  "Compact cards keep sprint, tags, board, and file in the metadata line."
  (let ((simply-kanban--show-board t)
        (simply-kanban--multi-source t))
    (let* ((lines (simply-kanban--format-card
                   (list :keyword "TODO" :title "x" :tags '("backend")
                         :sprint "Sprint 2" :board "Project Alpha"
                         :file "tasks.org")
                   80))
           (meta (cl-find-if (lambda (l) (string-match-p ":backend:" l))
                             lines)))
      (should meta)
      (should (string-match-p "Sprint 2" meta))
      (should-not (string-match-p "Sprint:" meta))
      (should (string-match-p "Project Alpha" meta))
      (should (string-match-p "tasks.org" meta)))))

(ert-deftest sk-test-compact-cards-default-and-toggle ()
  "Cards start compact and `simply-kanban-toggle-compact' shows full badges."
  (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                              "* TODO Alpha\n"
                              ":PROPERTIES:\n:Effort:   2:00\n:END:\n")
    (should simply-kanban--compact-cards)
    (should-not (string-match-p "│ 2:00" (buffer-string)))
    (should-not (string-match-p "Effort:" (buffer-string)))
    (simply-kanban-toggle-compact)
    (should-not simply-kanban--compact-cards)
    (should (string-match-p "Effort: 2:00" (buffer-string)))))

(ert-deftest sk-test-compact-cards-option-on-open ()
  "`simply-kanban-compact-cards' chooses the layout when a board opens."
  (sk-test-with-org (concat "#+TODO: TODO | DONE\n\n"
                            "* TODO Alpha\n"
                            ":PROPERTIES:\n:Effort:   2:00\n:END:\n")
    (dolist (option '(nil t))
      (let ((simply-kanban-compact-cards option)
            (simply-kanban-buffer-name "*sk-test-compact-option*")
            board)
        (unwind-protect
            (progn
              (setq board (simply-kanban--open (cons 'buffer src)))
              (with-current-buffer board
                (should (eq option simply-kanban--compact-cards))
                (should (eq (not option)
                            (and (string-match-p "Effort:" (buffer-string)) t)))))
          (when (buffer-live-p board)
            (kill-buffer board)))))))

(ert-deftest sk-test-format-points ()
  "Story points render without a redundant trailing .0."
  (should (equal "3" (simply-kanban--format-points 3)))
  (should (equal "3" (simply-kanban--format-points 3.0)))
  (should (equal "3.5" (simply-kanban--format-points 3.5))))

(ert-deftest sk-test-collect-story-points ()
  "`--collect-tasks' reads STORY_POINTS as a number, ignoring invalid text."
  (sk-test-with-org (concat "* TODO Alpha\n:PROPERTIES:\n:STORY_POINTS: 5\n:END:\n"
                            "* TODO Beta\n:PROPERTIES:\n:STORY_POINTS: 3.5\n:END:\n"
                            "* TODO Gamma\n:PROPERTIES:\n:STORY_POINTS: many\n:END:\n")
    (let ((tasks (simply-kanban--collect-tasks src)))
      (should (= 5 (plist-get (car tasks) :points)))
      (should (= 3.5 (plist-get (cadr tasks) :points)))
      (should (null (plist-get (nth 2 tasks) :points))))))

(ert-deftest sk-test-column-points ()
  "`--column-points' sums the cards' story points, nil when none are set."
  (should (equal "8.5"
                 (simply-kanban--column-points
                  (list (list :points 5) (list :points 3.5)
                        (list :points nil)))))
  (should (equal "0" (simply-kanban--column-points
                      (list (list :points 0)))))
  (should (null (simply-kanban--column-points
                 (list (list :points nil))))))

(ert-deftest sk-test-format-card-shows-points ()
  "Story points appear in detailed cards; compact cards omit them."
  (let ((simply-kanban-show-story-points t)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :points 5) 24)))
      (should (cl-some (lambda (l) (string-match-p "Points: 5" l)) lines)))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x") 24)))
      (should-not (cl-some (lambda (l) (string-match-p "Points:" l)) lines))))
  (let ((simply-kanban-show-story-points t)
        (simply-kanban--compact-cards t))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :points 5) 24)))
      (should-not (cl-some (lambda (l) (string-match-p "Points:" l)) lines))
      (should-not (cl-some (lambda (l) (string-match-p " 5" l)) lines))))
  (let ((simply-kanban-show-story-points nil)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :points 5) 24)))
      (should-not (cl-some (lambda (l) (string-match-p "Points:" l)) lines)))))

(ert-deftest sk-test-collect-clocked ()
  "`--collect-tasks' reads clock entries into `:clocked' as minutes."
  (sk-test-with-org (concat "* TODO Parser\n"
                            ":LOGBOOK:\n"
                            "CLOCK: [2024-01-01 Mon 09:00]--[2024-01-01 Mon 10:00] =>  1:00\n"
                            ":END:\n"
                            "* TODO Render\n")
    (let ((tasks (simply-kanban--collect-tasks src)))
      (should (= 60 (plist-get (car tasks) :clocked)))
      (should (= 0 (plist-get (cadr tasks) :clocked))))))

(ert-deftest sk-test-column-clock ()
  "`--column-clock' sums the cards' clocked minutes as a duration."
  (should (string= (simply-kanban--column-clock
                    (list (list :clocked 90) (list :clocked 30)
                          (list :clocked nil)))
                   "2:00"))
  (should (null (simply-kanban--column-clock
                 (list (list :clocked 0) (list :clocked nil))))))

(ert-deftest sk-test-format-card-shows-clock ()
  "A card with clocked time renders a badge; a running clock is marked."
  (let ((simply-kanban-show-clock t)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :clocked 90) 24)))
      (should (cl-some (lambda (l) (string-match-p "Clocked: 1:30" l)) lines)))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :clocked 90 :clocking t) 28)))
      (should (cl-some (lambda (l) (string-match-p "Clocked: 1:30 (run)" l))
                       lines))))
  (let ((simply-kanban-show-clock nil)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :clocked 90) 24)))
      (should-not (cl-some (lambda (l) (string-match-p "Clocked:" l)) lines))))
  (let ((simply-kanban-show-clock t)
        (simply-kanban--compact-cards t))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :clocked 90 :clocking t)
                  24)))
      (should-not (cl-some (lambda (l) (string-match-p "1:30" l)) lines))
      (should-not (cl-some (lambda (l) (string-match-p "(run)" l)) lines)))))

(ert-deftest sk-test-remaining-minutes ()
  "`--remaining-minutes' subtracts clocked time from the effort estimate."
  (should (= 540 (simply-kanban--remaining-minutes "12:00" 180 nil)))
  (should (= 0 (simply-kanban--remaining-minutes "12:00" 900 nil)))
  (should (= 0 (simply-kanban--remaining-minutes "12:00" 0 t)))
  (should (null (simply-kanban--remaining-minutes nil 60 nil))))

(ert-deftest sk-test-over-minutes ()
  "`--over-minutes' reports clocked time beyond the effort estimate."
  (should (= 180 (simply-kanban--over-minutes "12:00" 900)))
  (should (= 0 (simply-kanban--over-minutes "12:00" 180)))
  (should (= 60 (simply-kanban--over-minutes "1:00" 120)))
  (should (null (simply-kanban--over-minutes nil 60))))

(ert-deftest sk-test-collect-over ()
  "`--collect-tasks' computes over-budget minutes from clock entries."
  (sk-test-with-org (concat "* TODO Parser\n"
                            ":PROPERTIES:\n:Effort:   1:00\n:END:\n"
                            ":LOGBOOK:\n"
                            "CLOCK: [2024-01-01 Mon 09:00]--[2024-01-01 Mon 10:30] =>  1:30\n"
                            ":END:\n")
    (let ((task (car (simply-kanban--collect-tasks src))))
      (should (= 30 (plist-get task :over)))
      (should (= 0 (plist-get task :remaining))))))

(ert-deftest sk-test-column-over ()
  "`--column-over' sums the cards' over-budget minutes as a duration."
  (should (string= (simply-kanban--column-over
                    (list (list :over 90) (list :over 30)
                          (list :over nil)))
                   "2h"))
  (should (null (simply-kanban--column-over
                 (list (list :over 0) (list :over nil))))))

(ert-deftest sk-test-format-card-shows-over ()
  "An over-budget card shows an Over badge instead of Remaining."
  (let ((simply-kanban-show-remaining t)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :clocked 90
                        :over 30 :remaining 0) 24)))
      (should (cl-some (lambda (l) (string-match-p "Over: 30m" l)) lines))
      (should-not (cl-some (lambda (l) (string-match-p "Remaining:" l))
                           lines))))
  (let ((simply-kanban-show-remaining nil)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :clocked 90
                        :over 30 :remaining 0) 24)))
      (should-not (cl-some (lambda (l) (string-match-p "Over:" l))
                           lines)))))

(ert-deftest sk-test-entry-body-excludes-logbook ()
  "Expanded body keeps notes and prose but drops LOGBOOK entries."
  (sk-test-with-org (concat "* TODO Parser\n"
                            ":PROPERTIES:\n:Effort:   1:00\n:END:\n"
                            "- Note taken on [2024-01-01 Mon 09:00] \\\\\n"
                            "  a useful note\n"
                            ":LOGBOOK:\n"
                            "CLOCK: [2024-01-01 Mon 09:00]--[2024-01-01 Mon 10:00] =>  1:00\n"
                            ":END:\n"
                            "\n"
                            "Parser body.\n")
    (let ((body (simply-kanban--entry-body)))
      (should (string-match-p "a useful note" body))
      (should (string-match-p "Parser body" body))
      (should-not (string-match-p "CLOCK:" body))
      (should-not (string-match-p ":LOGBOOK:" body)))))

(ert-deftest sk-test-entry-logbook ()
  "`--entry-logbook' returns the LOGBOOK drawer contents."
  (sk-test-with-org (concat "* TODO Parser\n"
                            ":LOGBOOK:\n"
                            "CLOCK: [2024-01-01 Mon 09:00]--[2024-01-01 Mon 10:00] =>  1:00\n"
                            ":END:\n")
    (should (string= (simply-kanban--entry-logbook)
                     "CLOCK: [2024-01-01 Mon 09:00]--[2024-01-01 Mon 10:00] =>  1:00"))))

(ert-deftest sk-test-collect-logbook ()
  "`--collect-tasks' reads the LOGBOOK drawer into `:logbook'."
  (sk-test-with-org (concat "* TODO Parser\n"
                            ":LOGBOOK:\n"
                            "CLOCK: [2024-01-01 Mon 09:00]--[2024-01-01 Mon 10:00] =>  1:00\n"
                            ":END:\n")
    (let ((task (car (simply-kanban--collect-tasks src))))
      (should (string-match-p "CLOCK:" (plist-get task :logbook))))))

(ert-deftest sk-test-toggle-logbook ()
  "`L' shows and hides the card's LOGBOOK drawer on the board."
  (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                              "* TODO Alpha\n"
                              ":LOGBOOK:\n"
                              "CLOCK: [2024-01-01 Mon 09:00]--[2024-01-01 Mon 10:00] =>  1:00\n"
                              ":END:\n")
    (goto-char (point-min))
    (simply-kanban-next-card)
    (simply-kanban-toggle-logbook)
    (should (string-match-p "Logbook" (buffer-string)))
    (should (string-match-p "CLOCK:" (buffer-string)))
    (simply-kanban-toggle-logbook)
    (should-not (string-match-p "CLOCK:" (buffer-string)))))

(ert-deftest sk-test-add-note-setup ()
  "`simply-kanban-add-note' sets up an Org note for the card at point."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (unwind-protect
        (progn
          (simply-kanban-add-note)
          (should (eq org-log-note-purpose 'note))
          (should (eq (marker-buffer org-log-note-marker) src))
          (should (eq simply-kanban--note-board board))
          (should (simply-kanban--same-card-p
                   simply-kanban--note-card
                   (simply-kanban--marker-at-point))))
      (setq org-log-note-purpose nil
            simply-kanban--note-card nil
            simply-kanban--note-board nil)
      (when (markerp org-log-note-marker)
        (set-marker org-log-note-marker nil))
      (remove-hook 'post-command-hook 'org-add-log-note))))

(ert-deftest sk-test-restore-card-after-note ()
  "Storing a note restores point to the annotated card."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n* TODO Beta\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (simply-kanban-next-card)
    (let ((card (simply-kanban--marker-at-point)))
      (setq simply-kanban--note-card (copy-marker card)
            simply-kanban--note-board (current-buffer))
      (simply-kanban--org-store-log-note-around (lambda (&rest _) nil))
      (should (simply-kanban--same-card-p
               (simply-kanban--marker-at-point) card))
      (should-not simply-kanban--note-card))))

(ert-deftest sk-test-collect-remaining ()
  "`--collect-tasks' computes remaining time from effort and clock entries."
  (sk-test-with-org (concat "* TODO Parser\n"
                            ":PROPERTIES:\n:Effort:   2:00\n:END:\n"
                            ":LOGBOOK:\n"
                            "CLOCK: [2024-01-01 Mon 09:00]--[2024-01-01 Mon 10:00] =>  1:00\n"
                            ":END:\n")
    (let ((task (car (simply-kanban--collect-tasks src))))
      (should (= 60 (plist-get task :remaining)))
      (should-not (plist-get task :done)))))

(ert-deftest sk-test-column-remaining ()
  "`--column-remaining' sums the cards' remaining minutes as a duration."
  (should (string= (simply-kanban--column-remaining
                    (list (list :remaining 90) (list :remaining 30)
                          (list :remaining nil)))
                   "2h"))
  (should (null (simply-kanban--column-remaining
                 (list (list :remaining 0) (list :remaining nil))))))

(ert-deftest sk-test-progress-bar ()
  "`--progress-bar' fills the requested fraction and empties the rest."
  (let ((bar (simply-kanban--progress-bar 0.5 10 'bold)))
    (should (= 10 (string-width bar)))
    (should (= 5 (seq-count (lambda (char) (eq char ?█))
                            (string-to-list bar))))
    (should (= 5 (seq-count (lambda (char) (eq char ?░))
                            (string-to-list bar)))))
  (let ((bar (simply-kanban--progress-bar nil 6 'bold)))
    (should (= 6 (seq-count (lambda (char) (eq char ?░))
                            (string-to-list bar))))))

(ert-deftest sk-test-column-progress ()
  "`--column-progress' burns done and clocked effort against estimates."
  (let ((tasks (list (list :effort "2:00" :clocked 60 :done nil)
                     (list :effort "2:00" :clocked 120 :done nil)
                     (list :effort "4:00" :clocked 0 :done t))))
    ;; Total 8:00 = 480 min; burned 60 + 120 + 240 = 420 => 0.875.
    (should (= 0.875 (simply-kanban--column-progress tasks)))))

(ert-deftest sk-test-column-progress-count-fallback ()
  "`--column-progress' falls back to the done-card count without efforts."
  (let ((tasks (list (list :done t) (list :done nil))))
    (should (= 0.5 (simply-kanban--column-progress tasks)))))

(ert-deftest sk-test-column-progress-renders ()
  "A DONE column with effort renders a filled progress bar."
  (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                              "* DONE Alpha\n"
                              ":PROPERTIES:\n:Effort:   1:00\n:END:\n")
    (goto-char (point-min))
    (should (re-search-forward "█" nil t))
    (goto-char (point-min))
    (should (re-search-forward "░" nil t))))

(ert-deftest sk-test-card-progress ()
  "`--card-progress' burns clocked time against the card's estimate."
  (should (= 1.0 (simply-kanban--card-progress (list :done t))))
  (should (= 0.5 (simply-kanban--card-progress
                  (list :effort "2:00" :clocked 60))))
  (should (= 1.0 (simply-kanban--card-progress
                  (list :effort "2:00" :clocked 300))))
  (should-not (simply-kanban--card-progress
               (list :effort "2:00" :clocked 0)))
  (should-not (simply-kanban--card-progress (list :clocked 60))))

(ert-deftest sk-test-card-progress-renders ()
  "A started card with an effort renders its own progress bar."
  (let ((simply-kanban-show-column-progress nil))
    (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                                "* TODO Alpha\n"
                                ":PROPERTIES:\n:Effort:   2:00\n:END:\n"
                                ":LOGBOOK:\n"
                                "CLOCK: [2024-01-01 Mon 09:00]--[2024-01-01 Mon 10:00] =>  1:00\n"
                                ":END:\n")
      (goto-char (point-min))
      (should (re-search-forward "█" nil t))
      (goto-char (point-min))
      (should (re-search-forward "░" nil t)))))

(ert-deftest sk-test-card-progress-hidden-without-data ()
  "A card with neither an estimate nor DONE state shows no progress bar."
  (let ((simply-kanban-show-column-progress nil))
    (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n"
      (should-not (string-match-p "█" (buffer-string))))))

(ert-deftest sk-test-card-progress-hidden-without-clock ()
  "A card with an estimate but no clocked time shows no empty progress bar."
  (let ((simply-kanban-show-column-progress nil))
    (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                                "* TODO Alpha\n"
                                ":PROPERTIES:\n:Effort:   2:00\n:END:\n")
      (should-not (string-match-p "█" (buffer-string)))
      (should-not (string-match-p "░" (buffer-string))))))

(ert-deftest sk-test-format-jira-duration ()
  "Remaining time renders with Jira-style day/hour/minute units."
  (let ((org-duration-units '(("min" . 1) ("h" . 60) ("d" . 444))))
    (should (string= (simply-kanban--format-jira-duration 666) "1d 3h 42m"))
    (should (string= (simply-kanban--format-jira-duration 444) "1d"))
    (should (string= (simply-kanban--format-jira-duration 42) "42m"))
    (should (string= (simply-kanban--format-jira-duration 0) "0m"))))

(ert-deftest sk-test-format-compact-duration ()
  "Compact durations use colons between units."
  (let ((org-duration-units '(("min" . 1) ("h" . 60) ("d" . 444))))
    (should (string= (simply-kanban--format-compact-duration 527)
                     "1d:1h:23m"))
    (should (string= (simply-kanban--format-compact-duration 90) "1h:30m"))
    (should (string= (simply-kanban--format-compact-duration 42) "42m"))
    (should (string= (simply-kanban--format-compact-duration 0) "0m"))))

(ert-deftest sk-test-board-inherits-duration-units ()
  "A board formats durations with its source buffer's duration units."
  (sk-test-with-org (concat "#+TODO: TODO | DONE\n\n"
                            "* TODO Parser\n"
                            ":PROPERTIES:\n:Effort:   2d\n:END:\n"
                            ":LOGBOOK:\n"
                            "CLOCK: [2024-01-01 Mon 09:00]--[2024-01-01 Mon 09:01] =>  0:01\n"
                            ":END:\n")
    (setq-local org-duration-units '(("min" . 1) ("h" . 60) ("d" . 444)))
    (let ((board (get-buffer-create "*sk-units-board*")))
      (unwind-protect
          (with-current-buffer board
            (simply-kanban-mode)
            (simply-kanban--render (cons 'buffer src))
            (should (string-match-p "1d:7h:23m"
                                    (buffer-string))))
        (kill-buffer board)))))

(ert-deftest sk-test-format-card-shows-remaining ()
  "A started card shows remaining time; an unstarted card does not."
  (let ((simply-kanban-show-remaining t)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :clocked 60
                        :remaining 60) 24)))
      (should (cl-some (lambda (l) (string-match-p "Remaining: 1h" l))
                       lines)))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :remaining 60) 24)))
      (should-not (cl-some (lambda (l) (string-match-p "Remaining:" l))
                           lines))))
  (let ((simply-kanban-show-remaining nil)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :clocked 60
                        :remaining 60) 24)))
      (should-not (cl-some (lambda (l) (string-match-p "Remaining:" l))
                           lines)))))

(ert-deftest sk-test-collect-boards ()
  "`--collect-boards' gathers every board's cards, tagging each with its :board."
  (sk-test-with-org (concat "* Project Alpha\n** TODO design\n** TODO build\n"
                            "* Project Beta\n** TODO research\n")
    (let* ((tasks (simply-kanban--collect-boards src))
           (boards (mapcar (lambda (tk) (plist-get tk :board)) tasks)))
      (should (= 3 (length tasks)))
      (should (member "Project Alpha" boards))
      (should (member "Project Beta" boards))
      ;; the design card belongs to Alpha
      (let ((design (seq-find (lambda (tk) (string= (plist-get tk :title) "design"))
                              tasks)))
        (should (string= (plist-get design :board) "Project Alpha"))))))

(ert-deftest sk-test-file-boards-with-all ()
  "`--file-boards-with-all' prepends an all-boards entry for multi-board files."
  (sk-test-with-org (concat "* Project Alpha\n** TODO design\n"
                            "* Project Beta\n** TODO research\n")
    (let ((boards (simply-kanban--file-boards-with-all src)))
      (should (assoc simply-kanban-all-boards-name boards))
      (should (equal (cdr (assoc simply-kanban-all-boards-name boards))
                     (cons 'all-boards src)))
      ;; the real boards are still present after the aggregate entry
      (should (assoc "Project Alpha" boards))
      (should (assoc "Project Beta" boards)))))

(ert-deftest sk-test-file-boards-with-all-single ()
  "A single-board file gets no all-boards entry."
  (sk-test-with-org "* Project Alpha\n** TODO design\n"
    (let ((boards (simply-kanban--file-boards-with-all src)))
      (should-not (assoc simply-kanban-all-boards-name boards)))))

(ert-deftest sk-test-format-card-shows-board ()
  "When showing all boards, a card renders its board name."
  (let ((simply-kanban--show-board t)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :board "Project Alpha") 24)))
      (should (cl-some (lambda (l) (string-match-p "Project Alpha" l)) lines))))
  ;; ...and not when the flag is off
  (let ((simply-kanban--show-board nil)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :board "Project Alpha") 24)))
      (should-not (cl-some (lambda (l) (string-match-p "Project Alpha" l)) lines)))))

(ert-deftest sk-test-collect-sprint ()
  "`--collect-tasks' reads the heading's SPRINT property into `:sprint'."
  (sk-test-with-org (concat "* TODO Alpha\n:PROPERTIES:\n:SPRINT: Sprint Alpha\n:END:\n"
                            "* TODO Beta\n")
    (let ((tasks (simply-kanban--collect-tasks src)))
      (should (equal "Sprint Alpha" (plist-get (car tasks) :sprint)))
      (should (null (plist-get (cadr tasks) :sprint))))))

(ert-deftest sk-test-sprint-inheritance ()
  "A SPRINT on a parent heading is inherited by its cards."
  (sk-test-with-org (concat "* Project Alpha\n:PROPERTIES:\n:SPRINT: Sprint 5\n:END:\n"
                            "** TODO design\n")
    (let ((tasks (simply-kanban--collect-tasks src)))
      (should (equal "Sprint 5" (plist-get (car tasks) :sprint))))))

(ert-deftest sk-test-sprint-from-heading ()
  "An ancestor heading names a card's sprint when the option is on."
  (sk-test-with-org (concat "* Sprint Alpha\n** TODO one\n"
                            "* Sprint Beta\n** TODO two\n")
    (let ((simply-kanban-sprint-from-heading t))
      (let ((tasks (simply-kanban--collect-tasks src)))
        (should (equal "Sprint Alpha" (plist-get (car tasks) :sprint)))
        (should (equal "Sprint Beta" (plist-get (cadr tasks) :sprint)))))))

(ert-deftest sk-test-sprint-property-beats-heading ()
  "A SPRINT property on the same ancestor beats that heading's text."
  (sk-test-with-org (concat "* Sprint Alpha\n:PROPERTIES:\n"
                            ":SPRINT: Explicit\n:END:\n"
                            "** TODO one\n")
    (let ((simply-kanban-sprint-from-heading t))
      (let ((tasks (simply-kanban--collect-tasks src)))
        (should (equal "Explicit" (plist-get (car tasks) :sprint)))))))

(ert-deftest sk-test-sprint-nearest-heading-wins ()
  "A closer section heading beats a SPRINT property on a higher ancestor."
  (sk-test-with-org (concat "* Issues\n:PROPERTIES:\n:SPRINT: Global\n:END:\n"
                            "** Emacs\n*** TODO one\n")
    (let ((simply-kanban-sprint-from-heading t))
      (let ((tasks (simply-kanban--collect-tasks src)))
        (should (equal "Emacs" (plist-get (car tasks) :sprint)))))))

(ert-deftest sk-test-format-card-shows-sprint ()
  "A card shows its sprint when no sprint filter is active, hidden otherwise."
  (let ((simply-kanban--sprint-filter nil)
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :sprint "Sprint 2") 24)))
      (should (cl-some (lambda (l) (string-match-p "Sprint: Sprint 2" l)) lines))))
  (let ((simply-kanban--sprint-filter "Sprint 2")
        (simply-kanban--compact-cards nil))
    (let ((lines (simply-kanban--format-card
                  (list :keyword "TODO" :title "x" :sprint "Sprint 2") 24)))
      (should-not (cl-some (lambda (l) (string-match-p "Sprint: Sprint 2" l))
                           lines)))))

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
             (simply-kanban--render (cons 'buffer src))
             ,@body)
         (kill-buffer board)))))

(ert-deftest sk-test-anchors-count ()
  "The board has one card anchor per task."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO a\n* TODO b\n* DONE c\n"
    (should (= 3 (length (simply-kanban--anchors))))))

(ert-deftest sk-test-board-ticket-types ()
  "Story and task cards show their type and hierarchy on the board."
  (let ((simply-kanban--show-stories t))
    (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                                "* TODO MM-100 Epic\n"
                                ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                                "** TODO MM-101 Child task\n")
      (should (string-match-p "STORY 1 child" (buffer-string)))
      (should (string-match-p "TASK parent MM-100" (buffer-string)))
      (should (string-match-p "╔" (buffer-string)))
      (should (string-match-p "╗" (buffer-string)))
      (should (string-match-p "║" (buffer-string)))
      (should (string-match-p "╚" (buffer-string)))
      (should (string-match-p "╝" (buffer-string))))))

(ert-deftest sk-test-board-stories-hidden-by-default ()
  "Stories are hidden by default; task cards still name their parent."
  (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                              "* TODO MM-100 Story\n"
                              ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                              "** TODO MM-101 Task\n")
    (should-not (string-match-p "STORY" (buffer-string)))
    (should (string-match-p "TASK parent MM-100" (buffer-string)))))

(ert-deftest sk-test-toggle-stories ()
  "The stories toggle shows and hides story cards on the board."
  (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                              "* TODO MM-100 Story\n"
                              ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                              "** TODO MM-101 Task\n")
    (should-not (string-match-p "STORY" (buffer-string)))
    (simply-kanban-toggle-stories)
    (should simply-kanban--show-stories)
    (should (string-match-p "STORY 1 child" (buffer-string)))
    (simply-kanban-toggle-stories)
    (should-not simply-kanban--show-stories)
    (should-not (string-match-p "STORY" (buffer-string)))))

(ert-deftest sk-test-toggle-tasks ()
  "The tasks toggle can hide task cards while keeping stories."
  (let ((simply-kanban--show-stories t))
    (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                                "* TODO MM-100 Story\n"
                                ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                                "** TODO MM-101 Task\n")
      (should (string-match-p "STORY 1 child" (buffer-string)))
      (should (string-match-p "TASK parent MM-100" (buffer-string)))
      (simply-kanban-toggle-tasks)
      (should-not simply-kanban--show-tasks)
      (should (string-match-p "STORY 1 child" (buffer-string)))
      (should-not (string-match-p "TASK parent MM-100" (buffer-string)))
      (simply-kanban-toggle-tasks)
      (should simply-kanban--show-tasks)
      (should (string-match-p "TASK parent MM-100" (buffer-string))))))

(ert-deftest sk-test-expanded-story-lists-children ()
  "Expanding a story lists all of its children."
  (let ((simply-kanban--show-stories t))
    (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                                "* TODO MM-100 Story\n"
                                ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                                "** TODO MM-101 Child one\n"
                                "** DONE MM-102 Child two\n")
      (goto-char (point-min))
      (simply-kanban-next-card)
      (should-not (string-match-p (regexp-quote "- TODO MM-101")
                                  (buffer-string)))
      (simply-kanban-toggle-expand)
      (should (string-match-p "Children" (buffer-string)))
      (should (string-match-p (regexp-quote "- TODO MM-101 Child one")
                              (buffer-string)))
      (should (string-match-p (regexp-quote "- DONE MM-102 Child two")
                              (buffer-string)))
      (goto-char (point-min))
      (should (re-search-forward "- TODO \\(MM-101\\)" nil t))
      (let ((face (get-text-property (match-beginning 1) 'face)))
        (should (memq 'simply-kanban-jira
                      (if (listp face) face (list face))))))))

(ert-deftest sk-test-stories-option-on-open ()
  "`simply-kanban-show-stories' chooses whether stories appear at startup."
  (sk-test-with-org (concat "#+TODO: TODO | DONE\n\n"
                            "* TODO MM-100 Story\n"
                            ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                            "** TODO MM-101 Task\n")
    (let ((simply-kanban-show-stories t)
          (simply-kanban-buffer-name "*sk-test-stories-option*")
          board)
      (unwind-protect
          (progn
            (setq board (simply-kanban--open (cons 'buffer src)))
            (with-current-buffer board
              (should simply-kanban--show-stories)
              (should (string-match-p "STORY 1 child" (buffer-string)))))
        (when (buffer-live-p board)
          (kill-buffer board))))))

(ert-deftest sk-test-tasks-option-on-open ()
  "`simply-kanban-show-tasks' can hide tasks while showing stories."
  (sk-test-with-org (concat "#+TODO: TODO | DONE\n\n"
                            "* TODO MM-100 Story\n"
                            ":PROPERTIES:\n:TICKET_TYPE: STORY\n:END:\n"
                            "** TODO MM-101 Task\n")
    (let ((simply-kanban-show-stories t)
          (simply-kanban-show-tasks nil)
          (simply-kanban-buffer-name "*sk-test-tasks-option*")
          board)
      (unwind-protect
          (progn
            (setq board (simply-kanban--open (cons 'buffer src)))
            (with-current-buffer board
              (should-not simply-kanban--show-tasks)
              (should (string-match-p "STORY 1 child" (buffer-string)))
              (should-not (string-match-p "TASK parent MM-100"
                                          (buffer-string)))))
        (when (buffer-live-p board)
          (kill-buffer board))))))

(ert-deftest sk-test-all-boards-render ()
  "Rendering an all-boards spec shows every board's cards, denoting the board."
  (sk-test-with-org (concat "* Project Alpha\n** TODO design\n** TODO build\n"
                            "* Project Beta\n** TODO research\n")
    (let ((board (get-buffer-create "*sk-test-board*")))
      (unwind-protect
          (with-current-buffer board
            (simply-kanban-mode)
            (simply-kanban--render (cons 'all-boards src))
            (should (= 3 (length (simply-kanban--anchors))))
            (goto-char (point-min))
            (should (re-search-forward "Project Alpha" nil t))
            (goto-char (point-min))
            (should (re-search-forward "Project Beta" nil t)))
        (kill-buffer board)))))

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
               (max 20 (window-body-width (selected-window)))))))

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
          (simply-kanban-buffer-name "*sk-auto-test*")
          board)
      (unwind-protect
          (progn
            (setq board (with-current-buffer src (simply-kanban)))
            (should (buffer-live-p board))
            (with-current-buffer board
              (should (= 1 (length (simply-kanban--anchors)))))
            ;; Add a task to the source and save it.
            (with-current-buffer src
              (goto-char (point-max))
              (insert "* TODO b\n")
              (save-buffer))
            ;; The board picked it up via the source's after-save hook.
            (with-current-buffer board
              (should (= 2 (length (simply-kanban--anchors))))))
        (when (buffer-live-p board)
          (kill-buffer board))))))

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
          (simply-kanban--render (list 'files f1 f2))
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
            (simply-kanban--render (list 'files f1 f2))
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
  (should (eq (lookup-key simply-kanban-mode-map (kbd "C-m")) 'simply-kanban-goto))
  (should (equal (interactive-form 'simply-kanban-goto) '(interactive "P")))
  (should (eq (lookup-key simply-kanban-mode-map "}") 'simply-kanban-advance))
  (should (eq (lookup-key simply-kanban-mode-map "{") 'simply-kanban-retreat))
  (should (eq (lookup-key simply-kanban-mode-map "s") 'simply-kanban-set-status))
  (should (eq (lookup-key simply-kanban-mode-map "k") 'simply-kanban-delete))
  (should (eq (lookup-key simply-kanban-mode-map "t") 'simply-kanban-set-tag-filter))
  (should (eq (lookup-key simply-kanban-mode-map "T") 'simply-kanban-clear-tag-filter))
  (should (eq (lookup-key simply-kanban-mode-map "F") 'simply-kanban-toggle-follow))
  (should (eq (lookup-key simply-kanban-mode-map "c") 'simply-kanban-toggle-compact))
  (should (eq (lookup-key simply-kanban-mode-map "v") 'simply-kanban-toggle-stories))
  (should (eq (lookup-key simply-kanban-mode-map "V") 'simply-kanban-toggle-tasks))
  (should (eq (lookup-key simply-kanban-mode-map ";") 'simply-kanban-set-effort))
  (should (eq (lookup-key simply-kanban-mode-map "P") 'simply-kanban-set-story-points))
  (should (eq (lookup-key simply-kanban-mode-map "#") 'simply-kanban-set-sprint))
  (should (eq (lookup-key simply-kanban-mode-map "i") 'simply-kanban-clock-in))
  (should (eq (lookup-key simply-kanban-mode-map "o") 'simply-kanban-clock-out))
  (should (eq (lookup-key simply-kanban-mode-map "S") 'simply-kanban-set-sprint-filter))
  (should (eq (lookup-key simply-kanban-mode-map "C") 'simply-kanban-clear-sprint-filter))
  (should (eq (lookup-key simply-kanban-mode-map "n") 'simply-kanban-next-card)))

(defun sk-test--header-line-string ()
  "Evaluate the board's `header-line-format' to a plain string."
  (mapconcat (lambda (piece)
               (cond ((stringp piece) piece)
                     ((and (consp piece) (eq (car piece) :eval))
                      (or (eval (cadr piece) t) ""))
                     (t "")))
             header-line-format ""))

(defun sk-test--mode-line-buffer-string ()
  "Evaluate the board's mode-line buffer identification to a plain string."
  (mapconcat (lambda (piece)
               (cond ((stringp piece) piece)
                     ((and (consp piece) (eq (car piece) :eval))
                      (or (eval (cadr piece) t) ""))
                     (t "")))
             mode-line-buffer-identification ""))

(ert-deftest sk-test-header-line-indicators-first ()
  "The clock indicator leads the header line."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO a\n"
    (let ((simply-kanban--sprint-filter "2"))
      (cl-letf (((symbol-function 'org-clock-is-active) (lambda () t))
                ((symbol-function 'org-clock-get-clocked-time) (lambda () 90)))
        (let ((line (sk-test--header-line-string)))
          (should (string-prefix-p " [clock: 1:30] " line))
          (should-not (string-match-p (regexp-quote "[sprint:") line))
          (should (string-match-p (regexp-quote "] ? menu") line))
          (should-not (string-match-p "follow" line))
          (should (string-match-p (regexp-quote "? menu") line))
          (should-not (string-match-p "SPC" line))
          (should-not (string-match-p "status" line))
          (should-not (string-match-p "quit" line)))))))

(ert-deftest sk-test-mode-line-sprint-indicator ()
  "The sprint filter appears in the mode line, not the header line."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO a\n"
    (should-not (string-match-p "sprint" (sk-test--mode-line-buffer-string)))
    (let ((simply-kanban--sprint-filter "2"))
      (should (string-match-p (regexp-quote "[sprint: 2]")
                              (sk-test--mode-line-buffer-string)))
      (should-not (string-match-p (regexp-quote "[sprint:")
                                  (sk-test--header-line-string))))))

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

(ert-deftest sk-test-set-effort ()
  "`simply-kanban-set-effort' writes the Effort property back to Org."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Parser\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "1:00")))
      (simply-kanban-set-effort))
    (with-current-buffer src
      (goto-char (point-min))
      (re-search-forward "Parser")
      (org-back-to-heading t)
      (should (string= (org-entry-get nil "Effort") "1:00")))))

(ert-deftest sk-test-set-story-points ()
  "`simply-kanban-set-story-points' writes the property back to Org."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Parser\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "5")))
      (simply-kanban-set-story-points))
    (with-current-buffer src
      (goto-char (point-min))
      (re-search-forward "Parser")
      (org-back-to-heading t)
      (should (string= (org-entry-get nil "STORY_POINTS") "5")))))

(ert-deftest sk-test-set-story-points-remove ()
  "Empty input to `simply-kanban-set-story-points' removes the property."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Parser\n:PROPERTIES:\n:STORY_POINTS: 5\n:END:\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
      (simply-kanban-set-story-points))
    (with-current-buffer src
      (goto-char (point-min))
      (re-search-forward "Parser")
      (org-back-to-heading t)
      (should (null (org-entry-get nil "STORY_POINTS"))))))

(ert-deftest sk-test-clock-in-out ()
  "Clocking from a card updates Org and writes a CLOCK entry."
  (sk-test-with-board "#+TODO: TODO DOING | DONE\n\n* TODO Parser\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (unwind-protect
        (progn
          (simply-kanban-clock-in)
          (should (org-clock-is-active))
          (with-current-buffer board
            (should-not (string-match-p "(run)" (buffer-string))))
          (simply-kanban-clock-out)
          (should-not (org-clock-is-active))
          (with-current-buffer src
            (goto-char (point-min))
            (should (re-search-forward "CLOCK:" nil t))))
      (when (org-clock-is-active)
        (org-clock-out)))))

(ert-deftest sk-test-highlight-running-card ()
  "The running card gets a solid block outline."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n* TODO Beta\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (unwind-protect
        (progn
          (simply-kanban-clock-in)
          (should (simply-kanban--same-card-p
                   simply-kanban--running-card
                   (simply-kanban--marker-at-point)))
          (let* ((card (simply-kanban--marker-at-point))
                 (regions (simply-kanban--card-regions card))
                 (top (car regions))
                 (bottom (car (last regions)))
                 (middle (butlast (cdr regions)))
                 (face (simply-kanban--keyword-face "TODO")))
            (should (> (length regions) 2))
            (dolist (region (list top bottom))
              (should (seq-some
                       (lambda (ov)
                         (and (= (overlay-start ov) (car region))
                              (= (overlay-end ov) (cdr region))))
                       simply-kanban--running-overlays)))
            (dolist (region middle)
              (should (seq-some
                       (lambda (ov)
                         (and (= (overlay-start ov) (car region))
                              (= (overlay-end ov) (1+ (car region)))))
                       simply-kanban--running-overlays))
              (should (seq-some
                       (lambda (ov)
                         (and (= (overlay-start ov) (1- (cdr region)))
                              (= (overlay-end ov) (cdr region))))
                       simply-kanban--running-overlays)))
            (dolist (ov simply-kanban--running-overlays)
              (let ((display (substring-no-properties
                              (overlay-get ov 'display))))
                (should (eq (overlay-get ov 'face) face))
                (should (= (string-width display)
                           (- (overlay-end ov) (overlay-start ov))))
                (should (seq-every-p (lambda (ch) (eq ch ?█))
                                     (string-to-list display))))))
          (simply-kanban-clock-out)
          (should-not simply-kanban--running-card)
          (should-not simply-kanban--running-overlays))
      (when (org-clock-is-active)
        (org-clock-out)))))

(ert-deftest sk-test-running-card-title-case ()
  "Clocking in leaves the card title in its original case."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n* TODO Beta\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (unwind-protect
        (progn
          (simply-kanban-clock-in)
          (let ((case-fold-search nil))
            (should (string-match-p "Alpha" (buffer-string)))
            (should-not (string-match-p "ALPHA" (buffer-string)))
            (should (string-match-p "Beta" (buffer-string))))
          (simply-kanban-clock-out)
          (should (string-match-p "Alpha" (buffer-string))))
      (when (org-clock-is-active)
        (org-clock-out)))))

(ert-deftest sk-test-toggle-clock ()
  "Toggling clocking twice clocks the same card back out."
  (sk-test-with-board "#+TODO: TODO DOING | DONE\n\n* TODO Parser\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (unwind-protect
        (progn
          (simply-kanban-toggle-clock)
          (should (org-clock-is-active))
          (simply-kanban-toggle-clock)
          (should-not (org-clock-is-active)))
      (when (org-clock-is-active)
        (org-clock-out)))))

;;; Tag filtering

(ert-deftest sk-test-tag-filter ()
  "Setting a tag filter shows only cards with that tag."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha :urgent:\n* TODO Beta\n* TODO Gamma :urgent:\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (should (= 3 (length (simply-kanban--anchors))))
    (setq simply-kanban--tag-filter "urgent")
    (simply-kanban-refresh)
    (should (= 2 (length (simply-kanban--anchors))))))

(ert-deftest sk-test-clear-tag-filter ()
  "Clearing the tag filter shows all cards."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha :urgent:\n* TODO Beta\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (setq simply-kanban--tag-filter "urgent")
    (simply-kanban-refresh)
    (should (= 1 (length (simply-kanban--anchors))))
    (setq simply-kanban--tag-filter nil)
    (simply-kanban-refresh)
    (should (= 2 (length (simply-kanban--anchors))))))

;;; Sprints

(ert-deftest sk-test-sprint-lessp ()
  "Numeric sprints sort numerically; text sprints lexicographically."
  (should (simply-kanban--sprint-lessp "2" "10"))
  (should (simply-kanban--sprint-lessp "Alpha" "Beta"))
  (should-not (simply-kanban--sprint-lessp "10" "2")))

(ert-deftest sk-test-sprint-filter ()
  "A sprint filter shows only cards whose sprint text matches."
  (sk-test-with-board (concat "#+TODO: TODO | DONE\n\n"
                              "* TODO Alpha\n:PROPERTIES:\n:SPRINT: Sprint 1\n:END:\n"
                              "* TODO Beta\n:PROPERTIES:\n:SPRINT: Sprint 2\n:END:\n"
                              "* TODO Gamma\n:PROPERTIES:\n:SPRINT: Sprint 1\n:END:\n")
    (goto-char (point-min))
    (simply-kanban-next-card)
    (should (= 3 (length (simply-kanban--anchors))))
    (setq simply-kanban--sprint-filter "Sprint 1")
    (simply-kanban-refresh)
    (should (= 2 (length (simply-kanban--anchors))))
    (setq simply-kanban--sprint-filter nil)
    (simply-kanban-refresh)
    (should (= 3 (length (simply-kanban--anchors))))))

(ert-deftest sk-test-set-sprint ()
  "`simply-kanban-set-sprint' writes any sprint text back to Org."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Sprint Alpha")))
      (simply-kanban-set-sprint))
    (with-current-buffer src
      (goto-char (point-min))
      (re-search-forward "Alpha")
      (org-back-to-heading t)
      (should (string= (org-entry-get nil "SPRINT") "Sprint Alpha")))))

(ert-deftest sk-test-set-sprint-remove ()
  "Empty input to `simply-kanban-set-sprint' removes the SPRINT property."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n:PROPERTIES:\n:SPRINT: 2\n:END:\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
      (simply-kanban-set-sprint))
    (with-current-buffer src
      (goto-char (point-min))
      (re-search-forward "Alpha")
      (org-back-to-heading t)
      (should (null (org-entry-get nil "SPRINT"))))))

(ert-deftest sk-test-default-sprint-on-open ()
  "Opening a board honours `simply-kanban-default-sprint'."
  (let ((simply-kanban-default-sprint "1"))
    (sk-test-with-org (concat "* TODO Alpha\n:PROPERTIES:\n:SPRINT: 1\n:END:\n"
                              "* TODO Beta\n:PROPERTIES:\n:SPRINT: 2\n:END:\n")
      (let (board)
        (unwind-protect
            (progn
              (setq board (simply-kanban))
              (with-current-buffer board
                (should (equal "1" simply-kanban--sprint-filter))
                (should (= 1 (length (simply-kanban--anchors))))))
          (when (buffer-live-p board)
            (kill-buffer board)))))))

;;; Sprint summary

(defconst sk-test-sprint-summary-content
  (concat "#+TODO: TODO DOING | DONE\n\n"
          "* Work breakdown\n"
          "** Sprint 8\n"
          "*** TODO A\n"
          ":PROPERTIES:\n:SPRINT:   8\n:Effort:   1:00\n:STORY_POINTS: 5\n:END:\n"
          ":LOGBOOK:\n"
          "CLOCK: [2026-01-01 Thu 09:00]--[2026-01-01 Thu 09:30] =>  0:30\n"
          ":END:\n"
          "*** DONE B\n"
          ":PROPERTIES:\n:SPRINT:   8\n:Effort:   1:00\n:STORY_POINTS: 3\n:END:\n"
          "** Sprint 9\n"
          "*** TODO C\n"
          ":PROPERTIES:\n:SPRINT:   9\n:Effort:   2:00\n:STORY_POINTS: 8\n:END:\n"))

(ert-deftest sk-test-sprint-summary-rows ()
  "`--sprint-summary-rows' aggregates tasks, done cards, and durations."
  (sk-test-with-org sk-test-sprint-summary-content
    (let ((rows (simply-kanban--sprint-summary-rows 'file)))
      (should (equal (car rows)
                     '("Sprint" "Tasks" "Done" "Points" "Progress"
                       "Estimate" "Actual" "Remaining")))
      (should (equal (nth 1 rows) '("8" 2 1 "8" "75%" "2h" "30m" "30m")))
      (should (equal (nth 2 rows) '("9" 1 0 "8" "0%" "2h" "0m" "2h"))))))

(ert-deftest sk-test-sprint-summary-dblock ()
  "The sprint summary dynamic block writes an aligned Org table."
  (sk-test-with-org sk-test-sprint-summary-content
    (goto-char (point-max))
    (insert "\n* Sprint summary\n"
            "#+BEGIN: simply-kanban-sprint-summary :scope file\n"
            "#+END:\n")
    (goto-char (point-min))
    (search-forward "#+BEGIN: simply-kanban-sprint-summary")
    (beginning-of-line)
    (org-dblock-update)
    (goto-char (point-min))
    (should (re-search-forward
             "| +8 +| +2 +| +1 +| +8 +| +75% +| +2h +| +30m +| +30m +|" nil t))
    (should (re-search-forward
             "| +9 +| +1 +| +0 +| +8 +| +0% +| +2h +| +0m +| +2h +|" nil t))))

;;; Delete card

(ert-deftest sk-test-delete-card ()
  "Deleting a card removes the heading from the source buffer."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n* TODO Beta\n* TODO Gamma\n"
    (goto-char (point-min))
    (simply-kanban-next-card)
    (simply-kanban-next-card)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (simply-kanban-delete))
    (with-current-buffer src
      (goto-char (point-min))
      (should-not (re-search-forward "Beta" nil t)))))

;;; Priority sorting

(ert-deftest sk-test-priority-sort ()
  "When priority sorting is enabled, cards appear in priority order."
  (let ((simply-kanban-sort-by-priority t))
    (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO [#C] Low\n* TODO [#A] High\n* TODO [#B] Medium\n"
      (goto-char (point-min))
      (simply-kanban-next-card)
      (let* ((anchors (simply-kanban--anchors))
             (first-marker (get-text-property (caar anchors) 'simply-kanban-marker)))
        (with-current-buffer (marker-buffer first-marker)
          (goto-char first-marker)
          (should (string-match-p "High" (org-get-heading t t t t))))))))

(ert-deftest sk-test-show-card-finds-anchor ()
  "A heading's markers match its own card anchor on the board."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n* TODO Beta\n"
    (let* ((cands (with-current-buffer src
                    (goto-char (point-min))
                    (re-search-forward "Beta")
                    (simply-kanban--heading-markers-upward)))
           (anchor (seq-some #'simply-kanban--anchor-for-marker cands)))
      (should anchor)
      (goto-char (car anchor))
      (let ((m (simply-kanban--marker-at-point)))
        (should (with-current-buffer src
                  (goto-char m) (string= (org-get-heading t t t t) "Beta")))))))

(ert-deftest sk-test-show-card-walks-up-to-enclosing-card ()
  "Point on a non-card sub-heading resolves to the enclosing card."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n** Notes\n"
    (let* ((cands (with-current-buffer src
                    (goto-char (point-min))
                    (re-search-forward "Notes")
                    (simply-kanban--heading-markers-upward)))
           (anchor (seq-some #'simply-kanban--anchor-for-marker cands)))
      (should (= 2 (length cands)))
      (should anchor)
      (goto-char (car anchor))
      (let ((m (simply-kanban--marker-at-point)))
        (should (with-current-buffer src
                  (goto-char m) (string= (org-get-heading t t t t) "Alpha")))))))

(ert-deftest sk-test-show-card-command ()
  "`simply-kanban-show-card' selects, on the board, the heading at point."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n* TODO Beta\n"
    (with-current-buffer src
      (goto-char (point-min))
      (re-search-forward "Beta")
      (simply-kanban-show-card))
    (with-current-buffer board
      (let ((m (simply-kanban--marker-at-point)))
        (should m)
        (should (with-current-buffer src
                  (goto-char m) (string= (org-get-heading t t t t) "Beta")))))))

(ert-deftest sk-test-jump-to-card-focuses-board ()
  "`simply-kanban-jump-to-card' leaves focus on the matching board card."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Alpha\n* TODO Beta\n"
    (unwind-protect
        (progn
          (switch-to-buffer src)
          (delete-other-windows)
          (goto-char (point-min))
          (re-search-forward "Beta")
          (simply-kanban-jump-to-card)
          (should (eq (window-buffer (selected-window)) board))
          (with-current-buffer board
            (let ((m (simply-kanban--marker-at-point)))
              (should m)
              (should (with-current-buffer src
                        (goto-char m)
                        (string= (org-get-heading t t t t) "Beta"))))))
      (delete-other-windows))))

(defun sk-test--default-board (source)
  "Return the live board buffer for SOURCE's default board spec."
  (simply-kanban--find-board
   (with-current-buffer source
     (simply-kanban--org-board-spec))))

(ert-deftest sk-test-show-card-creates-board-when-missing ()
  "`show-card' creates a board when none is open, then selects the card."
  (sk-test-with-org "#+TODO: TODO | DONE\n\n* TODO Alpha\n* TODO Beta\n"
    (let ((simply-kanban-buffer-name "*sk-test-autoboard*")
          board)
      (unwind-protect
          (progn
            (should-not (sk-test--default-board src))
            (goto-char (point-min))
            (re-search-forward "Beta")
            (simply-kanban-show-card)
            (setq board (sk-test--default-board src))
            (should (buffer-live-p board))
            (with-current-buffer board
              (should (string-match-p "sk-test-autoboard" (buffer-name)))
              (let ((m (simply-kanban--marker-at-point)))
                (should (with-current-buffer src
                          (goto-char m)
                          (string= (org-get-heading t t t t) "Beta"))))))
        (when (buffer-live-p board)
          (kill-buffer board))))))

(ert-deftest sk-test-show-card-create-splits-right ()
  "Auto-creating the board splits to the right, keeping the Org file visible."
  (sk-test-with-org "#+TODO: TODO | DONE\n\n* TODO Alpha\n* TODO Beta\n"
    (let ((simply-kanban-buffer-name "*sk-test-autoboard*")
          board)
      (unwind-protect
          (progn
            (switch-to-buffer src)
            (delete-other-windows)
            (goto-char (point-min))
            (re-search-forward "Beta")
            (simply-kanban-show-card)
            (setq board (sk-test--default-board src))
            (let ((src-win (get-buffer-window src))
                  (board-win (get-buffer-window board)))
              ;; The Org file stays visible ...
              (should (window-live-p src-win))
              ;; ... alongside the board, which sits to its right.
              (should (window-live-p board-win))
              (should (> (window-left-column board-win)
                         (window-left-column src-win)))))
        (when (buffer-live-p board)
          (kill-buffer board))
        (delete-other-windows)))))

(ert-deftest sk-test-show-card-creates-all-boards-for-multiboard ()
  "For a multi-board file `show-card' auto-creates an all-boards view."
  (sk-test-with-org (concat "* Project Alpha\n** TODO design\n"
                            "* Project Beta\n** TODO research\n")
    (let ((simply-kanban-buffer-name "*sk-test-autoboard*")
          board)
      (unwind-protect
          (progn
            (goto-char (point-min))
            (re-search-forward "research")
            (simply-kanban-show-card)
            (setq board (sk-test--default-board src))
            (should (buffer-live-p board))
            (with-current-buffer board
              (should (eq (car simply-kanban--source-spec) 'all-boards))
              (let ((m (simply-kanban--marker-at-point)))
                (should (with-current-buffer src
                          (goto-char m)
                          (string= (org-get-heading t t t t) "research"))))))
        (when (buffer-live-p board)
          (kill-buffer board))))))

(ert-deftest sk-test-open-boards-in-separate-buffers ()
  "Different boards open in separate buffers named after their source."
  (sk-test-with-org (concat "* Project Alpha\n** TODO design\n"
                            "* Project Beta\n** TODO research\n")
    (let ((simply-kanban-buffer-name "*sk-test-multi*")
          alpha-buffer beta-buffer)
      (unwind-protect
          (progn
            (let* ((boards (simply-kanban--file-boards src))
                   (alpha (cdr (assoc "Project Alpha" boards)))
                   (beta (cdr (assoc "Project Beta" boards))))
              (setq alpha-buffer (simply-kanban--open alpha)
                    beta-buffer (simply-kanban--open beta))
              (should-not (eq alpha-buffer beta-buffer))
              (should (string-match-p "Project Alpha"
                                      (buffer-name alpha-buffer)))
              (should (string-match-p "Project Beta"
                                      (buffer-name beta-buffer)))
              ;; Reopening the same board reuses its buffer.
              (should (eq alpha-buffer (simply-kanban--open alpha)))))
        (dolist (board (list alpha-buffer beta-buffer))
          (when (buffer-live-p board)
            (kill-buffer board)))))))

(ert-deftest sk-test-truncate-title ()
  "`--truncate-title' shortens long titles unless the card is expanded."
  (let ((simply-kanban--title-length 5))
    ;; Long title is cut to the limit with an ellipsis ...
    (should (string= (simply-kanban--truncate-title "abcdefgh" nil) "abcde…"))
    ;; ... unless the card is expanded ...
    (should (string= (simply-kanban--truncate-title "abcdefgh" t) "abcdefgh"))
    ;; ... and short titles are left alone.
    (should (string= (simply-kanban--truncate-title "abc" nil) "abc")))
  ;; No limit means no change.
  (let ((simply-kanban--title-length nil))
    (should (string= (simply-kanban--truncate-title "abcdefgh" nil) "abcdefgh"))))

(ert-deftest sk-test-title-length-renders-truncated ()
  "A long title renders truncated on the board, in full once expanded."
  (sk-test-with-board
      "#+TODO: TODO | DONE\n\n* TODO A very long card title indeed\n"
    (setq simply-kanban--title-length 8)
    (simply-kanban-refresh)
    (goto-char (point-min))
    (should (re-search-forward "A very l…" nil t))
    ;; Expanding the card reveals the full title.
    (goto-char (point-min))
    (simply-kanban-next-card)
    (simply-kanban-toggle-expand)
    (goto-char (point-min))
    (should (re-search-forward "long card title" nil t))))

(ert-deftest sk-test-set-title-length-command ()
  "`simply-kanban-set-title-length' updates the board's limit live."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Some lengthy heading\n"
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "4")))
      (simply-kanban-set-title-length))
    (should (= simply-kanban--title-length 4))
    (goto-char (point-min))
    (should (re-search-forward "Some…" nil t))
    ;; Empty input clears the limit.
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
      (simply-kanban-set-title-length))
    (should-not simply-kanban--title-length)
    (goto-char (point-min))
    (should (re-search-forward "Some lengthy heading" nil t))))

(ert-deftest sk-test-set-title-length-rejects-nonpositive ()
  "`simply-kanban-set-title-length' refuses zero or negative lengths."
  (sk-test-with-board "#+TODO: TODO | DONE\n\n* TODO Heading\n"
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "0")))
      (should-error (simply-kanban-set-title-length) :type 'user-error))))

(provide 'simply-kanban-tests)
;;; simply-kanban-tests.el ends here
