include Lwt_pipe.Make (struct
  type input_channel = Lwt_io.input_channel
  type output_channel = Lwt_io.output_channel

  let sleep = Lwt_unix.sleep

  let read_into = Lwt_io.read_into
  let read_line_opt = Lwt_io.read_line_opt

  let write = Lwt_io.write
  let write_line = Lwt_io.write_line

  let flush = Lwt_io.flush
end)
