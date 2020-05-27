# Lwt Pipe  [![Build Status](https://travis-ci.org/c-cube/lwt-pipe.svg?branch=master)](https://travis-ci.org/c-cube/lwt-pipe)

An alternative to `Lwt_stream` with interfaces for producers and consumers
and a bounded internal buffer.

[Online Documentation](https://c-cube.github.io/lwt-pipe/)

## Build

```
opam install lwt-pipe
```

or:

```
opam pin https://github.com/c-cube/lwt-pipe.git
```

## License

permissive free software (BSD-2)

## Use

A pipe can be used as a regular iterator:

```ocaml
# #require "lwt";;
# #require "lwt-pipe.unix";;

# open Lwt.Infix;;

# module Lwt_pipe = Lwt_pipe_unix;;
module Lwt_pipe = Lwt_pipe_unix

# let l = [1;2;3;4];;
val l : int list = [1; 2; 3; 4]

# Lwt_pipe.of_list l
  |> Lwt_pipe.Reader.map ~f:(fun x->x+1)
  |> Lwt_pipe.to_list;;
- : int list = [2; 3; 4; 5]
```

But also as a streaming queue (here with two producers `push_ints` that will
put `1, 2, … 5` into the pipe, and one reader that consumes the whole pipe):

```ocaml
# let rec push_ints p i : unit Lwt.t =
  if i <= 0 then Lwt.return ()
  else Lwt_pipe.write_exn p i >>= fun () -> push_ints p (i-1) ;;
val push_ints : (int, [< `r | `w > `w ]) Lwt_pipe.t -> int -> unit Lwt.t =
  <fun>

# let reader =
    let p = Lwt_pipe.create ~max_size:3 () in
    let t1 = push_ints p 5
    and t2 = push_ints p 5
    and t_read = Lwt_pipe.to_list p in
    Lwt.join [t1;t2] >>= fun () ->
    Lwt_pipe.close p >>= fun () ->
    t_read
  in
  List.sort compare @@ Lwt_main.run reader
  ;;
- : int list = [1; 1; 2; 2; 3; 3; 4; 4; 5; 5]
```

This can be expressed with higher level constructs:


```ocaml
# let rec list_range i = if i<=0 then [] else i :: list_range (i-1);;
val list_range : int -> int list = <fun>
# let int_range n = Lwt_pipe.of_list @@ list_range n ;;
val int_range : int -> int Lwt_pipe.Reader.t = <fun>

# Lwt_main.run @@ Lwt_pipe.to_list (int_range 5);;
- : int list = [5; 4; 3; 2; 1]

# let reader =
    let p1 = int_range 6
    and p2 = int_range 6
    and p3 = int_range 6 in
    Lwt_pipe.to_list (Lwt_pipe.Reader.merge_all [p1;p2;p3])
  in
  List.sort compare @@ Lwt_main.run reader
  ;;
- : int list = [1; 1; 1; 2; 2; 2; 3; 3; 3; 4; 4; 4; 5; 5; 5; 6; 6; 6]
```
