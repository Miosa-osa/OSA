// src/lib/types/chat.ts

export type MessageRole = "user" | "assistant" | "system";
export type MessageStatus = "pending" | "streaming" | "complete" | "error";

export interface TextPart {
  type: "text";
  text: string;
}

export interface CodePart {
  type: "code";
  language: string;
  code: string;
}

export interface ToolCallPart {
  type: "tool_call";
  toolUseId: string;
  toolName: string;
  input: Record<string, unknown>;
  result?: string;
  isExpanded: boolean;
}

export interface ThinkingPart {
  type: "thinking";
  text: string;
  isExpanded: boolean;
}

export interface FilePart {
  type: "file";
  name: string;
  mimeType: string;
  /** base64 or blob URL after upload */
  dataUrl: string;
  sizeBytes: number;
}

export type MessagePart =
  | TextPart
  | CodePart
  | ToolCallPart
  | ThinkingPart
  | FilePart;

export interface ChatMessage {
  id: string;
  role: MessageRole;
  parts: MessagePart[];
  status: MessageStatus;
  createdAt: number;
}

/** Raw SSE event shapes from the Elixir backend */
export interface SSETextDelta {
  type: "text_delta";
  delta: string;
}

export interface SSEToolUse {
  type: "tool_use";
  tool_use_id: string;
  tool_name: string;
  input: Record<string, unknown>;
}

export interface SSEToolResult {
  type: "tool_result";
  tool_use_id: string;
  result: string;
}

export interface SSEThinkingDelta {
  type: "thinking_delta";
  delta: string;
}

export interface SSEDone {
  type: "done";
}

export interface SSEError {
  type: "error";
  message: string;
}

export type SSEEvent =
  | SSETextDelta
  | SSEToolUse
  | SSEToolResult
  | SSEThinkingDelta
  | SSEDone
  | SSEError;

export type ModelId =
  | "claude-opus-4-6"
  | "claude-sonnet-4-6"
  | "claude-haiku-3-5";

export interface ChatConfig {
  model: ModelId;
  baseUrl: string;
  maxReconnectAttempts: number;
  reconnectDelayMs: number;
}
