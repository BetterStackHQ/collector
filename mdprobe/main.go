package main

import (
	"encoding/json"
	"fmt"
	"regexp"

	"github.com/coroot/coroot-node-agent/node/metadata"
)

func main() {
	md := metadata.GetInstanceMetadata()
	if md == nil {
		fmt.Println("{}")
		return
	}
	
	// Modify AvailabilityZone if it's a decimal numeric string (Azure case)
	if matched, _ := regexp.MatchString("^[0-9]+$", md.AvailabilityZone); matched {
		md.AvailabilityZone = md.Region + "-" + md.AvailabilityZone
	}
	
	out, _ := json.Marshal(md)
	fmt.Println(string(out))
}
