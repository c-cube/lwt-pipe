# Lwt Pipe  [![Build Status](https://travis-ci.org/c-cube/lwt-pipe.svg?branch=master)](https://travis-ci.org/c-cube/lwt-pipe)

An alternative to `Lwt_stream` with interfaces for producers and consumers
and a bounded internal buffer.

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
# #require "lwt-pipe";;

# open Lwt.Infix;;

# let l = [1;2;3;4];;
val l : int list = [1; 2; 3; 4]

# Lwt_pipe.of_list l
  |> Lwt_pipe.Reader.map ~f:(fun x->x+1)
  |> Lwt_pipe.to_list;;
- : int list = [2; 3; 4; 5]
```

But also as a streaming queue:

```ocaml
# let rec push_ints p i : unit Lwt.t =
  if i <= 0 then Lwt.return ()
  else Lwt_pipe.write p i >>= fun () -> push_ints p (i-1) ;;
val push_ints : (int, [< `r | `w > `w ]) Lwt_pipe.t -> int -> unit Lwt.t =
  <fun>

# let read_all (p:_ Lwt_pipe.Reader.t) : _ list Lwt.t =
  let rec aux acc =
    Lwt_pipe.read p >>= function
    | None -> Lwt.return (List.rev acc)
    | Some x -> aux (x::acc) 
  in aux [];;
val read_all : 'a Lwt_pipe.Reader.t -> 'a list Lwt.t = <fun>

# let thread =
    let p = Lwt_pipe.create ~max_size:3 () in
    let t1 = push_ints p 5
    and t2 = push_ints p 5
    and t_read : int list Lwt.t = read_all p in
    Lwt.join [t1;t2] >>= fun () ->
    Lwt_pipe.close p >>= fun () ->
    t_read
  in
  List.sort Pervasives.compare @@ Lwt_main.run thread
  ;;
- : int list = [1; 1; 2; 2; 3; 3; 4; 4; 5; 5]
```
