// Command rendu is the agent-side CLI for a Rendu server.
package main

import (
	"os"

	"github.com/Kadxy/rendu/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr, os.Getenv))
}
