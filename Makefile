
OPTS= -classic-display -use-ocamlfind
TARGETS= lwt_pipe.cma lwt_pipe.cmxa lwt_pipe.cmxs lwt_pipe.a

build:
	ocamlbuild $(OPTS) $(addprefix src/, $(TARGETS))

clean:
	ocamlbuild -clean

install: build
	ocamfind install lwt_pipe src/META $(addprefix _build/src/, $(TARGETS)) _build/src/*.cmi
