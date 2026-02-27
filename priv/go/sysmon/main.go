package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/mem"
	"github.com/shirou/gopsutil/v3/process"
)

// Request is a JSON-RPC request read from stdin.
type Request struct {
	ID     string          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

// Response is a JSON-RPC response written to stdout.
type Response struct {
	ID     string      `json:"id"`
	Result interface{} `json:"result,omitempty"`
	Error  *RPCError   `json:"error,omitempty"`
}

// RPCError represents a JSON-RPC error object.
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// PathParams holds an optional path parameter for disk_usage.
type PathParams struct {
	Path string `json:"path"`
}

// CPUResult is returned by cpu_percent.
type CPUResult struct {
	Percent []float64 `json:"percent"`
	Count   int       `json:"count"`
}

// MemoryResult is returned by memory_info.
type MemoryResult struct {
	Total     uint64  `json:"total"`
	Available uint64  `json:"available"`
	Used      uint64  `json:"used"`
	Percent   float64 `json:"percent"`
}

// DiskResult is returned by disk_usage.
type DiskResult struct {
	Total   uint64  `json:"total"`
	Free    uint64  `json:"free"`
	Used    uint64  `json:"used"`
	Percent float64 `json:"percent"`
}

// ProcessEntry represents a single process in process_list.
type ProcessEntry struct {
	PID    int32   `json:"pid"`
	Name   string  `json:"name"`
	CPU    float64 `json:"cpu"`
	Memory uint64  `json:"memory"`
}

// ProcessResult is returned by process_list.
type ProcessResult struct {
	Processes []ProcessEntry `json:"processes"`
	Count     int            `json:"count"`
}

var stdout = bufio.NewWriter(os.Stdout)

func writeResponse(resp Response) {
	data, err := json.Marshal(resp)
	if err != nil {
		log.Printf("failed to marshal response: %v", err)
		return
	}
	fmt.Fprintf(stdout, "%s\n", data)
	stdout.Flush()
}

func errorResponse(id string, code int, message string) Response {
	return Response{
		ID:    id,
		Error: &RPCError{Code: code, Message: message},
	}
}

func handleCPUPercent(id string) Response {
	// Use a short 200ms interval for a meaningful non-zero reading.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	percents, err := cpu.PercentWithContext(ctx, 200*time.Millisecond, true)
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("cpu_percent failed: %v", err))
	}

	count, _ := cpu.CountsWithContext(ctx, true)

	return Response{
		ID: id,
		Result: CPUResult{
			Percent: percents,
			Count:   count,
		},
	}
}

func handleMemoryInfo(id string) Response {
	vm, err := mem.VirtualMemory()
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("memory_info failed: %v", err))
	}

	return Response{
		ID: id,
		Result: MemoryResult{
			Total:     vm.Total,
			Available: vm.Available,
			Used:      vm.Used,
			Percent:   vm.UsedPercent,
		},
	}
}

func handleDiskUsage(id string, params json.RawMessage) Response {
	var p PathParams
	p.Path = "/"
	if params != nil {
		if err := json.Unmarshal(params, &p); err != nil {
			return errorResponse(id, -32602, fmt.Sprintf("invalid params: %v", err))
		}
	}
	if p.Path == "" {
		p.Path = "/"
	}

	usage, err := disk.Usage(p.Path)
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("disk_usage failed for %q: %v", p.Path, err))
	}

	return Response{
		ID: id,
		Result: DiskResult{
			Total:   usage.Total,
			Free:    usage.Free,
			Used:    usage.Used,
			Percent: usage.UsedPercent,
		},
	}
}

func handleProcessList(id string) Response {
	procs, err := process.Processes()
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("process_list failed: %v", err))
	}

	entries := make([]ProcessEntry, 0, len(procs))
	for _, p := range procs {
		name, _ := p.Name()
		cpuPct, _ := p.CPUPercent()
		memInfo, _ := p.MemoryInfo()

		var rss uint64
		if memInfo != nil {
			rss = memInfo.RSS
		}

		entries = append(entries, ProcessEntry{
			PID:    p.Pid,
			Name:   name,
			CPU:    cpuPct,
			Memory: rss,
		})
	}

	return Response{
		ID: id,
		Result: ProcessResult{
			Processes: entries,
			Count:     len(entries),
		},
	}
}

func handleRequest(req Request) Response {
	switch req.Method {
	case "ping":
		return Response{ID: req.ID, Result: "pong"}
	case "cpu_percent":
		return handleCPUPercent(req.ID)
	case "memory_info":
		return handleMemoryInfo(req.ID)
	case "disk_usage":
		return handleDiskUsage(req.ID, req.Params)
	case "process_list":
		return handleProcessList(req.ID)
	default:
		return errorResponse(req.ID, -32601, fmt.Sprintf("unknown method: %s", req.Method))
	}
}

func main() {
	// Direct all library logging to stderr — stdout is protocol-only.
	log.SetOutput(os.Stderr)
	log.SetFlags(log.Ltime | log.Lshortfile)

	log.Println("osa-sysmon sidecar ready")

	scanner := bufio.NewScanner(os.Stdin)
	// 10MB buffer — sysmon responses can be large for process_list.
	scanner.Buffer(make([]byte, 0), 10*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			log.Printf("failed to parse request: %v", err)
			writeResponse(errorResponse("", -32700, fmt.Sprintf("parse error: %v", err)))
			continue
		}

		resp := handleRequest(req)
		writeResponse(resp)
	}

	if err := scanner.Err(); err != nil {
		log.Fatalf("stdin scanner error: %v", err)
	}

	log.Println("stdin closed, exiting")
}
