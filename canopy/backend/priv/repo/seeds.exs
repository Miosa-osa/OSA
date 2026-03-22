import Ecto.Query

alias Canopy.Repo

alias Canopy.Schemas.{
  User,
  Workspace,
  Agent,
  Schedule,
  Project,
  Goal,
  Issue,
  BudgetPolicy,
  Skill,
  ActivityEvent,
  Integration
}

IO.puts("\n=== Canopy Dev Seeds ===\n")

# ---------------------------------------------------------------------------
# SECTION 1: Users
# ---------------------------------------------------------------------------

IO.puts("[1/10] Users...")

Repo.insert(
  User.changeset(%User{}, %{
    name: "Roberto Luna",
    email: "admin@canopy.dev",
    password: "canopy123",
    role: "admin"
  }),
  on_conflict: :nothing,
  conflict_target: :email
)

Repo.insert(
  User.changeset(%User{}, %{
    name: "Dev User",
    email: "dev@canopy.dev",
    password: "canopy123",
    role: "member"
  }),
  on_conflict: :nothing,
  conflict_target: :email
)

admin = Repo.get_by!(User, email: "admin@canopy.dev")
_dev_user = Repo.get_by!(User, email: "dev@canopy.dev")

IO.puts("    admin@canopy.dev (admin), dev@canopy.dev (member)")

# ---------------------------------------------------------------------------
# SECTION 2: Workspace
# ---------------------------------------------------------------------------

IO.puts("[2/10] Workspace...")

Repo.insert(
  Workspace.changeset(%Workspace{}, %{
    name: "OSA Development",
    path: Path.expand("~/.canopy/default"),
    status: "active",
    owner_id: admin.id
  }),
  on_conflict: :nothing
)

workspace = Repo.one!(from w in Workspace, where: w.owner_id == ^admin.id, limit: 1)

IO.puts("    \"OSA Development\" (#{workspace.id})")

# ---------------------------------------------------------------------------
# SECTION 3: Agents
# ---------------------------------------------------------------------------

IO.puts("[3/10] Agents...")

# Orchestrator must be inserted first so subordinates can reference its id.
unless Repo.exists?(from a in Agent, where: a.workspace_id == ^workspace.id and a.slug == "orchestrator") do
  Repo.insert!(
    Agent.changeset(%Agent{}, %{
      slug: "orchestrator",
      name: "Orchestrator",
      role: "orchestrator",
      adapter: "osa",
      model: "claude-opus-4-6",
      status: "idle",
      reports_to: nil,
      workspace_id: workspace.id
    })
  )
end

orchestrator = Repo.get_by!(Agent, workspace_id: workspace.id, slug: "orchestrator")

subordinate_agents = [
  %{
    slug: "researcher",
    name: "Research Agent",
    role: "researcher",
    adapter: "claude-code",
    model: "claude-sonnet-4-6",
    status: "sleeping",
    reports_to: orchestrator.id
  },
  %{
    slug: "developer",
    name: "Developer Agent",
    role: "developer",
    adapter: "claude-code",
    model: "claude-sonnet-4-6",
    status: "sleeping",
    reports_to: orchestrator.id
  },
  %{
    slug: "reviewer",
    name: "Code Reviewer",
    role: "reviewer",
    adapter: "claude-code",
    model: "claude-sonnet-4-6",
    status: "sleeping",
    reports_to: orchestrator.id
  },
  %{
    slug: "devops",
    name: "DevOps Agent",
    role: "devops",
    adapter: "bash",
    model: "bash",
    status: "sleeping",
    reports_to: orchestrator.id
  },
  %{
    slug: "api-monitor",
    name: "API Monitor",
    role: "monitor",
    adapter: "http",
    model: "http",
    status: "sleeping",
    reports_to: orchestrator.id
  }
]

for attrs <- subordinate_agents do
  unless Repo.exists?(from a in Agent, where: a.workspace_id == ^workspace.id and a.slug == ^attrs.slug) do
    Repo.insert!(Agent.changeset(%Agent{}, Map.put(attrs, :workspace_id, workspace.id)))
  end
