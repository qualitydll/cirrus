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
	fmt.Println(`AEGIS — custom VPN protocol (v0.1 TCP)

Usage:
  aegis server -listen <addr> -secret <password>
  aegis client -server <host:port> -secret <password> -listen <addr>

Commands:
  server   Run AEGIS server (on VPS)
  client   Run AEGIS client as local SOCKS5 proxy

Examples:
  # On VPS:
  aegis server -listen :8443 -secret mysecret123

  # On local machine:
  aegis client -server 1.2.3.4:8443 -secret mysecret123 -listen 127.0.0.1:1080

  # Then configure mihomo/clash to use socks5://127.0.0.1:1080 as upstream
`)
}

func serverCmd(args []string) {
	fs := flag.NewFlagSet("server", flag.ExitOnError)
	listen := fs.String("listen", ":8443", "Listen address")
	secret := fs.String("secret", "", "Shared secret for authentication")
	transport := fs.String("transport", "tcp", "Transport protocol (tcp or udp)")
	fec := fs.Bool("fec", false, "Enable FEC for UDP transport")
	fs.Parse(args)

	if *secret == "" {
		fmt.Fprintln(os.Stderr, "Error: -secret is required")
		os.Exit(1)
	}

	if *transport == "udp" {
		if err := runUDPServer(*listen, *secret, *fec); err != nil {
			fmt.Fprintf(os.Stderr, "UDP Server error: %v\n", err)
			os.Exit(1)
		}
	} else {
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
	transport := fs.String("transport", "tcp", "Transport protocol (tcp or udp)")
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

	if *transport == "udp" {
		if err := runUDPClient(*server, *secret, *listen, *fec); err != nil {
			fmt.Fprintf(os.Stderr, "UDP Client error: %v\n", err)
			os.Exit(1)
		}
	} else {
		if err := runClient(*server, *secret, *listen); err != nil {
			fmt.Fprintf(os.Stderr, "Client error: %v\n", err)
			os.Exit(1)
		}
	}
}
