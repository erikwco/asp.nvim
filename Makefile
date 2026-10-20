NVIM ?= nvim
CC ?= cc
CFLAGS ?= -Os -fPIC -shared

# El parser.c de cada gramática está versionado en el repo (ABI 14, para
# cargar en Neovim >= 0.10). Por eso `make parsers` sólo necesita un
# compilador C — NO tree-sitter CLI ni Node.js. Esos sólo se necesitan
# para `make generate` (regenerar tras editar una grammar.js).
#
# `parsers-test` agrega html y javascript, compilados desde clones shallow
# en build/ (sólo para la suite: al usuario se los provee nvim-treesitter):
# html para las regiones HTML y los <script>, javascript para la capa de
# navegación JS (asp.js) dentro de esos <script>.
#
# tree-sitter-javascript va pineado a un tag con ABI 14: la rama principal
# genera ABI 15, que Neovim 0.10 (el mínimo soportado) no carga, y además
# no es reproducible. El directorio lleva el tag en el nombre, así que
# cambiar TS_JS_REF clona de nuevo y recompila parser/javascript.so.
TS_CLI ?= npx -y tree-sitter-cli@0.25.10
TS_ABI ?= 14
TS_JS_REF ?= v0.23.1
TS_JS_DIR := build/tree-sitter-javascript-$(TS_JS_REF)

PARSERS := parser/aspclassic.so parser/vbscript.so

.PHONY: parsers parsers-test generate test clean helptags

parsers: $(PARSERS)

parsers-test: parsers parser/html.so parser/javascript.so

# Regenera el parser.c versionado desde grammar.js. Requiere Node.js.
# Corré esto tras cambiar cualquier grammar.js y commiteá el resultado.
generate:
	cd grammars/aspclassic && $(TS_CLI) generate --abi $(TS_ABI)
	cd grammars/vbscript && $(TS_CLI) generate --abi $(TS_ABI)

build:
	mkdir -p build

parser:
	mkdir -p parser

build/plenary.nvim: | build
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $@

build/tree-sitter-html: | build
	git clone --depth 1 https://github.com/tree-sitter/tree-sitter-html $@

$(TS_JS_DIR)/src/parser.c: | build
	git -c advice.detachedHead=false clone --depth 1 --branch $(TS_JS_REF) https://github.com/tree-sitter/tree-sitter-javascript $(TS_JS_DIR)

parser/aspclassic.so: grammars/aspclassic/src/parser.c | parser
	$(CC) $(CFLAGS) -Igrammars/aspclassic/src grammars/aspclassic/src/*.c -o $@

parser/vbscript.so: grammars/vbscript/src/parser.c | parser
	$(CC) $(CFLAGS) -Igrammars/vbscript/src grammars/vbscript/src/*.c -o $@

parser/html.so: | build/tree-sitter-html parser
	$(CC) $(CFLAGS) -Ibuild/tree-sitter-html/src build/tree-sitter-html/src/*.c -o $@

# src/*.c incluye el scanner.c externo de la gramática.
parser/javascript.so: $(TS_JS_DIR)/src/parser.c | parser
	$(CC) $(CFLAGS) -I$(TS_JS_DIR)/src $(TS_JS_DIR)/src/*.c -o $@

test: parsers-test build/plenary.nvim
	$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec { minimal_init = 'tests/minimal_init.lua' }"

clean:
	rm -rf parser build doc/tags

helptags:
	$(NVIM) --headless -c 'helptags doc' -c 'quit'
