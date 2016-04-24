
(* This file is free software. See file "license" for more details. *)

open Lwt.Infix

let ret_end = Lwt.return None
let ret_yield x = Lwt.return (Some x)

exception Closed

type ('a, +'perm) t = {
  close : unit Lwt.u;
  closed : unit Lwt.t;
  readers : 'a option Lwt.u Queue.t;  (* readers *)
  writers : 'a option Queue.t;
  blocked_writers : ('a option * unit Lwt.u) Queue.t; (* blocked writers *)
  max_size : int;
  mutable keep : unit Lwt.t list;  (* do not GC, and wait for completion *)
} constraint 'perm = [< `r | `w]

type ('a, 'perm) pipe = ('a, 'perm) t

let create ?on_close ?(max_size=0) () =
  let closed, close = Lwt.wait () in
  begin match on_close with
    | None -> ()
    | Some f -> Lwt.on_success closed f
  end;
  {
    close;
    closed;
    readers = Queue.create ();
    writers = Queue.create ();
    blocked_writers = Queue.create ();
    max_size;
    keep=[];
  }

let keep p fut = p.keep <- fut :: p.keep

let is_closed p = not (Lwt.is_sleeping p.closed)

let close_nonblock p =
  if not (is_closed p) then (
    Lwt.wakeup p.close (); (* evaluate *)
    Queue.iter (fun r -> Lwt.wakeup r None) p.readers;
    Queue.iter (fun (_,r) -> Lwt.wakeup r ()) p.blocked_writers;
  )

let close p =
  close_nonblock p;
  Lwt.join p.keep

let wait p = Lwt.map (fun _ -> ()) p.closed

(* try to take next element from writers buffer *)
let try_read t =
  if Queue.is_empty t.writers
  then if Queue.is_empty t.blocked_writers
    then None
    else (
      assert (t.max_size = 0);
      let x, signal_done = Queue.pop t.blocked_writers in
      Lwt.wakeup signal_done ();
      Some x
    )
  else (
    let x = Queue.pop t.writers in
    (* some writer may unblock *)
    if not (Queue.is_empty t.blocked_writers) && Queue.length t.writers < t.max_size then (
      let y, signal_done = Queue.pop t.blocked_writers in
      Queue.push y t.writers;
      Lwt.wakeup signal_done ();
    );
    Some x
  )

(* read next one *)
let read t = match try_read t with
   | None when is_closed t -> ret_end (* end of stream *)
   | None ->
     let fut, send = Lwt.wait () in
     Queue.push send t.readers;
     fut
   | Some x -> Lwt.return x

(* write a value *)
let write_step t x =
  if is_closed t then Lwt.fail Closed
  else if Queue.length t.readers > 0
    then (
      (* some reader waits, synchronize now *)
      let send = Queue.pop t.readers in
      Lwt.wakeup send x;
      Lwt.return_unit
    )
  else if Queue.length t.writers < t.max_size
    then (
      Queue.push x t.writers;
      Lwt.return_unit  (* into buffer, do not wait *)
    )
  else (
    (* block until the queue isn't full anymore *)
    let is_done, signal_done = Lwt.wait () in
    Queue.push (x, signal_done) t.blocked_writers;
    is_done (* block *)
  )

let rec connect_rec r w =
  read r >>= function
  | None -> Lwt.return_unit
  | Some _ as step ->
    write_step w step >>= fun () ->
    connect_rec r w

(* close a when b closes *)
let link_close p ~after =
  Lwt.on_termination after.closed
    (fun _ -> close_nonblock p)

let connect ?(ownership=`None) a b =
  let fut = connect_rec a b in
  keep b fut;
  match ownership with
  | `None -> ()
  | `InOwnsOut -> link_close b ~after:a
  | `OutOwnsIn -> link_close a ~after:b

(* close a when every member of after closes *)
let link_close_l p ~after =
  let n = ref (List.length after) in
  List.iter
    (fun p' -> Lwt.on_termination p'.closed
      (fun _ ->
         decr n;
         if !n = 0 then close_nonblock p))
    after

let write t x = write_step t (Some x)

let rec write_list t l = match l with
  | [] -> Lwt.return_unit
  | x :: tail ->
    write t x >>= fun () -> write_list t tail

module Writer = struct
  type 'a t = ('a, [`w]) pipe

  let map ~f a =
    let b = create() in
    let rec fwd () =
      let fut = read b in
      Lwt.on_failure fut (fun _ -> close_nonblock a);
      fut >>= function
      | Some x -> write a (f x) >>= fwd
      | None -> Lwt.return_unit
    in
    keep b (fwd());
    (* when a gets closed, close b too *)
    link_close b ~after:a;
    b

  let send_all l =
    if l = [] then invalid_arg "send_all";
    let res = create () in
    let rec fwd () =
      read res >>= function
      | None -> Lwt.return_unit
      | Some x -> Lwt_list.iter_p (fun p -> write p x) l >>= fwd
    in
    (* do not GC before res dies; close res when any outputx is closed *)
    keep res (fwd ());
    List.iter (fun out -> link_close res ~after:out) l;
    res

  let send_both a b = send_all [a; b]
end

module Reader = struct
  type 'a t = ('a, [`r]) pipe

  let map ~f a =
    let b = create () in
    let rec fwd () =
      let fut = read a in
      Lwt.on_failure fut (fun _ -> close_nonblock b);
      fut >>= function
      | Some x -> write b (f x) >>= fwd
      | None -> close b
    in
    keep b (fwd());
    b

  let map_s ~f a =
    let b = create () in
    let rec fwd () =
      let fut = read a in
      Lwt.on_failure fut (fun _ -> close_nonblock b);
      fut >>= function
      | Some x -> f x >>= fun y -> write b y >>= fwd
      | None -> close b
    in
    keep b (fwd());
    b

  let filter ~f a =
    let b = create () in
    let rec fwd () =
      let fut = read a in
      Lwt.on_failure fut (fun _ -> close_nonblock b);
      fut >>= function
      | Some x -> if f x then write b x >>= fwd else fwd()
      | None -> close b
    in
    keep b (fwd());
    b

  let filter_map ~f a =
    let b = create () in
    let rec fwd () =
      let fut = read a in
      Lwt.on_failure fut (fun _ -> close_nonblock b);
      fut >>= function
      | Some x ->
        begin match f x with
          | None -> fwd()
          | Some y -> write b y >>= fwd
        end
      | None -> close b
    in
    keep b (fwd());
    b

  let rec fold ~f ~x t =
    read t
    >>= function
    | None -> Lwt.return x
    | Some y -> fold ~f ~x:(f x y) t

  let rec fold_s ~f ~x t =
    read t >>= function
    | None -> Lwt.return x
    | Some y ->
      f x y >>= fun x -> fold_s ~f ~x t

  let rec iter ~f t =
    read t >>= function
    | None -> Lwt.return_unit
    | Some x -> f x; iter ~f t

  let rec iter_s ~f t =
    read t >>= function
    | None -> Lwt.return_unit
    | Some x -> f x >>= fun () -> iter_s ~f t

  let iter_p ~f t =
    let rec iter acc =
      read t >>= function
      | None -> Lwt.join acc
      | Some x -> iter (f x :: acc)
    in iter []

  let merge_all l =
    if l = [] then invalid_arg "merge_all";
    let res = create () in
    List.iter (fun p -> connect p res) l;
    (* connect res' input to all members of l; close res when they all close *)
    link_close_l res ~after:l;
    res

  let merge_both a b = merge_all [a; b]

  let append a b =
    let c = create () in
    connect a c;
    Lwt.on_success (wait a)
      (fun () ->
         connect b c;
         link_close c ~after:b (* once a and b finished, c is too *)
      );
    c
end

(** {2 Conversions} *)

type 'a lwt_klist = [ `Nil | `Cons of 'a * 'a lwt_klist ] Lwt.t

let of_list l : _ Reader.t =
  let p = create ~max_size:0 () in
  keep p (Lwt_list.iter_s (write p) l >>= fun () -> close p);
  p

let of_array a =
  let p = create ~max_size:0 () in
  let rec send i =
    if i = Array.length a then close p
    else (
      write p a.(i) >>= fun () ->
      send (i+1)
    )
  in
  keep p (send 0);
  p

let of_string a =
  let p = create ~max_size:0 () in
  let rec send i =
    if i = String.length a then close p
    else (
      write p (String.get a i) >>= fun () ->
      send (i+1)
    )
  in
  keep p (send 0);
  p

let of_lwt_klist l =
  let p = create ~max_size:0 () in
  let rec next l =
    l >>= function
    | `Nil -> close p
    | `Cons (x, tl) ->
      write p x >>= fun () -> next tl
  in
  keep p (next l);
  p

let to_list_rev r =
  Reader.fold ~f:(fun acc x -> x :: acc) ~x:[] r

let to_list r = to_list_rev r >|= List.rev

let to_buffer buf r =
  Reader.iter ~f:(fun c -> Buffer.add_char buf c) r

let to_buffer_str ?(sep="") buf r =
  let first = ref true in
  Reader.iter r
    ~f:(fun s ->
        if !first then first:= false else Buffer.add_string buf sep;
        Buffer.add_string buf s)

let to_string r =
  let buf = Buffer.create 128 in
  to_buffer buf r >>= fun () -> Lwt.return (Buffer.contents buf)

let join_strings ?sep r =
  let buf = Buffer.create 128 in
  to_buffer_str ?sep buf r >>= fun () -> Lwt.return (Buffer.contents buf)

let to_lwt_klist r =
  let rec next () =
    read r >>= function
    | None -> Lwt.return `Nil
    | Some x -> Lwt.return (`Cons (x, next ()))
  in
  next ()

(** {2 Basic IO wrappers} *)

module IO = struct
  let read ?(bufsize=4096) ic : _ Reader.t =
    let buf = Bytes.make bufsize ' ' in
    let p = create ~max_size:0 () in
    let rec send() =
      Lwt_io.read_into ic buf 0 bufsize >>= fun n ->
      if n = 0 then close p
      else (
        write p (Bytes.sub_string buf 0 n) >>= fun () ->
        send ()
      )
    in Lwt.async send;
    p

  let read_lines ic =
    let p = create () in
    let rec send () =
      Lwt_io.read_line_opt ic >>= function
      | None -> close p
      | Some line -> write p line >>= fun () -> send ()
    in
    Lwt.async send;
    p

  let write oc =
    let p = create () in
    keep p (
      Reader.iter_s ~f:(Lwt_io.write oc) p >>= fun _ ->
      Lwt_io.flush oc >>= fun () ->
      close p
    );
    p

  let write_lines oc =
    let p = create () in
    keep p (
      Reader.iter_s ~f:(Lwt_io.write_line oc) p >>= fun _ ->
      Lwt_io.flush oc >>= fun () ->
      close p
    );
    p
end
