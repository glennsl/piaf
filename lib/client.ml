(*
 * - Follow redirects (assumes upgrading to https too)
 * - Functions for persistent / oneshot connections
 * - Logging
 * *)
open Monads
module Version = Httpaf.Version

module SSL = struct
  let () =
    Ssl_threads.init ();
    Ssl.init ()

  let default_ctx = Ssl.create_context Ssl.SSLv23 Ssl.Client_context

  let () =
    Ssl.disable_protocols default_ctx [ Ssl.SSLv23 ];
    (* Ssl.set_context_alpn_protos default_ctx [ "h2" ]; *)
    Ssl.honor_cipher_order default_ctx

  let connect ?(ctx = default_ctx) ?src ?hostname sa fd =
    let open Lwt.Syntax in
    let* () =
      match src with
      | None ->
        Lwt.return_unit
      | Some src_sa ->
        Lwt_unix.bind fd src_sa
    in
    let* () = Lwt_unix.connect fd sa in
    match hostname with
    | Some host ->
      let s = Lwt_ssl.embed_uninitialized_socket fd ctx in
      let ssl_sock = Lwt_ssl.ssl_socket_of_uninitialized_socket s in
      Ssl.set_client_SNI_hostname ssl_sock host;
      (* TODO: Configurable protos *)
      Ssl.set_alpn_protos ssl_sock [ "h2"; "http/1.1" ];
      Lwt_ssl.ssl_perform_handshake s
    | None ->
      Lwt_ssl.ssl_connect fd ctx
end

