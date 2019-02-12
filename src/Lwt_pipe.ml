
(* This file is free software. See file "license" for more details. *)

open Lwt.Infix

exception Closed

type 'a read_timeout_result =
  | Pipe_closed
  | Nothing_available
  | Timeout
  | Data_available of 'a

type 'a reader = {
  r_wakeup: 'a read_timeout_result Lwt.u;
  mutable r_timeout: bool;
}

type ('a, +'perm) t = {
  close : unit Lwt.u;
  closed : unit Lwt.t;
  mutable stopped: bool; (* if true, no more input will come *)
  readers : 'a reader Queue.t;  (* blocked readers *)
  buf : 'a Queue.t; (* internal buffers of written values *)
  blocked_writers : ('a * bool Lwt.u) Queue.t; (* blocked writers *)
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
    stopped=false;
    readers = Queue.create ();
    buf = Queue.create ();
    blocked_writers = Queue.create ();
    max_size;
    keep=[];
  }

let keep p fut = p.keep <- fut :: p.keep
let wait p = p.closed
let is_closed p = not (Lwt.is_sleeping p.closed)

let close_ p =
  if not p.stopped then (
    assert (not (is_closed p));
    p.stopped <- true;
    assert (Queue.is_empty p.readers || Queue.is_empty p.buf);
    Queue.iter
      (fun {r_wakeup;_} -> Lwt.wakeup r_wakeup Pipe_closed)
      p.readers;
    Queue.iter (fun (_,r) -> Lwt.wakeup r false) p.blocked_writers;
    if Queue.length p.buf = 0 then (
      Lwt.wakeup p.close (); (* close immediately *)
    );
  )

let close_nonblock p =
  if not p.stopped then (
    close_ p
  )

let close p =
  if not p.stopped then (
    close_nonblock p;
    p.closed >>= fun () ->
    Lwt.join p.keep
  ) else (
    p.closed
  )

let opt_of_available = function
  | Data_available x -> Some x
  | _ -> None

let read_ t ~timeout : 'a read_timeout_result Lwt.t =
  let timeout_function s (r:_ reader) =
    Lwt_unix.sleep s >>= fun () ->
    r.r_timeout <- true;
    Lwt.return Timeout
  in
  if not (Queue.is_empty t.buf) then (
    let x = Queue.pop t.buf in
    (* some writer may unblock *)
    if not (Queue.is_empty t.blocked_writers) && Queue.length t.buf < t.max_size then (
      let y, signal_done = Queue.pop t.blocked_writers in
      Queue.push y t.buf;
      Lwt.wakeup signal_done true;
    );
    Lwt.return (Data_available x)
  ) else if t.stopped then (
    (* empty buf + stopped *)
    close_nonblock t;
    Lwt.return Pipe_closed
  ) else if Queue.is_empty t.blocked_writers then (
    let fut, r_wakeup = Lwt.wait () in
    let r = {r_wakeup; r_timeout=false} in
    Queue.push r t.readers;
    match timeout with
    | None -> fut
    | Some s -> Lwt.pick [fut; timeout_function s r]
  ) else (
    assert (t.max_size = 0);
    let x, signal_done = Queue.pop t.blocked_writers in
    Lwt.wakeup signal_done true;
    Lwt.return (Data_available x)
  )

let read_with_timeout t ~timeout =
  read_ t ~timeout

let read t =
  read_ t ~timeout:None >|= opt_of_available

let enqueue_into_writers t x =
  if Queue.length t.buf < t.max_size then (
    Queue.push x t.buf;
    Lwt.return true (* into buffer, do not wait *)
  ) else (
    (* block until the queue isn't full anymore *)
    let is_done, signal_done = Lwt.wait () in
    Queue.push (x, signal_done) t.blocked_writers;
    is_done
  )

(* write a value *)
let rec write_rec_ (t:('a,_) pipe) (x:'a) =
  if t.stopped then (
    Lwt.return_false
  ) else if Queue.length t.readers > 0 then (
    (* some reader waits, synchronize now *)
    let r = Queue.pop t.readers in
    if r.r_timeout then (
      (* if timeout occurred the corresponding reader has already received
         a Timeout value and shoud be discarded. The value [x] is processed
         again by [write_step] *)
      write_rec_ t x
    ) else (
      (* timeout = false *)
      Lwt.wakeup r.r_wakeup (Data_available x);
      Lwt.return true
    )
  ) else (
    enqueue_into_writers t x
  )

let rec connect_rec r w =
  read_with_timeout ~timeout:None r >>= function
  | Data_available x ->
    write_rec_ w x >>= fun ok ->
    if ok then connect_rec r w else Lwt.return_unit
  | _ -> Lwt.return_unit

(* close a when b closes *)
let link_close p ~after =
  Lwt.on_termination after.closed
    (fun _ -> close_nonblock p)

let connect ?(ownership=`None) a b =
  let fut = connect_rec a b in
  keep b fut;
  match ownership with
  | `None -> ()
  | `InOwnsOut -> Lwt.on_termination fut (fun () -> close_nonblock b)
  | `OutOwnsIn -> Lwt.on_termination fut (fun () -> close_nonblock a)

let write_exn t x =
  write_rec_ t x >>= fun ok ->
  if ok then Lwt.return_unit
  else Lwt.fail Closed

let write = write_rec_

let rec write_list t l = match l with
  | [] -> Lwt.return true
  | x :: tail ->
    let fut = write t x in
    fut >>= fun b ->
    if b then write_list t tail else fut

let write_list_exn t l =
  write_list t l >>= fun ok ->
  if ok then Lwt.return_unit
  else Lwt.fail Closed

let to_stream p =
  Lwt_stream.from (fun () -> read p)

let of_stream s =
  let p = create () in
  let fut = Lwt_stream.iter_s (write_exn p) s >>= fun () -> close p in
  keep p fut;
  Lwt.on_termination fut (fun () -> close_nonblock p);
  p

module Writer = struct
  type 'a t = ('a, [`w]) pipe

  let map ~f a =
    let b = create() in
    let rec fwd_rec () =
      read b >>= function
      | Some x ->
        write a (f x) >>= fun ok ->
        if ok then fwd_rec () else Lwt.return_unit
      | None -> Lwt.return_unit
    in
    let fwd = fwd_rec() in
    keep b fwd;
    (* when [fwd_rec] stops because a gets closed, close b too *)
    Lwt.on_termination fwd (fun () -> close_nonblock b);
    b

  let send_all l =
    if l = [] then invalid_arg "send_all";
    let res = create () in
    let rec fwd () =
      read res >>= function
      | None -> Lwt.return_unit
      | Some x -> Lwt_list.iter_p (fun p -> write_exn p x) l >>= fwd
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
    let rec fwd_rec () =
      read a >>= function
      | Some x ->
        write b (f x) >>= fun ok -> 
        if ok then fwd_rec () else Lwt.return_unit
      | None -> Lwt.return_unit
    in
    let fwd = fwd_rec() in
    keep b fwd;
    Lwt.on_termination fwd (fun () -> close_nonblock b);
    b

  let map_s ~f a =
    let b = create () in
    let rec fwd_rec () =
      read a >>= function
      | Some x ->
        f x >>= fun y ->
        write b y >>= fun ok ->
        if ok then fwd_rec () else Lwt.return_unit
      | None -> Lwt.return_unit
    in
    let fwd = fwd_rec() in
    keep b fwd;
    Lwt.on_termination fwd (fun () -> close_nonblock b);
    b

  let filter ~f a =
    let b = create () in
    let rec fwd_rec () =
      read a >>= function
      | Some x ->
        if f x then (
          write b x >>= fun ok ->
          if ok then fwd_rec () else Lwt.return_unit
        ) else fwd_rec()
      | None -> Lwt.return_unit
    in
    let fwd = fwd_rec() in
    keep b fwd;
    Lwt.on_termination fwd (fun () -> close_nonblock b);
    b

  let filter_map ~f a =
    let b = create () in
    let rec fwd_rec () =
      read a >>= function
      | Some x ->
        begin match f x with
          | None -> fwd_rec()
          | Some y ->
            write b y >>= fun ok ->
            if ok then fwd_rec () else Lwt.return_unit
        end
      | None -> close b
    in
    let fwd = fwd_rec() in
    keep b fwd;
    Lwt.on_termination fwd (fun () -> close_nonblock b);
    b

  let filter_map_s ~f a =
    let b = create () in
    let rec fwd_rec () =
      read a >>= function
      | Some x ->
        f x >>= (function
          | None -> fwd_rec()
          | Some y ->
            write b y >>= fun ok ->
            if ok then fwd_rec () else Lwt.return_unit
        )
      | None -> Lwt.return_unit
    in
    let fwd = fwd_rec() in
    keep b fwd;
    Lwt.on_termination fwd (fun () -> close_nonblock b);
    b

  let flat_map ~f a =
    let b = create () in
    let rec fwd_rec () =
      read a >>= function
      | Some x ->
        let l = f x in
        write_list b l >>= fun ok ->
        if ok then fwd_rec () else Lwt.return_unit
      | None -> Lwt.return_unit
    in
    let fwd = fwd_rec() in
    keep b fwd;
    Lwt.on_termination fwd (fun () -> close_nonblock b);
    b

  let flat_map_s ~f a =
    let b = create () in
    let rec fwd_rec () =
      read a >>= function
      | Some x ->
        f x >>= fun l ->
        write_list b l >>= fun ok ->
        if ok then fwd_rec () else Lwt.return_unit
      | None -> Lwt.return_unit
    in
    let fwd = fwd_rec() in
    keep b fwd;
    Lwt.on_termination fwd (fun () -> close_nonblock b);
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

  (* util to find in lists *)
  let find_map_l f l =
    let rec aux f = function
      | [] -> None
      | x::l' ->
        match f x with
          | Some _ as res -> res
          | None -> aux f l'
    in aux f l

  let iter_p ~f t =
    let rec iter acc =
      read t >>= function
      | None -> Lwt.join acc
      | Some x ->
        (* did any computation fail? *)
        let maybe_err =
          find_map_l
            (fun t -> match Lwt.state t with
               | Lwt.Fail e -> Some e | _ -> None)
            acc
        in
        begin match maybe_err with
          | None ->
            (* continue, removing  from [acc] the already terminated functions *)
            let acc = List.filter (fun t -> Lwt.state t <> Lwt.Sleep) acc in
            iter (f x :: acc)
          | Some e -> Lwt.fail e
        end
    in iter []

  let merge_all l =
    if l = [] then invalid_arg "merge_all";
    let res = create () in
    let conns = List.map (fun p -> connect_rec p res) l in
    (* when [conns] all done, close [res] *)
    res.keep <- conns;
    Lwt.async
      (fun () -> Lwt.join conns >>= fun () -> close res);
    res

  let merge_both a b = merge_all [a; b]

  let append a b =
    let c = create () in
    connect a c;
    Lwt.on_success (wait a)
      (fun () ->
         let fut = connect_rec b c in
         keep c fut;
         Lwt.on_termination fut (fun () -> close_nonblock c);
      );
    c
end

(** {2 Conversions} *)

type 'a lwt_klist = [ `Nil | `Cons of 'a * 'a lwt_klist ] Lwt.t

let of_list l : _ Reader.t =
  let p = create ~max_size:0 () in
  let fut = Lwt_list.iter_s (write_exn p) l in
  keep p fut;
  Lwt.on_termination fut (fun () -> close_nonblock p);
  p

let of_array a =
  let p = create ~max_size:0 () in
  let rec send i =
    if i = Array.length a then close p
    else (
      write p a.(i) >>= fun ok ->
      if ok then send (i+1) else Lwt.return_unit
    )
  in
  let fut = send 0 in
  keep p fut;
  Lwt.on_termination fut (fun () -> close_nonblock p);
  p

let of_string a =
  let p = create ~max_size:0 () in
  let rec send i =
    if i < String.length a then (
      write p (String.get a i) >>= fun ok ->
      if ok then send (i+1) else Lwt.return_unit
    ) else Lwt.return_unit
  in
  keep p (send 0);
  p

let of_lwt_klist l =
  let p = create ~max_size:0 () in
  let rec next l =
    l >>= function
    | `Nil -> Lwt.return_unit
    | `Cons (x, tl) ->
      write p x >>= fun ok ->
      if ok then next tl else Lwt.return_unit
  in
  let fut = next l in
  keep p fut;
  Lwt.on_termination fut (fun () -> close_nonblock p);
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
      if n = 0 then (
        Lwt.return_unit
      ) else (
        write p (Bytes.sub_string buf 0 n) >>= fun ok ->
        if ok then send () else Lwt.return_unit
      )
    in
    let fut = send () in
    keep p fut;
    Lwt.on_termination fut (fun () -> close_nonblock p);
    p

  let read_lines ic =
    let p = create () in
    let rec send () =
      Lwt_io.read_line_opt ic >>= function
      | None -> Lwt.return_unit
      | Some line ->
        write p line >>= fun ok ->
        if ok then send() else Lwt.return_unit
    in
    let fut = send () in
    keep p fut;
    Lwt.on_termination fut (fun () -> close_nonblock p);
    p

  let write oc =
    let p = create () in
    let fut =
      Reader.iter_s ~f:(Lwt_io.write oc) p >>= fun _ ->
      Lwt_io.flush oc
    in
    keep p fut;
    Lwt.on_termination fut (fun () -> close_nonblock p);
    p

  let write_lines oc =
    let p = create () in
    let fut =
      Reader.iter_s ~f:(Lwt_io.write_line oc) p >>= fun _ ->
      Lwt_io.flush oc >>= fun () ->
      close p
    in
    keep p fut;
    Lwt.on_termination fut (fun () -> close_nonblock p);
    p
end