end

developer = Repo.get_by!(Agent, workspace_id: workspace.id, slug: "developer")
reviewer = Repo.get_by!(Agent, workspace_id: workspace.id, slug: "reviewer")
devops = Repo.get_by!(Agent, workspace_id: workspace.id, slug: "devops")
researcher = Repo.get_by!(Agent, workspace_id: workspace.id, slug: "researcher")

IO.puts("    6 agents: orchestrator (osa), researcher, developer, reviewer (claude-code), devops (bash), api-monitor (http)")

# ---------------------------------------------------------------------------
# SECTION 4: Schedules
# ---------------------------------------------------------------------------

IO.puts("[4/10] Schedules...")

schedules = [
  %{
    name: "Morning standup",
    cron_expression: "0 9 * * 1-5",
    context: "Run daily standup: summarize yesterday's completed issues, flag blockers, list today's priorities.",
    enabled: false,
    workspace_id: workspace.id,
    agent_id: researcher.id
  },
  %{
    name: "Nightly code review",
    cron_expression: "0 2 * * *",
    context: "Review all pull requests opened today. Post review comments and summary report.",
    enabled: false,
    workspace_id: workspace.id,
    agent_id: reviewer.id
  },
  %{
    name: "Infrastructure check",
    cron_expression: "*/30 * * * *",
    context: "Check service health endpoints, disk usage, and container status. Alert on anomalies.",
    enabled: false,
    workspace_id: workspace.id,
    agent_id: devops.id
  }
]

for attrs <- schedules do
  unless Repo.exists?(from s in Schedule, where: s.workspace_id == ^workspace.id and s.name == ^attrs.name) do
    Repo.insert!(Schedule.changeset(%Schedule{}, attrs))
  end
end

IO.puts("    3 schedules (all disabled): morning standup, nightly code review, infrastructure check")

# ---------------------------------------------------------------------------
# SECTION 5: Projects
# ---------------------------------------------------------------------------

IO.puts("[5/10] Projects...")

unless Repo.exists?(from p in Project, where: p.workspace_id == ^workspace.id and p.name == "Canopy Platform") do
  Repo.insert!(%Project{
    name: "Canopy Platform",
    description: "The Canopy Command Center desktop application and backend API.",
    status: "active",
    workspace_id: workspace.id
  })
end

unless Repo.exists?(from p in Project, where: p.workspace_id == ^workspace.id and p.name == "Infrastructure") do
  Repo.insert!(%Project{
    name: "Infrastructure",
    description: "CI/CD pipelines, deployment automation, and monitoring setup.",
    status: "active",
    workspace_id: workspace.id
  })
end

canopy_project = Repo.get_by!(Project, workspace_id: workspace.id, name: "Canopy Platform")
infra_project = Repo.get_by!(Project, workspace_id: workspace.id, name: "Infrastructure")

IO.puts("    2 projects: \"Canopy Platform\", \"Infrastructure\"")

# ---------------------------------------------------------------------------
# SECTION 6: Goals
# ---------------------------------------------------------------------------

IO.puts("[6/10] Goals...")

unless Repo.exists?(from g in Goal, where: g.workspace_id == ^workspace.id and g.title == "Launch MVP") do
  Repo.insert!(%Goal{
    title: "Launch MVP",
    description: "Ship the first production-ready release of Canopy with core agent management features.",
    status: "active",
    workspace_id: workspace.id,
    project_id: canopy_project.id
  })
end

launch_mvp = Repo.get_by!(Goal, workspace_id: workspace.id, title: "Launch MVP")

unless Repo.exists?(from g in Goal, where: g.workspace_id == ^workspace.id and g.title == "Implement Adapter System") do
  Repo.insert!(%Goal{
    title: "Implement Adapter System",
    description: "Build the pluggable adapter layer supporting osa, claude-code, bash, http, and codex adapters.",
    status: "active",
    workspace_id: workspace.id,
    project_id: canopy_project.id,
    parent_id: launch_mvp.id
  })
