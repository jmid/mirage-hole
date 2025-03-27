
let argument_error = 64

(* a default/fall-back blocking URL *)
let url = "https://blocklistproject.github.io/Lists/tracking.txt"

open Cmdliner

let src = Logs.Src.create "unikernel" ~doc:"Main unikernel code"
module Log = (val Logs.src_log src : Logs.LOG)

let dns_cache =
  let doc = Arg.info ~doc:"DNS cache size" ["dns-cache"] in
  Mirage_runtime.register_arg Arg.(value & opt int 0 doc)

let blocklist_url =
  let doc = Arg.info ~doc:"URL to fetch the blocked list of domains from" ["blocklist-url"] in
  Mirage_runtime.register_arg Arg.(value & opt string url doc)

module Main
    (S : Tcpip.Stack.V4V6)
    (HTTP : Http_mirage_client.S) = struct

  module Stub = Dns_stub_mirage.Make(S)

  let is_ip_address str =
    try ignore (Ipaddr.V4.of_string_exn str); true
    with Ipaddr.Parse_error (_,_) -> false

  (* a simple parser of files in the common blocking list format:
       # comment
       0.0.0.0 evil-domain.com *)
  let parse_domain_file str =
    let lines = String.split_on_char '\n' str in
    let lines = List.filter (fun l -> l <> "" && not (String.starts_with ~prefix:"#" l)) lines in
    List.filter_map (fun l -> match String.split_on_char ' ' l with
        | [ ip; dom_name ] ->
          if is_ip_address dom_name
          then (Logs.warn (fun m -> m "ip address in hostname position: \"%s\"" l); None)
          else
          if String.equal "0.0.0.0" ip
          then Some dom_name
          else (Logs.warn (fun m -> m "non-0.0.0.0 ip in input file: %s" l); Some dom_name)
        | _ -> Logs.warn (fun m -> m "unexpected input line format: \"%s\"" l); None)
      lines

  (* declare these pairs up front, so that they'll only be allocated once *)
  let ipv6_pair = (3600l,Ipaddr.V6.(Set.singleton localhost))
  let ipv4_pair = (3600l,Ipaddr.V4.(Set.singleton localhost))
  let soa       = (Dns.Soa.create (Domain_name.of_string_exn "localhost"))
  let add_dns_entries str t =
    Logs.warn (fun m -> m "adding domain: \"%s\"" str);
    match Domain_name.of_string str with
    | Error (`Msg msg) -> (Logs.err (fun m -> m "Invalid domain name: %s" msg); t)
    | Ok name ->
      let t = Dns_trie.insert name Dns.Rr_map.Aaaa ipv6_pair t in
      let t = Dns_trie.insert name Dns.Rr_map.A    ipv4_pair t in
      let t = Dns_trie.insert name Dns.Rr_map.Soa  soa t
      in t

  let start s http_ctx =
    let open Lwt.Syntax in
    let open Lwt.Infix in
    let cache_size = dns_cache () in
    let blocklist_url = blocklist_url () in

    Log.info (fun m -> m "downloading %s" blocklist_url);
    let* result = Http_mirage_client.request
       http_ctx
       blocklist_url
       (fun resp _acc body ->
          if H2.Status.is_successful resp.status
          then
            begin
              Logs.info (fun m -> m "downloaded %s" blocklist_url);
              Lwt.return (parse_domain_file body)
            end
          else
            begin
              Logs.warn (fun m -> m "%s: %a" blocklist_url H2.Status.pp_hum resp.status);
              Lwt.return ([])
            end
       )
       []
    in
    match result with
    | Error e -> failwith (Fmt.str "%a" Mimic.pp_error e)
    | Ok (_resp, domains) ->
    let trie = List.fold_right add_dns_entries domains Dns_trie.empty in
    let primary_t =
      (* setup DNS server state: *)
      Dns_server.Primary.create ~rng:Mirage_crypto_rng.generate trie
    in
    (* setup stub forwarding state and IP listeners: *)
    Stub.H.connect_device s >>= fun happy_eyeballs ->
    let _ = Stub.create ~cache_size primary_t ~happy_eyeballs s in

    (* Since {Stub.create} registers UDP + TCP listeners asynchronously there
       is no Lwt task.
       We need to return an infinite Lwt task to prevent the unikernel from
       exiting early: *)
    fst (Lwt.task ())
end
