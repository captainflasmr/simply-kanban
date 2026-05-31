# Makefile for simply-kanban
#
#   make test       run the ERT suite
#   make compile    byte-compile (warnings are errors)
#   make checkdoc   run checkdoc
#   make lint       run package-lint (needs `make deps')
#   make deps       install package-lint into ./.elpa
#   make all        compile + test + checkdoc
#   make clean      remove byte-compiled files
#
# Override the Emacs binary with, e.g.:  make EMACS=emacs-29.4 test

EMACS ?= emacs

PACKAGE = simply-kanban.el
TESTS   = tests/simply-kanban-tests.el
INIT    = tests/init.el

BATCH = $(EMACS) -Q --batch -l $(INIT)

.PHONY: all compile test checkdoc lint deps clean

all: compile test checkdoc

deps:
	$(BATCH) \
	  --eval "(unless package-archive-contents (package-refresh-contents))" \
	  --eval "(unless (package-installed-p 'package-lint) (package-install 'package-lint))"

compile:
	$(BATCH) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(PACKAGE)
	@rm -f $(PACKAGE)c

test:
	$(BATCH) -l ert -l $(TESTS) -f ert-run-tests-batch-and-exit

checkdoc:
	$(BATCH) --eval "(checkdoc-file \"$(PACKAGE)\")"

lint:
	$(BATCH) --eval "(require 'package-lint)" \
	  -f package-lint-batch-and-exit $(PACKAGE)

clean:
	rm -f $(PACKAGE)c tests/*.elc