end

unless Repo.exists?(from g in Goal, where: g.workspace_id == ^workspace.id and g.title == "Setup CI/CD") do
  Repo.insert!(%Goal{
    title: "Setup CI/CD",
    description: "Automated build, test, and deployment pipeline via GitHub Actions.",
    status: "active",
    workspace_id: workspace.id,
    project_id: infra_project.id
  })
end

unless Repo.exists?(from g in Goal, where: g.workspace_id == ^workspace.id and g.title == "Security Audit") do
  Repo.insert!(%Goal{
    title: "Security Audit",
    description: "OWASP Top 10 review, JWT hardening, tenant isolation validation.",
    status: "active",
    workspace_id: workspace.id,
    project_id: infra_project.id
  })
end

IO.puts("    4 goals: Launch MVP, Implement Adapter System (child), Setup CI/CD, Security Audit")

# ---------------------------------------------------------------------------
# SECTION 7: Issues
# ---------------------------------------------------------------------------

IO.puts("[7/10] Issues...")

adapter_goal = Repo.get_by!(Goal, workspace_id: workspace.id, title: "Implement Adapter System")
cicd_goal = Repo.get_by!(Goal, workspace_id: workspace.id, title: "Setup CI/CD")
security_goal = Repo.get_by!(Goal, workspace_id: workspace.id, title: "Security Audit")

issues = [
  %{
    title: "Implement OSA adapter",
    description: "Wire up the OSA adapter to the agent execution engine. Support tool calling and streaming responses.",
    status: "todo",
    priority: "high",
    workspace_id: workspace.id,
    project_id: canopy_project.id,
    goal_id: adapter_goal.id,
    assignee_id: developer.id
  },
  %{
    title: "Write integration tests",
    description: "Integration test suite covering adapter execution, session lifecycle, and budget enforcement.",
    status: "backlog",
    priority: "medium",
    workspace_id: workspace.id,
    project_id: canopy_project.id,
    goal_id: adapter_goal.id
  },
  %{
    title: "Fix SSE connection drops",
    description: "SSE stream disconnects after ~30s under load. Suspected Bandit keepalive timeout misconfiguration.",
    status: "in_progress",
    priority: "critical",
    workspace_id: workspace.id,
    project_id: canopy_project.id,
    goal_id: launch_mvp.id,
    assignee_id: developer.id
  },
  %{
    title: "Add budget enforcement UI",
    description: "Budget policy editor in the Canopy UI: set monthly limits, warning thresholds, and view spend history.",
    status: "todo",
    priority: "medium",
    workspace_id: workspace.id,
    project_id: canopy_project.id,
    goal_id: launch_mvp.id
  },
  %{
    title: "Review auth flow",
    description: "Audit JWT issuance, refresh token rotation, and Guardian plug configuration for production readiness.",
    status: "in_review",
    priority: "high",
    workspace_id: workspace.id,
    project_id: infra_project.id,
    goal_id: security_goal.id,
    assignee_id: reviewer.id
  },
  %{
    title: "Setup monitoring dashboards",
    description: "Grafana dashboards for agent session throughput, budget burn rate, and BEAM VM health metrics.",
    status: "backlog",
    priority: "low",
    workspace_id: workspace.id,
    project_id: infra_project.id,
    goal_id: cicd_goal.id,
    assignee_id: devops.id
  }
]

for attrs <- issues do
  unless Repo.exists?(from i in Issue, where: i.workspace_id == ^workspace.id and i.title == ^attrs.title) do
    Repo.insert!(Issue.changeset(%Issue{}, attrs))
  end
end

IO.puts("    6 issues: 2 todo, 1 in_progress (critical), 1 in_review, 2 backlog")

# ---------------------------------------------------------------------------
# SECTION 8: Budget Policies
# ---------------------------------------------------------------------------

