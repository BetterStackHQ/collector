// Produces a CSV file associating process IDs to container IDs and names.
// This CSV file is formatted as:
//
// pid,container_name,container_id,image_name
// 1115,better-stack-collector,59e2ea91d8af,betterstack/collector:latest
// 1020,your-container-replica-name-1,0dbc098bc64d,your-repository/your-image:latest
//
// This file is shared from the Beyla container to the Collector container via the docker-metadata volume mounted at /enrichment.
// Vector uses this file to enrich logs, metrics, and traces with container metadata.
package main

import (
	"context"
	"encoding/csv"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/client"
)

const (
	defaultOutputPath   = "/enrichment/docker-mappings.incoming.csv"
	defaultInterval     = 15 // seconds; in line with default tickrate of Beyla collection
	defaultTimeout      = 15 // seconds
	debugLogLimit       = 5
	shortContainerIDLen = 12 // length of the short container ID (e.g. 0dbc098bc64d)
)

type config struct {
	outputPath string
	interval   time.Duration
}

type containerInfo struct {
	name  string
	id    string
	image string
}

type pidMapper struct {
	client *client.Client
	config config
}

func main() {
	log.Println("Starting dockerprobe...")

	cfg := loadConfig()

	if err := ensureOutputDirectory(cfg.outputPath); err != nil {
		log.Fatalf("Failed to create output directory: %v", err)
	}

	dockerClient, err := createDockerClient()
	if err != nil {
		log.Fatalf("Failed to create Docker client: %v", err)
	}
	defer dockerClient.Close()

	mapper := &pidMapper{
		client: dockerClient,
		config: cfg,
	}

	mapper.run()
}

func loadConfig() config {
	outputPath := os.Getenv("DOCKERPROBE_OUTPUT_PATH")
	if outputPath == "" {
		outputPath = defaultOutputPath
	}

	interval := defaultInterval
	if intervalStr := os.Getenv("DOCKERPROBE_INTERVAL"); intervalStr != "" {
		parsed, err := strconv.Atoi(intervalStr)
		if err != nil {
			log.Printf("Invalid interval %q, using default %d: %v", intervalStr, defaultInterval, err)
		} else {
			interval = parsed
		}
	}

	return config{
		outputPath: outputPath,
		interval:   time.Duration(interval) * time.Second,
	}
}

func ensureOutputDirectory(outputPath string) error {
	return os.MkdirAll(filepath.Dir(outputPath), 0755)
}

func createDockerClient() (*client.Client, error) {
	return client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
}

func (pm *pidMapper) run() {
	if err := pm.updateMappings(); err != nil {
		log.Printf("Error updating mappings: %v", err)
	}

	ticker := time.NewTicker(pm.config.interval)
	defer ticker.Stop()

	for range ticker.C { // ticker.C is a channel that emits a value every time the interval elapses
		if err := pm.updateMappings(); err != nil {
			log.Printf("Error updating mappings: %v", err)
		}
	}
}

func (pm *pidMapper) updateMappings() error {
	ctx, cancel := context.WithTimeout(context.Background(), defaultTimeout*time.Second)
	defer cancel()

	containers, err := pm.listRunningContainers(ctx)
	if err != nil {
		return err
	}

	// Use pointers for containerInfo to shave off some memory when many PIDs are mapped to the same container
	pidMappings := make(map[string]*containerInfo)

	for _, cnt := range containers {
		if err := pm.processContainer(ctx, cnt, pidMappings); err != nil {
			log.Printf("Failed to process container %s: %v", cnt.ID[:shortContainerIDLen], err)
			continue
		}
	}

	if err := writeCSVFile(pm.config.outputPath, []string{"pid", "container_name", "container_id", "image_name"}, pidMappings); err != nil {
		return fmt.Errorf("failed to write PID mappings: %w", err)
	}

	return nil
}

