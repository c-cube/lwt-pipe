# Lwt Pipe

An alternative to `Lwt_stream` with interfaces for producers and consumers
and a bounded internal buffer.

## Build

    opam install lwt_pipe

or:

    opam pin add -k git lwt-pipe https://github.com/c-cube/lwt_pipe.git
    opam install lwt_pipe

## Use

```ocaml
# #require "lwt";;
# #require "lwt_pipe";;

# open Lwt.Infix;;

# let l = [1;2;3;4];;

# Lwt_pipe.of_list l
  |> Lwt_pipe.Reader.map ~f:(fun x->x+1)
  |> Lwt_pipe.to_list;;

```

## License

permissive free software (BSD-2)
