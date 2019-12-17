(*----------------------------------------------------------------------------
 * Copyright (c) 2019, António Nuno Monteiro
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 *    contributors may be used to endorse or promote products derived from
 *    this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *---------------------------------------------------------------------------*)

open Monads
module IOVec = H2.IOVec

type length =
  [ `Fixed of Int64.t
  | `Chunked
  | `Error of [ `Bad_request | `Bad_gateway | `Internal_server_error ]
  | `Unknown
  | `Close_delimited
  ]

type stream =
  [ `Empty
  | `String of string
  | `Stream of Bigstringaf.t IOVec.t Lwt_stream.t
  ]

type t =
  { length : length
  ; body : stream
  }

let create ~body_length body = { length = body_length; body }

let empty = create ~body_length:(`Fixed 0L) `Empty

let of_stream ?(length = `Unknown) stream =
  create ~body_length:length (`Stream stream)

let of_string_stream ?(length = `Unknown) stream =
  let stream =
    Lwt_stream.map
      (fun s ->
        let len = String.length s in
        { IOVec.buffer = Bigstringaf.of_string ~off:0 ~len s; off = 0; len })
      stream
  in
  create ~body_length:length (`Stream stream)

let of_string s =
  let body_length = `Fixed (Int64.of_int (String.length s)) in
  create ~body_length (`String s)

let to_stream { body; _ } =
  match body with
  | `Empty ->
    Lwt_stream.of_list []
  | `String s ->
    Lwt_stream.of_list [ Bigstringaf.of_string ~off:0 ~len:(String.length s) s ]
  | `Stream stream ->
    Lwt_stream.map (fun { IOVec.buffer; _ } -> buffer) stream

let to_string { body; length } =
  match body with
  | `Empty ->
    Lwt.return ""
  | `String s ->
    Lwt.return s
  | `Stream stream ->
    let open Lwt.Syntax in
    let len =
      match length with
      | `Fixed n ->
        Int64.to_int n
      | _ ->
        (* TODO: use some config? *)
        100
    in
    let result_buffer = Buffer.create len in
    let+ () =
      Lwt_stream.iter
        (fun { IOVec.buffer; off; len } ->
          let bytes = Bytes.create len in
          Bigstringaf.blit_to_bytes buffer ~src_off:off ~dst_off:0 ~len bytes;
          Buffer.add_bytes result_buffer bytes)
        stream
    in
    Buffer.contents result_buffer

let to_string_stream { body; _ } =
  match body with
  | `Empty ->
    Lwt_stream.of_list []
  | `String s ->
    Lwt_stream.of_list [ s ]
  | `Stream stream ->
    Lwt_stream.map
      (fun { IOVec.buffer; off; len } -> Bigstringaf.substring buffer ~off ~len)
      stream

let drain { body; _ } =
  match body with
  | `Empty | `String _ ->
    Lwt.return_unit
  | `Stream stream ->
    Lwt_stream.junk_while (fun _ -> true) stream

let drain_available { body; _ } =
  match body with
  | `Empty | `String _ ->
    Lwt.return_unit
  | `Stream stream ->
    Lwt_stream.junk_old stream