package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"

	tiktoken "github.com/pkoukk/tiktoken-go"
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

// TextParams holds the text parameter for count_tokens and encode.
type TextParams struct {
	Text string `json:"text"`
}

// CountResult is returned by count_tokens.
type CountResult struct {
	Count int `json:"count"`
}

// EncodeResult is returned by encode.
type EncodeResult struct {
	Tokens []int `json:"tokens"`
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

func handleRequest(enc *tiktoken.Tiktoken, req Request) Response {
	switch req.Method {
	case "ping":
		return Response{ID: req.ID, Result: "pong"}

	case "count_tokens":
		if req.Params == nil {
			return errorResponse(req.ID, -32602, "missing text param")
		}
		var params TextParams
		if err := json.Unmarshal(req.Params, &params); err != nil || params.Text == "" {
			if err != nil {
				return errorResponse(req.ID, -32602, "missing text param")
			}
			// Empty text is valid — zero tokens
			return Response{ID: req.ID, Result: CountResult{Count: 0}}
		}
		tokens := enc.Encode(params.Text, nil, nil)
		return Response{ID: req.ID, Result: CountResult{Count: len(tokens)}}

	case "encode":
		if req.Params == nil {
			return errorResponse(req.ID, -32602, "missing text param")
		}
		var params TextParams
		if err := json.Unmarshal(req.Params, &params); err != nil {
			return errorResponse(req.ID, -32602, "missing text param")
		}
		tokens := enc.Encode(params.Text, nil, nil)
		// Convert []int to []int (tiktoken returns []int already)
		result := make([]int, len(tokens))
		copy(result, tokens)
		return Response{ID: req.ID, Result: EncodeResult{Tokens: result}}

	default:
		return errorResponse(req.ID, -32601, fmt.Sprintf("unknown method: %s", req.Method))
	}
}

func main() {
	// Direct all library logging to stderr — stdout is protocol-only.
	log.SetOutput(os.Stderr)
	log.SetFlags(log.Ltime | log.Lshortfile)

	// Load encoding once at startup (~100ms). All subsequent calls are <1ms.
	log.Println("loading cl100k_base encoding...")
	enc, err := tiktoken.GetEncoding("cl100k_base")
	if err != nil {
		log.Fatalf("failed to load encoding: %v", err)
	}
	log.Println("encoding loaded, ready")

	scanner := bufio.NewScanner(os.Stdin)
	// 10MB buffer to handle large texts in a single line.
	scanner.Buffer(make([]byte, 0), 10*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			log.Printf("failed to parse request: %v", err)
			// Emit a parse error with empty id since we couldn't extract one.
			writeResponse(errorResponse("", -32700, fmt.Sprintf("parse error: %v", err)))
			continue
		}

		resp := handleRequest(enc, req)
		writeResponse(resp)
	}

	if err := scanner.Err(); err != nil {
		log.Fatalf("stdin scanner error: %v", err)
	}

	log.Println("stdin closed, exiting")
}
