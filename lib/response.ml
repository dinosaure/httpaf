type t = Response0.t =
  { version : Version.t
  ; status  : Status.t
  ; reason  : string
  ; headers : Headers.t }

let create ?reason ?(version=Version.v1_1) ?(headers=Headers.empty) status =
  let reason =
    match reason with
    | Some reason -> reason
    | None ->
      begin match status with
      | #Status.standard as status -> Status.default_reason_phrase status
      | `Code _                    -> "Non-standard status code"
      end
  in
  { version; status; reason; headers }

let persistent_connection ?proxy { version; headers } =
  Message.persistent_connection ?proxy version headers

let proxy_error  = `Error `Bad_gateway
let server_error = `Error `Internal_server_error
let body_length ?(proxy=false) ~request_method { status; headers } =
  match status, request_method with
  | (`No_content | `Not_modified), _           -> `Fixed 0L
  | s, _        when Status.is_informational s -> `Fixed 0L
  | s, `CONNECT when Status.is_successful s    -> `Close_delimited
  | _, _                                       ->
    begin match Headers.get_multi headers "transfer-encoding" with
    | "chunked"::_                             -> `Chunked
    | _        ::es when List.mem "chunked" es -> `Close_delimited
    | [] | _                                   ->
      begin match Message.unique_content_length_values headers with
      | []      -> `Close_delimited
      | [ len ] ->
        let len = Message.content_length_of_string len in
        if Int64.(len >= 0L)
        then `Fixed len
        else if proxy then proxy_error else server_error
      | _       ->
        if proxy then proxy_error else server_error
      end
    end

let pp_hum fmt { version; status; reason; headers } =
  Format.fprintf fmt "((version \"%a\") (status %a) (reason %S) (headers %a))"
    Version.pp_hum version Status.pp_hum status reason Headers.pp_hum headers

module Body = struct
  type t =
    { faraday                     : Faraday.t
    ; mutable when_ready_to_write : unit -> unit
    }

  let default_ready_to_write =
    Sys.opaque_identity (fun () -> ())

  let of_faraday faraday =
    { faraday
    ; when_ready_to_write = default_ready_to_write
    }

  let create buffer =
    of_faraday (Faraday.of_bigstring buffer)

  let unsafe_faraday t =
    t.faraday

  let write_char t c =
    Faraday.write_char t.faraday c

  let write_string t ?off ?len s =
    Faraday.write_string ?off ?len t.faraday s

  let write_bigstring t ?off ?len (b:Bigstring.t) =
  (* XXX(seliopou): there is a type annontation on bigstring because of bug
   * #1699 on the OASIS bug tracker. Once that's resolved, it should no longer
   * be necessary. *)
    Faraday.write_bigstring ?off ?len t.faraday b

  let schedule_string t ?off ?len s =
    Faraday.schedule_string ?off ?len t.faraday s

  let schedule_bigstring t ?off ?len (b:Bigstring.t) =
    Faraday.schedule_bigstring ?off ?len t.faraday b

  let ready_to_write t =
    let callback = t.when_ready_to_write in
    t.when_ready_to_write <- default_ready_to_write;
    callback ()

  let flush t kontinue =
    Faraday.flush t.faraday kontinue;
    ready_to_write t

  let close t =
    Faraday.close t.faraday;
    ready_to_write t

  let is_closed t =
    Faraday.is_closed t.faraday

  let has_pending_output t =
    Faraday.has_pending_output t.faraday

  let when_ready_to_write t callback =
    if is_closed t then callback ();
    if t.when_ready_to_write == default_ready_to_write then failwith "Response.Body: closed";
    t.when_ready_to_write <- callback
end
