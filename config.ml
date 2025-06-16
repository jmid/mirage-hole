(* Copyright Robur, 2020 *)

open Mirage

type http_client = HTTP_client
let http_client = typ HTTP_client

let dns_upstream =
  let doc = Key.Arg.info ~doc:"Upstream DNS resolver IP" ["dns-upstream"] in
  Key.(create "dns-upstream" Arg.(opt (some ip_address) None doc))

let dns_port =
  let doc = Key.Arg.info ~doc:"Upstream DNS resolver port" ["dns-port"] in
  Key.(create "dns-port" Arg.(opt int 53 doc))

let tls_hostname =
  let doc = Key.Arg.info ~doc:"Hostname to use for TLS authentication" ["tls-hostname"] in
  Key.(create "tls-hostname" Arg.(opt (some string) None doc))

let authenticator =
  let doc = Key.Arg.info ~doc:"TLS authenticator" ["authenticator"] in
  Key.(create "authenticator" Arg.(opt (some string) None doc))

let no_tls =
  let doc = Key.Arg.info ~doc:"Disable DNS-over-TLS" ["no-tls"] in
  Key.(create "no-tls" Arg.(opt bool false doc))

let blocklist_url =
  let doc = Key.Arg.info ~doc:"URL to fetch the blocked list of domains from" ["blocklist-url"] in
  Key.(create "blocklist-url" Arg.(opt (some string) None doc))

let dnsvizor =
  let packages =
    [
      package "logs" ;
      package "metrics" ;
      package ~min:"6.0.0" ~sublibs:["mirage"] "dns-stub";
      package "dns";
      package "dns-client";
      package "dns-mirage";
      package "dns-resolver";
      package "dns-tsig";
      package "dns-server";
      package "ca-certs-nss";
      package ~pin:"git+https://git.robur.io/robur/http-mirage-client.git" "http-mirage-client";
    ]
  in
  foreign
    ~keys:[Key.v dns_upstream ; Key.v dns_port ; Key.v tls_hostname ; Key.v authenticator ; Key.v no_tls; Key.v blocklist_url ]
    ~packages
    "Unikernel.Main"
    (random @-> pclock @-> mclock @-> time @-> stackv4v6 @-> http_client @-> job)

let http_client =
  let connect _ modname = function
    | [ _pclock; _tcpv4v6; ctx ] ->
      Fmt.str {ocaml|%s.connect %s|ocaml} modname ctx
    | _ -> assert false in
  impl ~connect "Http_mirage_client.Make"
    (pclock @-> tcpv4v6 @-> git_client @-> http_client)

let stack = generic_stackv4v6 default_network
let dns = generic_dns_client stack
let tcp = tcpv4v6_of_stackv4v6 stack
let happy_eyeballs = git_happy_eyeballs stack dns (generic_happy_eyeballs stack dns)
let http_client = http_client $ default_posix_clock $ tcp $ happy_eyeballs

let () =
  register "mirage-hole" [
    dnsvizor
    $ default_random
    $ default_posix_clock
    $ default_monotonic_clock
    $ default_time
    $ stack
    $ http_client ]
