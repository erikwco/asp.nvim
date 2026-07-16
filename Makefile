NVIM ?= nvim

build/plenary.nvim:
	mkdir -p build
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim build/plenary.nvim

.PHONY: test
test: build/plenary.nvim
	$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec { minimal_init = 'tests/minimal_init.lua' }"
