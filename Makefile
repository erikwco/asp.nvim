NVIM ?= nvim
CC ?= cc
CFLAGS ?= -Os -fPIC -shared

PARSERS := parser/aspclassic.so parser/vbscript.so

.PHONY: parsers parsers-test test clean

parsers: $(PARSERS)

parsers-test: parsers parser/html.so

build:
	mkdir -p build

parser:
	mkdir -p parser

build/plenary.nvim: | build
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $@

build/tree-sitter-html: | build
	git clone --depth 1 https://github.com/tree-sitter/tree-sitter-html $@

grammars/aspclassic/src/parser.c: grammars/aspclassic/grammar.js
	cd grammars/aspclassic && tree-sitter generate

parser/aspclassic.so: grammars/aspclassic/src/parser.c | parser
	$(CC) $(CFLAGS) -Igrammars/aspclassic/src grammars/aspclassic/src/*.c -o $@

grammars/vbscript/src/parser.c: grammars/vbscript/grammar.js
	cd grammars/vbscript && tree-sitter generate

parser/vbscript.so: grammars/vbscript/src/parser.c | parser
	$(CC) $(CFLAGS) -Igrammars/vbscript/src grammars/vbscript/src/*.c -o $@

parser/html.so: | build/tree-sitter-html parser
	$(CC) $(CFLAGS) -Ibuild/tree-sitter-html/src build/tree-sitter-html/src/*.c -o $@

test: parsers-test build/plenary.nvim
	$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec { minimal_init = 'tests/minimal_init.lua' }"

clean:
	rm -rf parser build grammars/aspclassic/src grammars/vbscript/src
