.PHONY: build clean install

build:
	@dune build @install

clean:
	@dune clean

install:
	@dune install

test: build
	@dune runtest --force --no-buffer

watch:
	@dune build @all -w
