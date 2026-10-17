EMACS ?= emacs
# Dependencies (transient and its dependencies, ghostel) are taken from
# package.el, or from directories given in LOAD_PATH, e.g.
# LOAD_PATH="-L ../transient/lisp -L ../compat -L ../ghostel/lisp".
LOAD_PATH ?=
BATCH = $(EMACS) -Q --batch --eval '(package-initialize)' -L . $(LOAD_PATH) \
	--eval '(setq load-prefer-newer t)'
FILES = $(wildcard agent-term*.el)

.PHONY: all compile checkdoc test clean

all: compile checkdoc test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(FILES)

checkdoc:
	$(BATCH) --eval '(dolist (f (quote ($(patsubst %,"%",$(FILES))))) (checkdoc-file f))'

test:
	$(BATCH) -L test -l test/agent-term-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
