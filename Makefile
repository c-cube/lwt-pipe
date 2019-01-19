.PHONY: build clean install

build:
	@dune build @install

clean:
	@dune clean

install:
	@dune install
