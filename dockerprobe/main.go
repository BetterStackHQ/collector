// Produces a CSV file associating process IDs to container IDs and names.
// This CSV file is formatted as:
//
// pid,container_name,container_id,image_name
// 1115,better-stack-collector,59e2ea91d8af,betterstack/collector:latest
// 1020,your-container-replica-name-1,0dbc098bc64d,your-repository/your-image:latest
//
// This file is shared from the Beyla container to the Collector container via the docker-metadata volume mounted at /enrichment.
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
	defaultOutputPath   = "/enrichment/docker-mappings.csv"
	defaultInterval     = 30
	defaultTimeout      = 30 * time.Second
	debugLogLimit       = 5
	shortContainerIDLen = 12
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

	for range ticker.C {
		if err := pm.updateMappings(); err != nil {
			log.Printf("Error updating mappings: %v", err)
		}
	}
}

func (pm *pidMapper) updateMappings() error {
	ctx, cancel := context.WithTimeout(context.Background(), defaultTimeout)
	defer cancel()

	containers, err := pm.listRunningContainers(ctx)
	if err != nil {
		return err
	}

	pidMappings := make(map[string]containerInfo)

	for _, cnt := range containers {
		if err := pm.processContainer(ctx, cnt, pidMappings); err != nil {
			log.Printf("Failed to process container %s: %v", cnt.ID[:shortContainerIDLen], err)
			continue
		}
	}

	if err := pm.writePIDMappings(pidMappings); err != nil {
		return fmt.Errorf("failed to write PID mappings: %w", err)
	}

	return nil
}

func (pm *pidMapper) listRunningContainers(ctx context.Context) ([]types.Container, error) {
	containers, err := pm.client.ContainerList(ctx, container.ListOptions{
		All: false,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to list containers: %w", err)
	}
	return containers, nil
}

func (pm *pidMapper) processContainer(ctx context.Context, cnt types.Container, pidMappings map[string]containerInfo) error {
	inspect, err := pm.client.ContainerInspect(ctx, cnt.ID)
	if err != nil {
		return err
	}

	if inspect.State.Pid <= 0 {
		return nil
	}

	info := containerInfo{
		name:  strings.TrimPrefix(cnt.Names[0], "/"),
		id:    cnt.ID[:shortContainerIDLen],
		image: cnt.Image,
	}

	pids := getProcessDescendants(inspect.State.Pid)
	for _, pid := range pids {
		pidMappings[strconv.Itoa(pid)] = info
	}

	log.Printf("Mapped %d PIDs to container %s", len(pids), info.name)
	logSamplePIDs(pids)

	return nil
}

func logSamplePIDs(pids []int) {
	for i, pid := range pids {
		if i >= debugLogLimit {
			break
		}
		log.Printf("  - PID %d", pid)
	}
}

func getProcessDescendants(rootPid int) []int {
	descendants := []int{rootPid}
	toCheck := []int{rootPid}

	for len(toCheck) > 0 {
		currentPid := toCheck[0]
		toCheck = toCheck[1:]

		children := findChildProcesses(currentPid)
		for _, childPid := range children {
			if !slices.Contains(descendants, childPid) {
				descendants = append(descendants, childPid)
				toCheck = append(toCheck, childPid)
			}
		}
	}

	return descendants
}

func findChildProcesses(parentPid int) []int {
	procDir, err := os.Open("/proc")
	if err != nil {
		return nil
	}
	defer procDir.Close()

	entries, err := procDir.Readdirnames(-1)
	if err != nil {
		return nil
	}

	var children []int
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry)
		if err != nil {
			continue
		}

		ppid, err := getParentPID(pid)
		if err != nil {
			continue
		}

		if ppid == parentPid {
			children = append(children, pid)
		}
	}

	return children
}

func getParentPID(pid int) (int, error) {
	statData, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, fmt.Errorf("failed to read stat file: %w", err)
	}

	statStr := string(statData)
	lastParen := strings.LastIndex(statStr, ")")
	if lastParen == -1 {
		return 0, fmt.Errorf("invalid stat format: no closing parenthesis")
	}

	fields := strings.Fields(statStr[lastParen+1:])
	if len(fields) < 2 {
		return 0, fmt.Errorf("invalid stat format: insufficient fields")
	}

	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0, fmt.Errorf("failed to parse parent PID: %w", err)
	}

	return ppid, nil
}

func (pm *pidMapper) writePIDMappings(mappings map[string]containerInfo) error {
	return writeCSVFile(pm.config.outputPath, []string{"pid", "container_name", "container_id", "image_name"},
		func(w *csv.Writer) error {
			for pid, info := range mappings {
				if err := w.Write([]string{pid, info.name, info.id, info.image}); err != nil {
					return fmt.Errorf("failed to write row: %w", err)
				}
			}
			log.Printf("Updated PID mappings file with %d entries", len(mappings))
			return nil
		})
}

func writeCSVFile(path string, headers []string, writeRows func(*csv.Writer) error) error {
	tmpPath := path + ".tmp"

	file, err := os.Create(tmpPath)
	if err != nil {
		return fmt.Errorf("failed to create file: %w", err)
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
		return fmt.Errorf("failed to write header: %w", err)
	}

	if err := writeRows(writer); err != nil {
		return err
	}

	writer.Flush()
	if err := writer.Error(); err != nil {
		return fmt.Errorf("CSV writer error: %w", err)
	}

	if err := file.Close(); err != nil {
		return fmt.Errorf("failed to close file: %w", err)
	}

	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("failed to rename file: %w", err)
	}

	success = true
	return nil
}
