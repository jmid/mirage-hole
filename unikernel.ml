
let argument_error = 64

(* a default/fall-back blocking URL *)
let url = "https://blocklistproject.github.io/Lists/tracking.txt"

module Main
    (R : Mirage_random.S)
    (P : Mirage_clock.PCLOCK)
    (M : Mirage_clock.MCLOCK)
    (Time : Mirage_time.S)
    (S : Tcpip.Stack.V4V6)
    (HTTP : Http_mirage_client.S) = struct

  module Stub = Dns_stub_mirage.Make(R)(Time)(P)(M)(S)
  module Ca_certs = Ca_certs_nss.Make(P)

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

  let start () () () () s http_ctx =
    let nameservers =
      match Key_gen.dns_upstream () with
      | None -> None
      | Some ip ->
        if Key_gen.no_tls () then
          Some ([ `Plaintext (ip, Key_gen.dns_port ()) ])
        else
          let authenticator =
            match Key_gen.authenticator () with
            | None ->
              (match Ca_certs.authenticator () with
               | Ok auth -> auth
               | Error `Msg msg ->
                 Logs.err (fun m -> m "error retrieving ca certs: %s" msg);
                 exit argument_error)
            | Some str ->
              match X509.Authenticator.of_string str with
              | Error `Msg msg ->
                Logs.err (fun m -> m "%s" msg);
                exit argument_error
              | Ok auth ->
                let time () = Some (Ptime.v (P.now_d_ps ())) in
                auth time
          in
          let peer_name, ip' = match Key_gen.tls_hostname () with
            | None -> None, Some ip
            | Some h ->
              Some (try Domain_name.(host_exn (of_string_exn h))
                    with Invalid_argument msg -> Logs.err (fun m -> m "invalid host name %S: %s" h msg); exit argument_error), None
          in
          let tls = Tls.Config.client ~authenticator ?peer_name ?ip:ip' () in
          Some [ `Tls (tls, ip, if Key_gen.dns_port () = 53 then 853 else Key_gen.dns_port ()) ]
    in
    let url = match Key_gen.blocklist_url () with
      | None -> url
      | Some url -> url in
    Logs.info (fun m -> m "downloading %s" url);
    let open Lwt.Infix in
    (Http_mirage_client.one_request
       ~alpn_protocol:HTTP.alpn_protocol
       ~authenticator:HTTP.authenticator
       ~ctx:http_ctx url >>= function
     | Ok (resp, Some str) ->
       if resp.status = `OK
       then
         begin
           Logs.info (fun m -> m "downloaded %s" url);
           Lwt.return (parse_domain_file str)
         end
       else
         begin
           Logs.warn (fun m -> m "%s: %a (reason %s)" url H2.Status.pp_hum resp.status resp.reason);
           Lwt.return []
         end
     | _ ->
       Logs.warn (fun m -> m "The HTTP request did not go Ok...");
       Lwt.return []) >>= fun domains ->
    let trie = List.fold_right add_dns_entries domains Dns_trie.empty in
    let primary_t =
      (* setup DNS server state: *)
      Dns_server.Primary.create ~rng:Mirage_crypto_rng.generate trie
    in
    (* setup stub forwarding state and IP listeners: *)
    let _ = Stub.create ?nameservers primary_t s in

    (* Since {Stub.create} registers UDP + TCP listeners asynchronously there
       is no Lwt task.
       We need to return an infinite Lwt task to prevent the unikernel from
       exiting early: *)
    fst (Lwt.task ())
end
