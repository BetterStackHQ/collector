package main

import (
	"encoding/json"
	"fmt"

	"github.com/coroot/coroot-node-agent/node/metadata"
)

func main() {
	md := metadata.GetInstanceMetadata()
	if md == nil {
		fmt.Println("{}")
		return
	}
	out, _ := json.Marshal(md)
	fmt.Println(string(out))
}
