// Command fake-mcp-server is a test double for the upstream mcp-server binary.
// It reads newline-terminated JSON frames from stdin and echoes each one back
// to stdout unchanged, which lets registry_test.go verify that the multiplexer
// relay is byte-transparent without involving the real upstream binary.
//
// The process exits cleanly when stdin is closed.
package main

import (
	"bufio"
	"fmt"
	"os"
)

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := scanner.Text()
		fmt.Println(line)
	}
}
