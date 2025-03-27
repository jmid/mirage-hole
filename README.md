Mirage-hole
===========

This repo contains a prototype implementation of a [DNS
sinkhole](https://en.wikipedia.org/wiki/DNS_sinkhole) in the style of
[Pi-hole](https://github.com/pi-hole/pi-hole) running as a
MirageOS unikernel in OCaml.

The DNS node works by fetching a list of domain names to be blocked
and then maps them to `localhost` (127.0.0.1) instead of their usual
IP address. DNS queries to non-blocked domains will be passed on to
the upstream DNS server.


Building and running as linux binary
------------------------------------

To build:
```
mirage configure -t unix --dhcp false --net direct
make depend
make build
```

To run on Linux
- you need a `tap` interface set up (here with IP 10.0.0.10):
  ```
  sudo modprobe tun
  sudo tunctl -u $USER -t tap0
  sudo ifconfig tap0 10.0.0.10 up
  ```
- forwarding should be set up:
  ```
  sysctl net.ipv4.ip_forward
  sudo sysctl -w net.ipv4.ip_forward=1
  ```
- masquerading should be set up to translate responses coming back (here from the wireless interface):
  ```
  sudo iptables -t nat -L -v
  sudo iptables -t nat -A POSTROUTING -o wlp0s20f3 -s 10.0.0.2 -j MASQUERADE
  ```

Now run it as follows:
```
 sudo ./dist/mirage-hole --ipv4-only=true --ipv4-gateway=10.0.0.10 --dns-upstream=192.168.42.2 --no-tls=true --blocklist-url=https://blocklistproject.github.io/Lists/tracking.txt
```
where we pass command-line arguments
- `--ipv4-only=true` as IPv4 is only supported
- `--ipv4-gateway=10.0.0.10` to specify
- `--dns-upstream=192.168.42.2` to specify the upstream DNS server
- `--no-tls=true` to disable DNS over TLS
- `--blocklist-url=URL` is optional (currently defaults to https://blocklistproject.github.io/Lists/tracking.txt)

Building and running as qubes AppVM
-----------------------------------
To build:
```
mirage configure -t qubes --dhcp true
make depend
make build
```

(note that other solo5 targets should be usable as well)

To create a Qubes AppVM (this is similar to the procedure for qubes-mirage-firewall):
Run those commands in dom0 to create a `mirage-hole` kernel and an AppVM using that kernel (replace the name of your AppVM where you build your unikernel `dev`, and the corresponding directory `mirage-hole`):
```
mkdir -p /var/lib/qubes/vm-kernels/mirage-hole/
cd /var/lib/qubes/vm-kernels/mirage-hole/
qvm-run -p dev 'cat mirage-hole/dist/mirage-hole.xen' > vmlinuz
qvm-create \
  --property kernel=mirage-hole \
  --property kernelopts='' \
  --property memory=32 \
  --property maxmem=32 \
  --property netvm=sys-net \
  --property provides_network=False \
  --property vcpus=1 \
  --property virt_mode=pvh \
  --label=green \
  --class StandaloneVM \
  mirage-hole
qvm-features mirage-hole no-default-kernelopts 1
```

Setup DNS:
In order to use it as your default resolver, you will need to run the following in dom0 (with your favorite resolver, which can eventually be another unikernel :) ):
```
qvm-prefs mirage-hole kernelopts -- '--dns-upstream=8.8.8.8'
```
And specify in sys-net that the resolver should not be retrieved from the DHCP configuration but be fixed: `10.137.0.XX` where `XX` is the IP address given by Qubes to your `mirage-hole` AppVM.

Usage
-----

A DNS query to mirage-hole for a blocked domain will now map to `localhost`:
```
$ dig @10.0.0.2 1-cl0ud.com

; <<>> DiG 9.16.1-Ubuntu <<>> @10.0.0.2 1-cl0ud.com
; (1 server found)
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 42109
;; flags: qr rd ad; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0
;; WARNING: recursion requested but not available

;; QUESTION SECTION:
;1-cl0ud.com.			IN	A

;; ANSWER SECTION:
1-cl0ud.com.		3600	IN	A	127.0.0.1

;; Query time: 0 msec
;; SERVER: 10.0.0.2#53(10.0.0.2)
;; WHEN: Thu Oct 06 13:28:26 CEST 2022
;; MSG SIZE  rcvd: 45

```

Note: It can be helpful to trace `tap` network traffic with `sudo tcpdump -i tap0 -n`.


TODO
----

- try out with other Mirage backends
- try out with a browser
- add a web-server with a bit of statistics
- check that it works for IPv6
- block other kinds of queries (`TXT`,...)
- extend to fetch blocklist updates dynamically
  - as a web-page button
  - as cron-like weekly/daily task
- write tests? How?
- ...


Acknowledgments
---------------

- The code builds on a DNS-stub example from [dnsvizor](https://github.com/roburio/dnsvizor)
- The project is heavily inspired by [Pi-hole](https://github.com/pi-hole/pi-hole)