IO.puts("[8/10] Budget policies...")

unless Repo.exists?(from b in BudgetPolicy, where: b.scope_type == "agent" and b.scope_id == ^orchestrator.id) do
  Repo.insert!(
    BudgetPolicy.changeset(%BudgetPolicy{}, %{
      scope_type: "agent",
      scope_id: orchestrator.id,
      monthly_limit_cents: 5_000,
      warning_threshold_pct: 80,
      hard_stop: true
    })
  )
end

unless Repo.exists?(from b in BudgetPolicy, where: b.scope_type == "workspace" and b.scope_id == ^workspace.id) do
  Repo.insert!(
    BudgetPolicy.changeset(%BudgetPolicy{}, %{
      scope_type: "workspace",
      scope_id: workspace.id,
      monthly_limit_cents: 20_000,
      warning_threshold_pct: 70,
      hard_stop: true
    })
  )
end

IO.puts("    2 policies: orchestrator $50/mo (80% warn), workspace $200/mo (70% warn)")

# ---------------------------------------------------------------------------
# SECTION 9: Skills
# ---------------------------------------------------------------------------

IO.puts("[9/10] Skills...")

skills = [
  %{
    name: "Code Generation",
    description: "Generate, refactor, and review source code across multiple languages.",
    category: "Development",
    enabled: true,
    trigger_rules: %{keywords: ["implement", "write", "refactor", "generate code"]},
    workspace_id: workspace.id
  },
  %{
    name: "Web Search",
    description: "Search the web for documentation, research papers, and technical references.",
    category: "Research",
    enabled: true,
    trigger_rules: %{keywords: ["search", "find", "look up", "research"]},
    workspace_id: workspace.id
  },
  %{
    name: "PR Review",
    description: "Review pull requests for correctness, security, and style adherence.",
    category: "Development",
    enabled: true,
    trigger_rules: %{keywords: ["review", "PR", "pull request", "LGTM"]},
    workspace_id: workspace.id
  },
  %{
    name: "Deployment",
    description: "Deploy services to staging and production via automated pipelines.",
    category: "Operations",
    enabled: false,
    trigger_rules: %{keywords: ["deploy", "release", "rollout", "ship"]},
    workspace_id: workspace.id
  }
]

for attrs <- skills do
  unless Repo.exists?(from s in Skill, where: s.workspace_id == ^workspace.id and s.name == ^attrs.name) do
    Repo.insert!(Skill.changeset(%Skill{}, attrs))
  end
end

IO.puts("    4 skills: Code Generation, Web Search, PR Review (enabled), Deployment (disabled)")

# ---------------------------------------------------------------------------
# SECTION 10: Activity Events
# ---------------------------------------------------------------------------

IO.puts("[10/10] Activity events & integrations...")

now = DateTime.utc_now() |> DateTime.truncate(:second)

