(* This file is free software. See file "license" for more details. *)
module type IO = sig
  type input_channel
  type output_channel

  val sleep : float -> unit Lwt.t

  val read_into : input_channel -> Bytes.t -> int -> int -> int Lwt.t
  val read_line_opt : input_channel -> string option Lwt.t

  val write : output_channel -> string -> unit Lwt.t
  val write_line : output_channel -> string -> unit Lwt.t

  val flush : output_channel -> unit Lwt.t
end

module Make : functor(IO : IO) ->
  Lwt_pipe_intf.S
    with type input_channel := IO.input_channel
     and type output_channel := IO.output_channel
