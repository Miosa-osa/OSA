package client

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

type Client struct {
	BaseURL    string
	Token      string
	HTTPClient *http.Client
}

func New(baseURL string) *Client {
	return &Client{
		BaseURL: baseURL,
		HTTPClient: &http.Client{
			Timeout: 300 * time.Second,
		},
	}
}

func (c *Client) SetToken(token string) {
	c.Token = token
}

func (c *Client) Health() (*HealthResponse, error) {
	resp, err := c.get("/health")
	if err != nil {
		return nil, fmt.Errorf("health check failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var health HealthResponse
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		return nil, fmt.Errorf("decode health: %w", err)
	}
	return &health, nil
}

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

func (c *Client) ListTools() ([]ToolEntry, error) {
	resp, err := c.get("/api/v1/tools")
	if err != nil {
		return nil, fmt.Errorf("list tools: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var wrapper struct {
		Tools []ToolEntry `json:"tools"`
		Count int         `json:"count"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrapper); err != nil {
		return nil, fmt.Errorf("decode tools: %w", err)
	}
	return wrapper.Tools, nil
}

func (c *Client) ListCommands() ([]CommandEntry, error) {
	resp, err := c.get("/api/v1/commands")
	if err != nil {
		return nil, fmt.Errorf("list commands: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var wrapper struct {
		Commands []CommandEntry `json:"commands"`
		Count    int            `json:"count"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrapper); err != nil {
		return nil, fmt.Errorf("decode commands: %w", err)
	}
	return wrapper.Commands, nil
}

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

func (c *Client) RefreshToken(refreshToken string) (*LoginResponse, error) {
	resp, err := c.postJSON("/api/v1/auth/refresh", map[string]string{"refresh_token": refreshToken})
	if err != nil {
		return nil, fmt.Errorf("refresh token: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result LoginResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode refresh: %w", err)
	}
	c.Token = result.Token
	return &result, nil
}

func (c *Client) Logout() error {
	resp, err := c.postJSON("/api/v1/auth/logout", nil)
	if err != nil {
		return fmt.Errorf("logout: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
		return c.parseError(resp)
	}
	c.Token = ""
	return nil
}

func (c *Client) ListSessions() ([]SessionInfo, error) {
	resp, err := c.get("/api/v1/sessions")
	if err != nil {
		return nil, fmt.Errorf("list sessions: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var wrapper struct {
		Sessions []SessionInfo `json:"sessions"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrapper); err != nil {
		return nil, fmt.Errorf("decode sessions: %w", err)
	}
	return wrapper.Sessions, nil
}

func (c *Client) CreateSession() (*SessionCreateResponse, error) {
	resp, err := c.postJSON("/api/v1/sessions", nil)
	if err != nil {
		return nil, fmt.Errorf("create session: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return nil, c.parseError(resp)
	}
	var result SessionCreateResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode session: %w", err)
	}
	return &result, nil
}

func (c *Client) ListModels() (*ModelListResponse, error) {
	resp, err := c.get("/api/v1/models")
	if err != nil {
		return nil, fmt.Errorf("list models: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result ModelListResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode models: %w", err)
	}
	return &result, nil
}

func (c *Client) SwitchModel(req ModelSwitchRequest) (*ModelSwitchResponse, error) {
	resp, err := c.postJSON("/api/v1/models/switch", req)
	if err != nil {
		return nil, fmt.Errorf("switch model: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result ModelSwitchResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode switch: %w", err)
	}
	return &result, nil
}

func (c *Client) GetSession(id string) (*SessionInfo, error) {
	resp, err := c.get(fmt.Sprintf("/api/v1/sessions/%s", id))
	if err != nil {
		return nil, fmt.Errorf("get session: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result SessionInfo
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode session: %w", err)
	}
	return &result, nil
}

func (c *Client) GetSessionMessages(id string) ([]SessionMessage, error) {
	resp, err := c.get(fmt.Sprintf("/api/v1/sessions/%s/messages", id))
	if err != nil {
		return nil, fmt.Errorf("get session messages: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var wrapper struct {
		Messages []SessionMessage `json:"messages"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrapper); err != nil {
		return nil, fmt.Errorf("decode messages: %w", err)
	}
	return wrapper.Messages, nil
}

// -- Classify -----------------------------------------------------------------

func (c *Client) Classify(message, channel string) (*ClassifyResponse, error) {
	resp, err := c.postJSON("/api/v1/classify", ClassifyRequest{Message: message, Channel: channel})
	if err != nil {
		return nil, fmt.Errorf("classify: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result ClassifyResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode classify: %w", err)
	}
	return &result, nil
}

// -- Tool execution -----------------------------------------------------------

func (c *Client) ExecuteTool(name string, args map[string]any) (*ToolExecuteResponse, error) {
	resp, err := c.postJSON(fmt.Sprintf("/api/v1/tools/%s/execute", name), ToolExecuteRequest{Arguments: args})
	if err != nil {
		return nil, fmt.Errorf("execute tool: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result ToolExecuteResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode tool execute: %w", err)
	}
	return &result, nil
}

// -- Skills -------------------------------------------------------------------

func (c *Client) ListSkills() ([]SkillEntry, error) {
	resp, err := c.get("/api/v1/skills")
	if err != nil {
		return nil, fmt.Errorf("list skills: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var wrapper struct {
		Skills []SkillEntry `json:"skills"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrapper); err != nil {
		return nil, fmt.Errorf("decode skills: %w", err)
	}
	return wrapper.Skills, nil
}

func (c *Client) CreateSkill(req SkillCreateRequest) (*SkillCreateResponse, error) {
	resp, err := c.postJSON("/api/v1/skills/create", req)
	if err != nil {
		return nil, fmt.Errorf("create skill: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return nil, c.parseError(resp)
	}
	var result SkillCreateResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode skill create: %w", err)
	}
	return &result, nil
}

// -- Complex orchestration ----------------------------------------------------

func (c *Client) LaunchComplexTask(req ComplexTaskRequest) (*ComplexTaskResponse, error) {
	resp, err := c.postJSON("/api/v1/orchestrate/complex", req)
	if err != nil {
		return nil, fmt.Errorf("complex task: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		return nil, c.parseError(resp)
	}
	var result ComplexTaskResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode complex task: %w", err)
	}
	return &result, nil
}

func (c *Client) GetTaskProgress(taskID string) (*TaskProgress, error) {
	resp, err := c.get(fmt.Sprintf("/api/v1/orchestrate/%s/progress", taskID))
	if err != nil {
		return nil, fmt.Errorf("task progress: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result TaskProgress
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode task progress: %w", err)
	}
	return &result, nil
}

func (c *Client) ListOrchestratedTasks() ([]OrchestratedTask, error) {
	resp, err := c.get("/api/v1/orchestrate/tasks")
	if err != nil {
		return nil, fmt.Errorf("list orchestrated tasks: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var wrapper struct {
		Tasks []OrchestratedTask `json:"tasks"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrapper); err != nil {
		return nil, fmt.Errorf("decode orchestrated tasks: %w", err)
	}
	return wrapper.Tasks, nil
}

// -- Swarm management ---------------------------------------------------------

func (c *Client) LaunchSwarm(req SwarmLaunchRequest) (*SwarmLaunchResponse, error) {
	resp, err := c.postJSON("/api/v1/swarm/launch", req)
	if err != nil {
		return nil, fmt.Errorf("launch swarm: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		return nil, c.parseError(resp)
	}
	var result SwarmLaunchResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode swarm launch: %w", err)
	}
	return &result, nil
}

func (c *Client) ListSwarms() (*SwarmListResponse, error) {
	resp, err := c.get("/api/v1/swarm")
	if err != nil {
		return nil, fmt.Errorf("list swarms: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result SwarmListResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode swarms: %w", err)
	}
	return &result, nil
}

func (c *Client) GetSwarmStatus(swarmID string) (*SwarmStatus, error) {
	resp, err := c.get(fmt.Sprintf("/api/v1/swarm/%s", swarmID))
	if err != nil {
		return nil, fmt.Errorf("swarm status: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result SwarmStatus
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode swarm status: %w", err)
	}
	return &result, nil
}

func (c *Client) CancelSwarm(swarmID string) error {
	resp, err := c.delete(fmt.Sprintf("/api/v1/swarm/%s", swarmID))
	if err != nil {
		return fmt.Errorf("cancel swarm: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return c.parseError(resp)
	}
	return nil
}

// -- Memory -------------------------------------------------------------------

func (c *Client) SaveMemory(content, category string) (*MemorySaveResponse, error) {
	resp, err := c.postJSON("/api/v1/memory", MemorySaveRequest{Content: content, Category: category})
	if err != nil {
		return nil, fmt.Errorf("save memory: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return nil, c.parseError(resp)
	}
	var result MemorySaveResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode memory save: %w", err)
	}
	return &result, nil
}

func (c *Client) RecallMemory() (*MemoryRecallResponse, error) {
	resp, err := c.get("/api/v1/memory/recall")
	if err != nil {
		return nil, fmt.Errorf("recall memory: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result MemoryRecallResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode memory recall: %w", err)
	}
	return &result, nil
}

// -- Analytics ----------------------------------------------------------------

func (c *Client) GetAnalytics() (*AnalyticsResponse, error) {
	resp, err := c.get("/api/v1/analytics")
	if err != nil {
		return nil, fmt.Errorf("analytics: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result AnalyticsResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode analytics: %w", err)
	}
	return &result, nil
}

// -- Scheduler ----------------------------------------------------------------

func (c *Client) ListSchedulerJobs() ([]SchedulerJob, error) {
	resp, err := c.get("/api/v1/scheduler/jobs")
	if err != nil {
		return nil, fmt.Errorf("list scheduler jobs: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var wrapper struct {
		Jobs []SchedulerJob `json:"jobs"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrapper); err != nil {
		return nil, fmt.Errorf("decode scheduler jobs: %w", err)
	}
	return wrapper.Jobs, nil
}

func (c *Client) ReloadScheduler() error {
	resp, err := c.postJSON("/api/v1/scheduler/reload", nil)
	if err != nil {
		return fmt.Errorf("reload scheduler: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		return c.parseError(resp)
	}
	return nil
}

// -- Machines -----------------------------------------------------------------

func (c *Client) ListMachines() ([]MachineInfo, error) {
	resp, err := c.get("/api/v1/machines")
	if err != nil {
		return nil, fmt.Errorf("list machines: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var wrapper struct {
		Machines []MachineInfo `json:"machines"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrapper); err != nil {
		return nil, fmt.Errorf("decode machines: %w", err)
	}
	return wrapper.Machines, nil
}

// -- Onboarding ---------------------------------------------------------------

func (c *Client) CheckOnboarding() (*OnboardingStatusResponse, error) {
	resp, err := c.get("/onboarding/status")
	if err != nil {
		return nil, fmt.Errorf("check onboarding: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result OnboardingStatusResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode onboarding status: %w", err)
	}
	return &result, nil
}

func (c *Client) CompleteOnboarding(req OnboardingSetupRequest) (*OnboardingSetupResponse, error) {
	resp, err := c.postJSON("/onboarding/setup", req)
	if err != nil {
		return nil, fmt.Errorf("complete onboarding: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, c.parseError(resp)
	}
	var result OnboardingSetupResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode onboarding setup: %w", err)
	}
	return &result, nil
}

// -- HTTP helpers -------------------------------------------------------------

func (c *Client) get(path string) (*http.Response, error) {
	req, err := http.NewRequest("GET", c.BaseURL+path, nil)
	if err != nil {
		return nil, err
	}
	c.setHeaders(req)
	return c.HTTPClient.Do(req)
}

func (c *Client) postJSON(path string, body any) (*http.Response, error) {
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

func (c *Client) delete(path string) (*http.Response, error) {
	req, err := http.NewRequest("DELETE", c.BaseURL+path, nil)
	if err != nil {
		return nil, err
	}
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
