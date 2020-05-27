module Make :
  functor (TIME : Mirage_time.S) (CHAN : Mirage_channel.S) ->
    Lwt_pipe_intf.S
      with type input_channel := CHAN.t
       and type output_channel := CHAN.t
