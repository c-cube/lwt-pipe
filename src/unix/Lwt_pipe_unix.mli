include Lwt_pipe_intf.S
  with type input_channel := Lwt_io.input_channel
   and type output_channel := Lwt_io.output_channel
