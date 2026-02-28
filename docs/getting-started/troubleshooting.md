# Troubleshooting Guide

> Common issues and solutions

## Diagnostics

Run the built-in doctor:
```
/doctor
```

This checks:
- Provider connectivity
- Channel status
- Sidecar health
- Database integrity
- Memory system
- Configuration validity

---

## Provider Issues

### "No provider configured"

**Cause**: No API keys found, and Ollama not running.

**Fix**:
```bash
# Option 1: Set an API key
echo 'ANTHROPIC_API_KEY=sk-ant-...' >> ~/.osa/.env

# Option 2: Start Ollama
ollama serve
ollama pull llama3.2:latest
```

### "Provider timeout" or "Connection refused"

**Cause**: API rate limit, network issue, or provider outage.

**Fix**:
```bash
# Check provider status
/model

# Switch to fallback
/model openai

# Check budget (may be exhausted)
/budget
```

### "Model not found" (Ollama)

**Cause**: Model not pulled or wrong name.

**Fix**:
```bash
ollama list                    # See available models
ollama pull llama3.2:latest    # Pull the model
/model ollama llama3.2:latest  # Use it
```

### Health endpoint shows wrong model

**Cause**: Prior to `ec37944`, the health endpoint read `OLLAMA_MODEL` regardless of active provider.

**Fix**: Now resolved automatically. The model name resolves from provider-specific env vars:
```bash
# Override for any provider
export OSA_MODEL=my-custom-model

# Or set provider-specific
export GROQ_MODEL=llama-3.3-70b-versatile
export ANTHROPIC_MODEL=claude-sonnet-4-6
export OPENAI_MODEL=gpt-4o
```

### Hallucinated tool calls from small models

**Cause**: Model too small for tool use, but tool gating not working.

**Fix**: OSA automatically gates tools for models < 7GB. If you see hallucinated tool calls:
```bash
# Use a larger model
/model ollama llama3.3:70b

# Or switch to a cloud provider
/model anthropic
```

---

## Channel Issues

### Channel not connecting

**Cause**: Missing or invalid credentials.

**Fix**:
```bash
/channels status           # Check which channels are configured
# Verify credentials in ~/.osa/.env
cat ~/.osa/.env | grep TELEGRAM
```

### Telegram: "Conflict: terminated by other getUpdates request"

**Cause**: Multiple OSA instances polling the same bot.

**Fix**: Ensure only one OSA instance runs per Telegram bot token.

### WhatsApp: "Webhook verification failed"

**Cause**: Verify token mismatch.

**Fix**: Ensure `WHATSAPP_VERIFY_TOKEN` in `.env` matches what you configured in Meta Developer Portal.

---

## Database Issues

### "Database is locked"

**Cause**: Multiple processes accessing SQLite simultaneously.

**Fix**:
```bash
# Ensure only one OSA instance per database
ps aux | grep osa

# If stuck, remove the lock (safe with WAL mode)
rm ~/.osa/osa.db-wal ~/.osa/osa.db-shm

# Restart OSA
```

### Migration errors on startup

**Cause**: Schema mismatch after update.

**Fix**:
```bash
mix ecto.migrate
# Or for release:
_build/prod/rel/optimal_system_agent/bin/optimal_system_agent eval "OptimalSystemAgent.Release.migrate()"
```

---

## Memory Issues

### "Context too large" / Emergency compaction

**Cause**: Conversation exceeded token budget.

**Fix**:
```bash
# Check usage
/usage

# Manual compact
/compact

# Start fresh session
/new

# Lower token limits in config
# max_tokens: 4096 → 2048
```

### Memory search returns nothing

**Cause**: Memory not populated or search terms too specific.

**Fix**:
```bash
# Check memory stats
/mem-stats

# Try broader search
/mem-search <broader-term>

# Manually save important context
/mem-save context "Important thing to remember"
```

---

## Sidecar Issues

### Go tokenizer not starting

**Cause**: Binary not compiled or not found.

**Fix**:
```bash
# Check if enabled
echo $OSA_GO_TOKENIZER_ENABLED

# Build the sidecar
cd sidecars/go-tokenizer && go build -o tokenizer
```

The system falls back to heuristic token counting if the sidecar fails (circuit breaker activates after 3 failures).

### Python sidecar "module not found"

**Cause**: Missing Python dependencies.

**Fix**:
```bash
pip3 install sentence-transformers
export OSA_PYTHON_PATH=$(which python3)
```

---

## Performance Issues

### Slow responses

**Possible causes**:
1. Large context (check `/usage`)
2. Complex model (Opus when Haiku would suffice)
3. Many hooks running

**Fix**:
```bash
# Check what's happening
/usage
/hooks

# Use a faster model for simple tasks
/think fast

# Compact context
/compact
```

### High token usage

**Fix**:
```bash
# Check budget
/budget

# Lower per-call limit
export OSA_PER_CALL_LIMIT_USD=2.0

# Use a cheaper model
/model groq
```

---

## Build Issues

### "OSA_SKIP_NIF" errors

**Cause**: Rust NIF compilation failing.

**Fix**:
```bash
# Skip NIF compilation (uses Elixir fallback)
export OSA_SKIP_NIF=true
mix compile
```

### Missing dependencies

```bash
mix deps.get
mix deps.compile
```

---

## Getting Help

```
/help              # List all commands
/doctor            # Run diagnostics
/status            # System status
/config            # Show configuration
```

If issues persist, check:
1. `~/.osa/` directory exists and is writable
2. `.env` file has correct API keys
3. No port conflicts on 8089
4. Ollama is running (if using local models)
