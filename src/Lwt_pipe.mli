
(* This file is free software. See file "license" for more details. *)

(** {1 Pipes, Readers, Writers}

  Stream processing using:

  - Pipe: a possibly buffered channel that can act as a reader or as a writer
  - Reader: accepts values, produces effects
  - Writer: yield values

    Examples:
    {[
      #require "lwt";;

      module P = Lwt_pipe;;

      let p1 =
        P.of_list CCList.(1 -- 100)
        |> P.Reader.map ~f:string_of_int;;

      Lwt_io.with_file ~mode:Lwt_io.output "/tmp/foo"
        (fun oc ->
           let p2 = P.IO.write_lines oc in
           P.connect ~ownership:`InOwnsOut p1 p2;
           P.wait p2
        );;
    ]}

    {b status: experimental}
*)

exception Closed

type ('a, +'perm) t constraint 'perm = [< `r | `w]
(** A pipe between producers of values of type 'a, and consumers of values
    of type 'a. *)

type ('a, 'perm) pipe = ('a, 'perm) t

val keep : (_,_) t -> unit Lwt.t -> unit
(** [keep p fut] adds a pointer from [p] to [fut] so that [fut] is not
    garbage-collected before [p] *)

val is_closed : (_,_) t -> bool

val close : (_,_) t -> unit Lwt.t
(** [close p] closes [p], which will not accept input anymore.
    This sends [End] to all readers connected to [p] *)

val close_nonblock : _ t -> unit
(** Same as {!close} but does not wait for completion of dependent tasks *)

val wait : (_,_) t -> unit Lwt.t
(** Evaluates once the pipe closes *)

val create : ?on_close:(unit -> unit) -> ?max_size:int -> unit -> ('a, 'perm) t
(** Create a new pipe.
    @param on_close called when the pipe is closed
    @param max_size size of internal buffer. Default 0. *)

val connect : ?ownership:[`None | `InOwnsOut | `OutOwnsIn] ->
              ('a, [>`r]) t -> ('a, [>`w]) t -> unit
(** [connect p1 p2] forwards every item output by [p1] into [p2]'s input
    until [p1] is closed.
    @param own determines which pipes owns which (the owner, when it
      closes, also closes the ownee) *)

val link_close : (_,_) t -> after:(_,_) t -> unit
(** [link_close p ~after] will close [p] when [after] closes.
    if [after] is closed already, closes [p] immediately *)

val read : ('a, [>`r]) t -> 'a option Lwt.t
(** Read the next value from a Pipe *)

val write : ('a, [>`w]) t -> 'a -> unit Lwt.t
(** @raise Closed if the writer is closed *)

val write_list : ('a, [>`w]) t -> 'a list -> unit Lwt.t
(** @raise Closed if the writer is closed *)

val to_stream : ('a, [>`r]) t -> 'a Lwt_stream.t
(** [to_stream p] returns a stream with the content from [p].  The
    stream will close when [p] closes. *)

val of_stream : 'a Lwt_stream.t -> ('a, [>`r]) t
(** [of_stream s] reads from [s].  The returned pipe will close when
    [s] closes. *)

(** {2 Write-only Interface and Combinators} *)

module Writer : sig
  type 'a t = ('a, [`w]) pipe

  val map : f:('a -> 'b) -> ('b, [>`w]) pipe -> 'a t
  (** Map values before writing them *)

  val send_both : 'a t -> 'a t -> 'a t
  (** [send_both a b] returns a writer [c] such that writing to [c]
      writes to [a] and [b], and waits for those writes to succeed
      before returning *)

  val send_all : 'a t list -> 'a t
  (** Generalized version of {!send_both}
      @raise Invalid_argument if the list is empty *)
end

(** {2 Read-only Interface and Combinators} *)

module Reader : sig
  type 'a t = ('a, [`r]) pipe

  val map : f:('a -> 'b) -> ('a, [>`r]) pipe -> 'b t

  val map_s : f:('a -> 'b Lwt.t) -> ('a, [>`r]) pipe -> 'b t

  val filter : f:('a -> bool) -> ('a, [>`r]) pipe -> 'a t

  val filter_map : f:('a -> 'b option) -> ('a, [>`r]) pipe -> 'b t

  val filter_map_s : f:('a -> 'b option Lwt.t) -> ('a, [>`r]) pipe -> 'b t

  val flat_map : f:('a -> 'b list) -> ('a, [>`r]) pipe -> 'b t 

  val flat_map_s : f:('a -> 'b list Lwt.t) -> ('a, [>`r]) pipe -> 'b t 

  val fold : f:('acc -> 'a -> 'acc) -> x:'acc -> ('a, [>`r]) pipe -> 'acc Lwt.t

  val fold_s : f:('acc -> 'a -> 'acc Lwt.t) -> x:'acc -> ('a, [>`r]) pipe -> 'acc Lwt.t

  val iter : f:('a -> unit) -> 'a t -> unit Lwt.t

  val iter_s : f:('a -> unit Lwt.t) -> 'a t -> unit Lwt.t

  val iter_p : f:('a -> unit Lwt.t) -> 'a t -> unit Lwt.t

  val merge_both : 'a t -> 'a t -> 'a t
  (** Merge the two input streams in a non-specified order *)

  val merge_all : 'a t list -> 'a t
  (** Merge all the input streams
      @raise Invalid_argument if the list is empty *)

  val append : 'a t -> 'a t -> 'a t
  (** [append a b] reads from [a] until [a] closes, then reads from [b]
      and closes when [b] closes *)
end

(** {2 Conversions} *)

type 'a lwt_klist = [ `Nil | `Cons of 'a * 'a lwt_klist ] Lwt.t

val of_list : 'a list -> 'a Reader.t

val of_array : 'a array -> 'a Reader.t

val of_string : string -> char Reader.t

val of_lwt_klist : 'a lwt_klist -> 'a Reader.t

val to_list_rev : ('a,[>`r]) t -> 'a list Lwt.t

val to_list : ('a,[>`r]) t -> 'a list Lwt.t

val to_buffer : Buffer.t -> (char ,[>`r]) t -> unit Lwt.t

val to_buffer_str : ?sep:string -> Buffer.t -> (string, [>`r]) t -> unit Lwt.t

val to_string : (char, [>`r]) t -> string Lwt.t

val join_strings  : ?sep:string -> (string, [>`r]) t -> string Lwt.t

val to_lwt_klist : 'a Reader.t -> 'a lwt_klist
(** Iterates on the reader. Errors are ignored (but stop the list). *)

(** {2 Basic IO wrappers} *)

module IO : sig
  val read : ?bufsize:int -> Lwt_io.input_channel -> string Reader.t

  val read_lines : Lwt_io.input_channel -> string Reader.t

  val write : Lwt_io.output_channel -> string Writer.t

  val write_lines : Lwt_io.output_channel -> string Writer.t
end