func (pm *pidMapper) listRunningContainers(ctx context.Context) ([]types.Container, error) {
	// All: false means only list running containers.
	containers, err := pm.client.ContainerList(ctx, container.ListOptions{
		All: false,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to list containers: %w", err)
	}
	return containers, nil
}

func (pm *pidMapper) processContainer(ctx context.Context, cnt types.Container, pidMappings map[string]*containerInfo) error {
	inspect, err := pm.client.ContainerInspect(ctx, cnt.ID)
	if err != nil {
		return err
	}

	if inspect.State.Pid <= 0 {
		return nil
	}

	// Allocate struct once, reuse pointer multiple times to avoid memcpy overhead
	// (assume the available allocator is not smart enough to reuse the same struct)
	info := &containerInfo{
		name:  strings.TrimPrefix(cnt.Names[0], "/"),
		id:    cnt.ID[:shortContainerIDLen],
		image: cnt.Image,
	}

	pids := getProcessDescendants(inspect.State.Pid)
	for _, pid := range pids {
		pidMappings[strconv.Itoa(pid)] = info
	}

	log.Printf("Mapped %d PIDs to container %s", len(pids), info.name)

	return nil
}

func getProcessDescendants(rootPid int) []int {
	descendants := []int{rootPid}
	toCheck := []int{rootPid}

	for len(toCheck) > 0 {
		currentPid := toCheck[0]
		toCheck = toCheck[1:] // compact implementation of FIFO queue

		children := findChildProcesses(currentPid)
		for _, childPid := range children { // breadth-first search for descendants
			if !slices.Contains(descendants, childPid) {
				descendants = append(descendants, childPid)
				toCheck = append(toCheck, childPid)
			}
		}
	}

	return descendants
}

// Scans the /proc directory to find all child processes of the given parent PID
// Proc is structured as:
// /proc/
//
//	/<pid>/
//	  /stat
//	  /task/
//	    /<child_pid>/
//	      /stat
//
// The stat file contains the parent PID in the format:
// <pid> (<parent_pid>) ...
func findChildProcesses(parentPid int) []int {
	procDir, err := os.Open("/proc")
	if err != nil {
		return nil
	}
	defer procDir.Close()

	entries, err := procDir.Readdirnames(-1)
	if err != nil { // /proc is inaccessessible for some reason
		return nil
	}

	var children []int
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry) // entry is a string like "1234"; this should always be a valid integer, but handle errors just in case
		if err != nil {
			continue
		}

		ppid, err := getParentPID(pid) // there are some edge cases where the mapping child->parent is not available, e.g. when the child process is a zombie; ignore these cases
		if err != nil {
			continue
		}

		if ppid == parentPid {
			children = append(children, pid) // found a child process of the parent PID that's not a zombie
		}
	}

	return children
}

// Parse the <pid> (<parent_pid>) ... format of the stat file to get the parent PID
func getParentPID(pid int) (int, error) {
	statData, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, fmt.Errorf("failed to read stat file: %w", err) // this _could_ happen on extremely old kernels, which we don't support
	}

	statStr := string(statData)
	lastParen := strings.LastIndex(statStr, ")")
	if lastParen == -1 {
		return 0, fmt.Errorf("invalid stat format: no closing parenthesis") // this should never happen, but handle it just in case
	}

	fields := strings.Fields(statStr[lastParen+1:])
	if len(fields) < 2 {
		return 0, fmt.Errorf("invalid stat format: insufficient fields") // this _could_ happen on extremely old kernels, which we don't support, but handle it just in case
	}

	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0, fmt.Errorf("failed to parse parent PID: %w", err) // this should never happen, but handle it just in case
	}

	return ppid, nil
}

func writeCSVFile(path string, headers []string, mappings map[string]*containerInfo) error {
	tmpPath := path + ".tmp"

	file, err := os.Create(tmpPath)
	if err != nil {
		return fmt.Errorf("failed to create file: %w", err) // shouldn't happen except for EXTREME resource exhaustion on the host machine
	}

	success := false
	defer func() {
		file.Close()
		if !success {
			os.Remove(tmpPath)
		}
	}()

	writer := csv.NewWriter(file)

	if err := writer.Write(headers); err != nil {
		return fmt.Errorf("failed to write header: %w", err) // file decided to close on us (again, extreme resource exhaustion)
	}

	for pid, info := range mappings {
		if err := writer.Write([]string{pid, info.name, info.id, info.image}); err != nil {
			return fmt.Errorf("failed to write row: %w", err) // file decided to close on us (again, extreme resource exhaustion)
		}
	}
	log.Printf("Updated PID mappings file with %d entries", len(mappings))

	writer.Flush()
	if err := writer.Error(); err != nil {
		return fmt.Errorf("CSV writer error: %w", err) // generic CSV writer error - this would be a bug on our side
	}

	if err := file.Close(); err != nil {
		return fmt.Errorf("failed to close file: %w", err) // really, REALLY shouldn't happen, but handle it just in case
	}

	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("failed to rename file: %w", err) // possible with exhausted inodes
	}

	success = true
	return nil
}