module Scheme = struct
  type t =
    | HTTP
    | HTTPS

  let of_uri uri =
    match Uri.scheme uri with
    | None | Some "http" ->
      Ok HTTP
    | Some "https" ->
      Ok HTTPS
    (* We don't support anything else *)
    | Some other ->
      Error (Format.asprintf "Unsupported scheme: %s" other)

  let to_string = function HTTP -> "http" | HTTPS -> "https"
end

let infer_port ~scheme uri =
  match Uri.port uri, scheme with
  (* if a port is given, use it. *)
  | Some port, _ ->
    port
  (* Otherwise, infer from the scheme. *)
  | None, Scheme.HTTPS ->
    443
  | None, HTTP ->
    80

let resolve_host ~port hostname =
  let open Lwt.Syntax in
  let+ addresses =
    Lwt_unix.getaddrinfo
      hostname
      (string_of_int port)
      (* https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml *)
      Unix.[ AI_CANONNAME; AI_PROTOCOL 6; AI_FAMILY PF_INET ]
  in
  match addresses with
  | [] ->
    Error "Can't resolve hostname"
  | { Unix.ai_addr; _ } :: _ ->
    (* TODO: add resolved canonical hostname *)
    Ok ai_addr

module Headers = struct
  let add_canonical_headers ~host ~version headers =
    match version with
    | { Version.major = 2; _ } ->
      H2.Headers.of_list ((":authority", host) :: headers)
    | { Version.major = 1; _ } ->
      H2.Headers.of_list (("Host", host) :: headers)
    | _ ->
      failwith "unsupported version"
end

let make_impl ~scheme ~address ~host fd =
  let open Lwt.Syntax in
  match scheme with
  | Scheme.HTTP ->
    let+ () = Lwt_unix.connect fd address in
    (* TODO: we should also be able to support HTTP/2 with prior knowledge /
       HTTP/1.1 upgrade. For now, insecure HTTP/2 is unsupported. *)
    (module Http1.HTTP : S.HTTPCommon), Request.v1_1
  | HTTPS ->
    let+ ssl_client = SSL.connect ~hostname:host address fd in
    (match Lwt_ssl.ssl_socket ssl_client with
    | None ->
      failwith "handshake not established?"
    | Some ssl_socket ->
      let (module Https), version =
        match Ssl.get_negotiated_alpn_protocol ssl_socket with
        (* Default to HTTP/1.x if the remote doesn't speak ALPN. *)
        | None | Some "http/1.1" ->
          (module Http1.HTTPS : S.HTTPS), Request.v1_1
        | Some "h2" ->
          (module Http2.HTTPS : S.HTTPS), Request.v2_0
        | Some _ ->
          (* Can't really happen - would mean that TLS negotiated a
           * protocol that we didn't specify. *)
          assert false
      in
      let module Https = struct
        (* TODO: I think this is only valid since OCaml 4.08 *)
        include Https

        module Client = struct
          include Https.Client

          (* partially apply the `create_connection` function so that we can
           * reuse the HTTPCommon interface *)
          let create_connection = Client.create_connection ~client:ssl_client
        end
      end
      in
      (module Https : S.HTTPCommon), version)

module Connection_info = struct
  (* This represents information that changes from connection to connection,
   * i.e.  if one of these parameters changes between redirects we need to
   * establish a new connection. *)
  type t =
    { port : int
    ; scheme : Scheme.t
    ; host : string
    ; address : Unix.sockaddr
    }

  (* Only need the address and port to know whether the endpoint is the same or
   * not. *)
  let equal c1 c2 =
    c1.port = c2.port
    &&
    match c1.address, c2.address with
    | ADDR_INET (addr1, _), ADDR_INET (addr2, _) ->
      String.equal
        (Unix.string_of_inet_addr addr1)
        (Unix.string_of_inet_addr addr2)
    | ADDR_UNIX addr1, ADDR_UNIX addr2 ->
      String.equal addr1 addr2
    | _ ->
      false

  (* Use this shortcut to avoid resolving the new address. Not 100% correct
   * because different hosts may point to the same address. *)
  let equal_without_resolving c1 c2 =
    c1.port = c2.port && c1.scheme = c2.scheme && c1.host = c2.host

  let of_uri uri =
    let open Lwt_result.Syntax in
    let uri = Uri.canonicalize uri in
    let host = Uri.host_with_default uri in
    let* scheme = Lwt.return (Scheme.of_uri uri) in
    let port = infer_port ~scheme uri in
    let+ address = resolve_host ~port host in
    { scheme; host; port; address }
end

type t =
  | Conn :
      { impl : (module S.HTTPCommon with type Client.t = 'a)
      ; conn : 'a
      ; conn_info : Connection_info.t
      ; version : Version.t
      ; uri : Uri.t
      ; config : Config.t
      }
      -> t

let open_connection ~config ~conn_info uri =
  let open Lwt.Syntax in
  let { Connection_info.host; scheme; address; _ } = conn_info in
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Format.eprintf "hst : %s %s@." host (Uri.path_and_query uri);
  let* (module HTTPImpl : S.HTTPCommon), version =
    make_impl ~scheme ~address ~host fd
  in
  let+ conn = HTTPImpl.Client.create_connection fd in
  Ok (Conn { impl = (module HTTPImpl); conn; version; uri; conn_info; config })

let rec build_request_and_handle_response
    ~meth
    ~headers
    ?body
    (Conn
      ({ impl = (module HTTPImpl); conn; version; conn_info; config; uri; _ } as
      t))
  =
  let open Lwt_result.Syntax in
  let { Connection_info.host; scheme; _ } = conn_info in
  let canonical_headers =
    Headers.add_canonical_headers ~version ~host headers
  in
  let request =
    Request.create
      meth
      ~version
      ~scheme:(Scheme.to_string scheme)
      ~headers:canonical_headers
      (Uri.path_and_query uri)
  in
  let* response, response_body =
    Http_impl.send_request (module HTTPImpl) conn ?body request
  in
  let open Lwt.Syntax in
  (* TODO: 201 created can also return a Location header. Should we follow
   * those? *)
  (* TODO: redirects left? *)
  match
    ( config.follow_redirects
    , H2.Status.is_redirection response.status
    , H2.Headers.get response.headers "location" )
  with
  | true, true, Some location ->
    (* TODO: do this in an Lwt.async call if HTTP/2 / HTTP/1.1 pipelining? *)
    let* () = Http_impl.drain_stream response_body in
    let location_uri = Uri.of_string location in
    let new_uri, new_host =
      match Uri.host location_uri with
      | Some new_host ->
        location_uri, new_host
      | None ->
        (* relative URI, replace the path and query on the old URI. *)
        Uri.resolve (Scheme.to_string scheme) uri location_uri, host
    in
    let open Lwt_result.Syntax in
    let* new_scheme = Lwt.return (Scheme.of_uri new_uri) in
    let new_conn_info =
      { conn_info with
        port = infer_port ~scheme:new_scheme new_uri
      ; scheme = new_scheme
      ; host = new_host
      }
    in
    let* new_t =
      if Connection_info.equal_without_resolving conn_info new_conn_info then
        (* If we're redirecting within the same host / port / scheme, no need
         * to re-establish a new connection. *)
        Lwt_result.return (Conn { t with uri = new_uri })
      else
        let* new_address =
          resolve_host ~port:new_conn_info.port new_conn_info.host
        in
        (* Now we know the new address *)
        let new_conn_info = { new_conn_info with address = new_address } in
        (* Really avoiding having to establish a new connection here. If the
         * new host resolves to the same address and the port matches *)
        if Connection_info.equal conn_info new_conn_info then
          Lwt_result.return
            (Conn { t with uri = new_uri; conn_info = new_conn_info })
        else (
          (* No way to avoid establishing a new connection. *)
          HTTPImpl.Client.shutdown conn;
          open_connection ~config ~conn_info:new_conn_info new_uri)
    in
    build_request_and_handle_response ~meth ~headers ?body new_t
  | true, true, None ->
    failwith "Redirect without Location header?"
  | _ ->
    Lwt_result.return response

let call ~config ~meth ~headers ?body uri =
  let open Lwt_result.Syntax in
  let* conn_info = Connection_info.of_uri uri in
  let* connection = open_connection ~config ~conn_info uri in
  build_request_and_handle_response ~meth ~headers ?body connection

let get ?(config = Config.default_config) ?(headers = []) uri =
  call ~config ~meth:`GET ~headers uri
