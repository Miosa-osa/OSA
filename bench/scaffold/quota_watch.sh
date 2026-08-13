#!/usr/bin/env bash
# Poll the provider until the session cap lifts. Exits 0 when a real
# completion comes back, 1 if still capped after the deadline.
deadline=$(( $(date +%s) + ${1:-3000} ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  out=$(timeout 90 curl -s -X POST http://localhost:11434/api/chat \
        -d '{"model":"glm-5.2:cloud","messages":[{"role":"user","content":"ok"}],"stream":false}' 2>&1)
  if ! printf '%s' "$out" | grep -q "session usage limit"; then
    echo "QUOTA_RESTORED at $(date -Is)"; printf '%s\n' "$out" | head -c 300; exit 0
  fi
  echo "still capped $(date +%H:%M:%S)"
  sleep 240
done
echo "STILL_CAPPED after deadline"; exit 1
