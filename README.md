# Lwt Pipe

An alternative to `Lwt_stream` with interfaces for producers and consumers
and a bounded internal buffer.

## Build

    opam install lwt-pipe

or:

    opam pin add -k git lwt-pipe https://github.com/c-cube/lwt-pipe.git
    opam install lwt-pipe

## Use

```ocaml
# #require "lwt";;
# #require "lwt-pipe";;

# open Lwt.Infix;;

# let l = [1;2;3;4];;

# Lwt_pipe.of_list l
  |> Lwt_pipe.Reader.map ~f:(fun x->x+1)
  |> Lwt_pipe.to_list;;
- : int list Lwt.t = [2; 3; 4; 5]

```

## License

permissive free software (BSD-2)
