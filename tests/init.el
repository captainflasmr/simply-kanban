;;; init.el --- Batch/CI bootstrap for simply-kanban -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded first by every Makefile target (and by CI).  Points
;; `package-user-dir' at a project-local .elpa so dependency installs
;; (transient, package-lint) never touch the developer's real package store,
;; and puts the working copy at the front of `load-path'.  Org is built in;
;; `transient' is bundled on Emacs 28.1+ and otherwise installed into ./.elpa
;; by `make deps'.

;;; Code:

(require 'package)

(setq package-user-dir (expand-file-name ".elpa" default-directory))
(add-to-list 'package-archives '("gnu" . "https://elpa.gnu.org/packages/") t)
(add-to-list 'package-archives '("nongnu" . "https://elpa.nongnu.org/nongnu/") t)
(package-initialize)

(add-to-list 'load-path (expand-file-name "tests" default-directory))
(add-to-list 'load-path (expand-file-name default-directory))

(provide 'init)
;;; init.el ends here