activity_seeds = [
  %{
    event_type: "agent.hired",
    message: "Agent 'Orchestrator' added to workspace OSA Development.",
    level: "info",
    metadata: %{agent_slug: "orchestrator", adapter: "osa"},
    workspace_id: workspace.id,
    agent_id: orchestrator.id,
    inserted_at: DateTime.add(now, -86_400 * 5, :second)
  },
  %{
    event_type: "agent.hired",
    message: "Agent 'Developer Agent' added to workspace OSA Development.",
    level: "info",
    metadata: %{agent_slug: "developer", adapter: "claude-code"},
    workspace_id: workspace.id,
    agent_id: developer.id,
    inserted_at: DateTime.add(now, -86_400 * 4, :second)
  },
  %{
    event_type: "session.completed",
    message: "Orchestrator completed session: architecture planning for Canopy adapter system.",
    level: "info",
    metadata: %{duration_ms: 42_300, tokens_used: 18_400},
    workspace_id: workspace.id,
    agent_id: orchestrator.id,
    inserted_at: DateTime.add(now, -86_400 * 3, :second)
  },
  %{
    event_type: "session.completed",
    message: "Developer Agent completed session: implemented OSA adapter scaffold.",
    level: "info",
    metadata: %{duration_ms: 91_200, tokens_used: 34_750},
    workspace_id: workspace.id,
    agent_id: developer.id,
    inserted_at: DateTime.add(now, -86_400 * 2, :second)
  },
  %{
    event_type: "budget.warning",
    message: "Workspace budget at 72% of monthly limit ($144 / $200).",
    level: "warn",
    metadata: %{spent_cents: 14_400, limit_cents: 20_000, pct: 72},
    workspace_id: workspace.id,
    inserted_at: DateTime.add(now, -86_400, :second)
  },
  %{
    event_type: "issue.status_changed",
    message: "Issue 'Fix SSE connection drops' moved to in_progress by Developer Agent.",
    level: "info",
    metadata: %{from_status: "todo", to_status: "in_progress", issue_title: "Fix SSE connection drops"},
    workspace_id: workspace.id,
    agent_id: developer.id,
    inserted_at: DateTime.add(now, -3_600 * 6, :second)
  },
  %{
    event_type: "session.started",
    message: "Code Reviewer started review session for auth flow issue.",
    level: "info",
    metadata: %{issue_title: "Review auth flow"},
    workspace_id: workspace.id,
    agent_id: reviewer.id,
    inserted_at: DateTime.add(now, -3_600 * 2, :second)
  },
  %{
    event_type: "agent.error",
    message: "API Monitor failed health check: endpoint /api/health returned 503.",
    level: "error",
    metadata: %{endpoint: "/api/health", status_code: 503, retry_count: 3},
    workspace_id: workspace.id,
    inserted_at: DateTime.add(now, -1_800, :second)
  }
]

for attrs <- activity_seeds do
  Repo.insert!(
    ActivityEvent.changeset(%ActivityEvent{}, Map.drop(attrs, [:inserted_at]))
    |> Ecto.Changeset.put_change(:inserted_at, attrs.inserted_at),
    on_conflict: :nothing
  )
end

# ---------------------------------------------------------------------------
# Integrations
# ---------------------------------------------------------------------------

integrations = [
  %{
    slug: "anthropic",
    name: "Anthropic",
    category: "AI Provider",
    config: %{api_key_set: true, default_model: "claude-opus-4-6"},
    connected: true,
    workspace_id: workspace.id,
    last_synced_at: DateTime.add(now, -3_600, :second)
  },
  %{
    slug: "github",
    name: "GitHub",
    category: "Version Control",
    config: %{},
    connected: false,
    workspace_id: workspace.id
  }
]

for attrs <- integrations do
  unless Repo.exists?(from i in Integration, where: i.workspace_id == ^workspace.id and i.slug == ^attrs.slug) do
    Repo.insert!(
      Integration.changeset(%Integration{}, Map.drop(attrs, [:last_synced_at]))
      |> then(fn cs ->
        case Map.get(attrs, :last_synced_at) do
          nil -> cs
          ts -> Ecto.Changeset.put_change(cs, :last_synced_at, ts)
        end
      end)
    )
  end
end

IO.puts("    8 activity events, 2 integrations (anthropic connected, github disconnected)")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

IO.puts("""

=== Seed complete ===

  Users       admin@canopy.dev (admin), dev@canopy.dev (member)
  Workspace   \"OSA Development\"
  Agents      6  (orchestrator, researcher, developer, reviewer, devops, api-monitor)
  Schedules   3  (all disabled)
  Projects    2  (Canopy Platform, Infrastructure)
  Goals       4  (Launch MVP + child, Setup CI/CD, Security Audit)
  Issues      6  (todo x2, in_progress x1, in_review x1, backlog x2)
  Budgets     2  (agent $50/mo, workspace $200/mo)
  Skills      4  (3 enabled, 1 disabled)
  Events      8  activity entries
  Integrations  2  (anthropic connected, github disconnected)
""")
