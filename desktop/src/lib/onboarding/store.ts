import { load, type Store } from "@tauri-apps/plugin-store";
import { homeDir } from "@tauri-apps/api/path";
import type { Provider, WorkspaceConfig } from "./types";

let _store: Store | null = null;

async function getStore(): Promise<Store> {
  if (!_store) {
    _store = await load("store.json", { autoSave: true, defaults: {} });
  }
  return _store;
}

export async function isOnboardingComplete(): Promise<boolean> {
  const store = await getStore();
  return (await store.get<boolean>("onboardingComplete")) ?? false;
}

export async function getDefaultWorkingDirectory(): Promise<string> {
  return homeDir();
}

export async function completeOnboarding(opts: {
  workspace: WorkspaceConfig;
  provider: Provider;
  model?: string;
  apiKey: string;
  agentName?: string;
  firstTask?: string;
}): Promise<void> {
  const store = await getStore();
  await store.set("onboardingComplete", true);
  await store.set("provider", opts.provider);
  await store.set("workingDirectory", opts.workspace.workingDirectory);
  await store.set("workspaceName", opts.workspace.name);
  await store.set("workspaceDescription", opts.workspace.description ?? "");
  await store.set("apiKey", opts.apiKey);
  await store.set("agentName", opts.agentName ?? "OSA Agent");
  await store.set("firstTask", opts.firstTask ?? "");
  await store.set("onboardingCompletedAt", new Date().toISOString());
  await store.save();

  // Notify the backend of the selected provider, model, API key, and workspace
  try {
    await fetch("http://127.0.0.1:9089/onboarding/setup", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        provider: opts.provider,
        model: opts.model ?? null,
        api_key: opts.apiKey || null,
        workspace_name: opts.workspace.name,
        workspace_description: opts.workspace.description ?? null,
        working_directory: opts.workspace.workingDirectory,
        agent_name: opts.agentName ?? "OSA Agent",
        first_task: opts.firstTask ?? null,
      }),
    });
  } catch {
    // Backend may not yet be ready — non-fatal, setup can be retried
  }
}
