.PHONY: all build clean install

all: build test

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
