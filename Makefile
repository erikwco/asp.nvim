NVIM ?= nvim
CC ?= cc
CFLAGS ?= -Os -fPIC -shared

PARSERS := parser/aspclassic.so parser/vba.so parser/html.so

.PHONY: parsers test clean

parsers: $(PARSERS) queries/vba

build:
	mkdir -p build

parser:
	mkdir -p parser

build/plenary.nvim: | build
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $@

build/tree-sitter-vba: | build
	git clone --depth 1 https://github.com/arrmee-wt/tree-sitter-vba $@

build/tree-sitter-html: | build
	git clone --depth 1 https://github.com/tree-sitter/tree-sitter-html $@

grammars/aspclassic/src/parser.c: grammars/aspclassic/grammar.js
	cd grammars/aspclassic && tree-sitter generate

parser/aspclassic.so: grammars/aspclassic/src/parser.c | parser
	$(CC) $(CFLAGS) -Igrammars/aspclassic/src grammars/aspclassic/src/*.c -o $@

parser/vba.so: | build/tree-sitter-vba parser
	$(CC) $(CFLAGS) -Ibuild/tree-sitter-vba/src build/tree-sitter-vba/src/*.c -o $@

parser/html.so: | build/tree-sitter-html parser
	$(CC) $(CFLAGS) -Ibuild/tree-sitter-html/src build/tree-sitter-html/src/*.c -o $@

# Queries de resaltado de VBA, tomadas del propio repo de la gramática.
# El repo arrmee-wt/tree-sitter-vba no trae queries/*.scm (highlights: []
# en su tree-sitter.json); si en el futuro las agrega, se copian aquí.
queries/vba: | build/tree-sitter-vba
	mkdir -p queries/vba
	cp build/tree-sitter-vba/queries/*.scm queries/vba/ 2>/dev/null || true

test: parsers build/plenary.nvim
	$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec { minimal_init = 'tests/minimal_init.lua' }"

clean:
	rm -rf parser build grammars/aspclassic/src
