package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "server":
		serverCmd(os.Args[2:])
	case "client":
		clientCmd(os.Args[2:])
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Println(`AEGIS — custom VPN protocol (v0.2 TCP/UDP/WS)

Usage:
  aegis server -listen <addr> -secret <password> [-transport tcp|udp|ws] [-fec]
  aegis client -server <host:port> -secret <password> -listen <addr> [-transport tcp|udp|ws] [-fec]

Commands:
  server   Run AEGIS server (on VPS)
  client   Run AEGIS client as local SOCKS5 proxy

Transports:
  tcp      Standard TCP transport (default)
  udp      UDP transport with optional FEC
  ws       WebSocket transport (for Cloudflare/CDN)

Examples:
  # TCP server
  aegis server -listen :8443 -secret mysecret123 -transport tcp
  
  # UDP server with FEC
  aegis server -listen :8443 -secret mysecret123 -transport udp -fec
  
  # WebSocket server (for Cloudflare)
  aegis server -listen :8443 -secret mysecret123 -transport ws

  # Client examples
  aegis client -server 1.2.3.4:8443 -secret mysecret123 -listen 127.0.0.1:1080 -transport tcp
  aegis client -server 1.2.3.4:8443 -secret mysecret123 -listen 127.0.0.1:1080 -transport udp -fec
  aegis client -server 1.2.3.4:8443 -secret mysecret123 -listen 127.0.0.1:1080 -transport ws

  # Then configure mihomo/clash to use socks5://127.0.0.1:1080 as upstream
`)
}

func serverCmd(args []string) {
	fs := flag.NewFlagSet("server", flag.ExitOnError)
	listen := fs.String("listen", ":8443", "Listen address")
	secret := fs.String("secret", "", "Shared secret for authentication")
	transport := fs.String("transport", "tcp", "Transport protocol (tcp, udp, or ws)")
	fec := fs.Bool("fec", false, "Enable FEC for UDP transport")
	fs.Parse(args)

	if *secret == "" {
		fmt.Fprintln(os.Stderr, "Error: -secret is required")
		os.Exit(1)
	}

	switch *transport {
	case "udp":
		if err := runUDPServer(*listen, *secret, *fec); err != nil {
			fmt.Fprintf(os.Stderr, "UDP Server error: %v\n", err)
			os.Exit(1)
		}
	case "ws":
		if err := runWSServer(*listen, *secret); err != nil {
			fmt.Fprintf(os.Stderr, "WebSocket Server error: %v\n", err)
			os.Exit(1)
		}
	default:
		if err := runServer(*listen, *secret); err != nil {
			fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
			os.Exit(1)
		}
	}
}

func clientCmd(args []string) {
	fs := flag.NewFlagSet("client", flag.ExitOnError)
	server := fs.String("server", "", "AEGIS server address (host:port)")
	secret := fs.String("secret", "", "Shared secret for authentication")
	listen := fs.String("listen", "127.0.0.1:1080", "Local SOCKS5 listen address")
	transport := fs.String("transport", "tcp", "Transport protocol (tcp, udp, or ws)")
	fec := fs.Bool("fec", false, "Enable FEC for UDP transport")
	fs.Parse(args)

	if *server == "" {
		fmt.Fprintln(os.Stderr, "Error: -server is required")
		os.Exit(1)
	}
	if *secret == "" {
		fmt.Fprintln(os.Stderr, "Error: -secret is required")
		os.Exit(1)
	}

	switch *transport {
	case "udp":
		if err := runUDPClient(*server, *secret, *listen, *fec); err != nil {
			fmt.Fprintf(os.Stderr, "UDP Client error: %v\n", err)
			os.Exit(1)
		}
	case "ws":
		if err := runWSClient(*server, *secret, *listen); err != nil {
			fmt.Fprintf(os.Stderr, "WebSocket Client error: %v\n", err)
			os.Exit(1)
		}
	default:
		if err := runClient(*server, *secret, *listen); err != nil {
			fmt.Fprintf(os.Stderr, "Client error: %v\n", err)
			os.Exit(1)
		}
	}
}
