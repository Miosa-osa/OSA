package client

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Client connects to the OSA backend HTTP API.
type Client struct {
	BaseURL    string
	Token      string
	HTTPClient *http.Client
}

// New creates a client pointing at the given base URL.
func New(baseURL string) *Client {
	return &Client{
		BaseURL: baseURL,
		HTTPClient: &http.Client{
			Timeout: 120 * time.Second,
		},
	}
}

// SetToken sets the JWT auth token.
func (c *Client) SetToken(token string) {
	c.Token = token
}

// Health checks backend connectivity.
func (c *Client) Health() (*HealthResponse, error) {
	resp, err := c.get("/health")
	if err != nil {
		return nil, fmt.Errorf("health check failed: %w", err)
	}
	defer resp.Body.Close()

	var health HealthResponse
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		return nil, fmt.Errorf("decode health: %w", err)
	}
	return &health, nil
}

// Orchestrate sends user input through the agent loop.
func (c *Client) Orchestrate(req OrchestrateRequest) (*OrchestrateResponse, error) {
	resp, err := c.postJSON("/api/v1/orchestrate", req)
	if err != nil {
		return nil, fmt.Errorf("orchestrate: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}

	var result OrchestrateResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode orchestrate: %w", err)
	}
	return &result, nil
}

// OrchestrateComplex launches a multi-agent task.
func (c *Client) OrchestrateComplex(req ComplexRequest) (*ComplexResponse, error) {
	resp, err := c.postJSON("/api/v1/orchestrate/complex", req)
	if err != nil {
		return nil, fmt.Errorf("orchestrate complex: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		return nil, c.parseError(resp)
	}

	var result ComplexResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode complex: %w", err)
	}
	return &result, nil
}

// Progress polls orchestrator task progress.
func (c *Client) Progress(taskID string) (*ProgressResponse, error) {
	resp, err := c.get(fmt.Sprintf("/api/v1/orchestrate/%s/progress", taskID))
	if err != nil {
		return nil, fmt.Errorf("progress: %w", err)
	}
	defer resp.Body.Close()

	var result ProgressResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode progress: %w", err)
	}
	return &result, nil
}

// ListTools returns available executable tools.
func (c *Client) ListTools() ([]ToolEntry, error) {
	resp, err := c.get("/api/v1/tools")
	if err != nil {
		return nil, fmt.Errorf("list tools: %w", err)
	}
	defer resp.Body.Close()

	var tools []ToolEntry
	if err := json.NewDecoder(resp.Body).Decode(&tools); err != nil {
		return nil, fmt.Errorf("decode tools: %w", err)
	}
	return tools, nil
}

// ListCommands returns available slash commands.
func (c *Client) ListCommands() ([]CommandEntry, error) {
	resp, err := c.get("/api/v1/commands")
	if err != nil {
		return nil, fmt.Errorf("list commands: %w", err)
	}
	defer resp.Body.Close()

	var commands []CommandEntry
	if err := json.NewDecoder(resp.Body).Decode(&commands); err != nil {
		return nil, fmt.Errorf("decode commands: %w", err)
	}
	return commands, nil
}

// ExecuteCommand runs a slash command server-side.
func (c *Client) ExecuteCommand(req CommandExecuteRequest) (*CommandExecuteResponse, error) {
	resp, err := c.postJSON("/api/v1/commands/execute", req)
	if err != nil {
		return nil, fmt.Errorf("execute command: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}

	var result CommandExecuteResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode command: %w", err)
	}
	return &result, nil
}

// Classify runs signal classification on input.
func (c *Client) Classify(input string) (*ClassifyResponse, error) {
	resp, err := c.postJSON("/api/v1/classify", ClassifyRequest{Input: input})
	if err != nil {
		return nil, fmt.Errorf("classify: %w", err)
	}
	defer resp.Body.Close()

	var result ClassifyResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode classify: %w", err)
	}
	return &result, nil
}

// Login authenticates and returns tokens.
func (c *Client) Login(userID string) (*LoginResponse, error) {
	resp, err := c.postJSON("/api/v1/auth/login", LoginRequest{UserID: userID})
	if err != nil {
		return nil, fmt.Errorf("login: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}

	var result LoginResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode login: %w", err)
	}
	c.Token = result.Token
	return &result, nil
}

// Logout invalidates the current session.
func (c *Client) Logout() error {
	resp, err := c.postJSON("/api/v1/auth/logout", nil)
	if err != nil {
		return fmt.Errorf("logout: %w", err)
	}
	defer resp.Body.Close()
	c.Token = ""
	return nil
}

// RefreshToken exchanges a refresh token for a new access token.
func (c *Client) RefreshToken(refreshToken string) (*RefreshResponse, error) {
	resp, err := c.postJSON("/api/v1/auth/refresh", RefreshRequest{RefreshToken: refreshToken})
	if err != nil {
		return nil, fmt.Errorf("refresh: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}

	var result RefreshResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode refresh: %w", err)
	}
	c.Token = result.Token
	return &result, nil
}

// -- internal helpers --

func (c *Client) get(path string) (*http.Response, error) {
	req, err := http.NewRequest("GET", c.BaseURL+path, nil)
	if err != nil {
		return nil, err
	}
	c.setHeaders(req)
	return c.HTTPClient.Do(req)
}

func (c *Client) postJSON(path string, body interface{}) (*http.Response, error) {
	data, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}
	req, err := http.NewRequest("POST", c.BaseURL+path, bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	c.setHeaders(req)
	return c.HTTPClient.Do(req)
}

func (c *Client) setHeaders(req *http.Request) {
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
}

func (c *Client) parseError(resp *http.Response) error {
	body, _ := io.ReadAll(resp.Body)
	var apiErr ErrorResponse
	if json.Unmarshal(body, &apiErr) == nil && apiErr.Error != "" {
		return fmt.Errorf("API %d: %s — %s", resp.StatusCode, apiErr.Error, apiErr.Details)
	}
	return fmt.Errorf("API %d: %s", resp.StatusCode, string(body))
}
