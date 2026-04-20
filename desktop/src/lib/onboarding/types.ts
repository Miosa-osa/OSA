export type Provider =
  | "ollama"
  | "ollama-cloud"
  | "lmstudio"
  | "anthropic"
  | "openai"
  | "groq";
export type OnboardingStep = 1 | 2 | 3 | 4 | "complete";

export interface DetectionResult {
  ollama: boolean;
  lmstudio: boolean;
}

export interface WorkspaceConfig {
  name: string;
  description?: string;
  workingDirectory: string;
}

export type AuthMethod = "api_key" | "oauth";

export interface OnboardingState {
  step: OnboardingStep;
  provider: Provider | null;
  detectedProviders: DetectionResult;
  detecting: boolean;
  authMethod: AuthMethod;
  apiKey: string;
  oauthConnected: boolean;
  oauthProfile: { email?: string; name?: string } | null;
  workingDirectory: string;
  workspace: WorkspaceConfig | null;
  agentName: string;
  firstTask: string;
}

export interface ProviderMeta {
  id: Provider;
  name: string;
  tagline: string;
  requiresKey: boolean;
  supportsOAuth: boolean;
  keyPlaceholder: string;
  keyDocsUrl: string;
}

export const PROVIDERS: ProviderMeta[] = [
  {
    id: "ollama",
    name: "Ollama (Local)",
    tagline: "Local · Free · Auto-detected",
    requiresKey: false,
    supportsOAuth: false,
    keyPlaceholder: "",
    keyDocsUrl: "",
  },
  {
    id: "ollama-cloud",
    name: "Ollama (Cloud)",
    tagline: "Remote Ollama instance",
    requiresKey: true,
    supportsOAuth: false,
    keyPlaceholder: "http://your-server:11434",
    keyDocsUrl: "https://github.com/ollama/ollama/blob/main/docs/faq.md",
  },
  {
    id: "lmstudio",
    name: "LM Studio",
    tagline: "Local · Free",
    requiresKey: false,
    supportsOAuth: false,
    keyPlaceholder: "",
    keyDocsUrl: "",
  },
  {
    id: "anthropic",
    name: "Anthropic",
    tagline: "Claude models · Sign in or use API key",
    requiresKey: true,
    supportsOAuth: true,
    keyPlaceholder: "sk-ant-api03-...",
    keyDocsUrl: "https://console.anthropic.com/settings/keys",
  },
  {
    id: "openai",
    name: "OpenAI",
    tagline: "GPT models",
    requiresKey: true,
    supportsOAuth: false,
    keyPlaceholder: "sk-...",
    keyDocsUrl: "https://platform.openai.com/api-keys",
  },
  {
    id: "groq",
    name: "Groq",
    tagline: "Fast inference",
    requiresKey: true,
    supportsOAuth: false,
    keyPlaceholder: "gsk_...",
    keyDocsUrl: "https://console.groq.com/keys",
  },
];
