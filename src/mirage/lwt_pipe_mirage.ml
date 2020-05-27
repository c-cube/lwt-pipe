module Make (TIME : Mirage_time.S) (CHAN : Mirage_channel.S) = struct
  module P = Lwt_pipe.Make (struct
    open Lwt.Infix

    type input_channel = CHAN.t
    type output_channel = CHAN.t

    let sleep f = TIME.sleep_ns (Duration.of_f f)

    let read_into chan buf off len =
      CHAN.read_some ~len chan
      >>= function
        | Ok (`Data b) ->
            let n = Cstruct.len b in
            Cstruct.blit_to_bytes b 0 buf off n;
            Lwt.return n
        | Ok `Eof -> Lwt.return 0
        | Error err -> Lwt.fail_with (Format.asprintf "%a" CHAN.pp_error err)

    let read_line_opt chan =
      CHAN.read_line chan
      >>= function
        | Ok (`Data bufs) ->
            let line = Cstruct.copyv bufs in
            Lwt.return (Some line)
        | Ok `Eof -> Lwt.return None
        | Error err -> Lwt.fail_with (Format.asprintf "%a" CHAN.pp_error err)

    let write chan s =
      CHAN.write_string chan s 0 (String.length s);
      Lwt.return_unit

    let write_line chan s =
      CHAN.write_line chan s;
      Lwt.return_unit

    let flush chan =
      CHAN.flush chan
      >>= function
        | Ok () -> Lwt.return_unit
        | Error err -> Lwt.fail_with (Format.asprintf "%a" CHAN.pp_write_error err)
  end)

  include P
end
