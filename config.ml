(* mirage >= 4.9.0 & < 4.10.0 *)
(* Copyright Robur, 2020 *)

open Mirage

let dnsvizor =
  main
  ~packages:
    [
      package "logs" ;
      package "metrics" ;
      package ~min:"6.0.0" ~sublibs:["mirage"] "dns-stub";
      package "mirage-ptime";
      package "http-mirage-client";
      package "dns";
      package "dns-client";
      package "dns-mirage";
      package "dns-resolver";
      package "dns-tsig";
      package "dns-server";
      package "ca-certs-nss";
      package "hex";
    ]
    "Unikernel.Main"
    (stackv4v6 @-> http_client @-> job)

let http_client =
  let connect _ modname = function
    | [ _tcpv4v6; ctx ] ->
        code ~pos:__POS__ {ocaml|%s.connect %s|ocaml} modname ctx
    | _ -> assert false
  in
  impl ~connect "Http_mirage_client.Make"
    (tcpv4v6 @-> mimic @-> Mirage.http_client)

let stackv4v6 = generic_stackv4v6 default_network
let he = generic_happy_eyeballs stackv4v6
let dns = generic_dns_client stackv4v6 he
let tcp = tcpv4v6_of_stackv4v6 stackv4v6

let http_client =
  let happy_eyeballs = mimic_happy_eyeballs stackv4v6 he dns in
  http_client $ tcp $ happy_eyeballs

let () =
  register "mirage-hole" [
    dnsvizor
    $ stackv4v6
    $ http_client ]
