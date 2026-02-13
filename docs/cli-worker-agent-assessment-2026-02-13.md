# CLI Worker-Agent Assessment (2026-02-13)

Status: research snapshot to support a future migration from custom in-process workers to external coding-agent CLIs.

## Scope

- Candidate worker runtimes:
  - Claude Code
  - Codex CLI
  - OpenCode
  - Kilo
- Decision drivers:
  - Headless automation viability
  - Safety/permission controls (especially command execution boundaries)
  - OpenRouter and vLLM backend compatibility
  - Operational friction and likely integration complexity

## Executive Summary

- All four are technically viable as worker engines.
- Best explicit permission-policy ergonomics: OpenCode/Kilo (single `permission` DSL with `allow|ask|deny`, per-tool/per-pattern overrides, per-agent overrides).
- Best documented OS-level sandboxing and enterprise policy controls: Codex and Claude Code.
- Claude Code remains viable for us (and preferred by familiarity), but headless usability depends on preconfigured permission policy and sandbox defaults; otherwise it can hit frequent approval walls.
- Codex is viable with custom providers, but custom-provider compatibility is shifting to Responses API; gateways/backends must support that path.

## Backend Compatibility (OpenRouter / vLLM)

### Claude Code

Confirmed:
- OpenRouter publishes a Claude Code integration path via `ANTHROPIC_BASE_URL=https://openrouter.ai/api` and `ANTHROPIC_AUTH_TOKEN`, with explicit note to blank `ANTHROPIC_API_KEY`.
- vLLM publishes a Claude Code integration path by pointing `ANTHROPIC_BASE_URL` at a vLLM server implementing Anthropic Messages compatibility.

Important caveat:
- OpenRouter states Claude Code compatibility is only guaranteed with Anthropic 1P provider routing.

Assessment:
- Strong path for both OpenRouter and vLLM, with documented setup recipes.

### Codex CLI

Confirmed:
- Custom providers are supported via `model_providers.<id>` (`base_url`, `env_key`, `wire_api`).
- `wire_api` supports `chat | responses` in docs.
- Official Codex discussion indicates `chat/completions` deprecation and migration pressure toward `responses`.

Assessment:
- OpenRouter/vLLM are possible through OpenAI-compatible provider endpoints, but reliability depends on Responses compatibility of the gateway/backend.
- Migration risk is medium if infra still depends on chat/completions semantics.

### OpenCode

Confirmed:
- Native OpenRouter provider support.
- Custom providers support any OpenAI-compatible endpoint through `provider` config (`npm: @ai-sdk/openai-compatible`, `options.baseURL`, etc.).

Assessment:
- Very flexible for gateway and self-hosted backends (including vLLM-style OpenAI-compatible endpoints).

### Kilo

Confirmed:
- Native OpenRouter provider docs.
- OpenAI-compatible provider mode with configurable Base URL/API key/model ID, including full endpoint URL support.

Assessment:
- Also flexible for OpenRouter and vLLM-style deployments.

## Safety and Permission Systems

### Claude Code

Controls:
- Permission rules in settings (`allow`, `ask`, `deny`, `defaultMode`, `disableBypassPermissionsMode`, `additionalDirectories`).
- CLI headless controls include `--permission-mode`, `--allowedTools`, `--permission-prompt-tool`, and tool restriction flags.
- Separate sandboxing system with filesystem/network constraints and domain controls for bash sandbox.
- Managed settings/policy options for enterprise control and precedence.

Barriers:
- In headless mode, unresolved approvals require policy preconfiguration or a permission-prompt integration.
- Bash matching is pattern-based (prefix/wildcard style), so command-shape control may need careful tuning.
- Some common tools/flows (tests, package manager networking, docker/watchman) may need explicit sandbox and policy adjustments.

Assessment:
- Strong but can feel brittle until baseline policy is tuned.

### Codex CLI

Controls:
- Approval policy (`untrusted | on-failure | on-request | never`).
- Sandbox modes (`read-only`, `workspace-write`, `danger-full-access`) and `--full-auto` preset.
- Documented OS-level sandbox model and enterprise requirements/managed config layers.
- Non-interactive mode supports JSON events and CI-friendly execution.

Barriers:
- Policy model is robust but less explicit as a single command-pattern DSL than OpenCode/Kilo.
- Requires careful environment/profile defaults to avoid either over-restriction or over-autonomy.

Assessment:
- Strong guardrails and enterprise posture; practical defaulting is straightforward once profile is set.

### OpenCode

Controls:
- Unified `permission` config.
- Global defaults and per-tool/per-pattern rules (`allow|ask|deny`), wildcard matching, path-level controls.
- `external_directory` and `doom_loop` guards.
- Per-agent permission overrides.

Barriers:
- Defaults are permissive unless explicitly hardened.

Assessment:
- Easiest model for a central "sane default policy" file; good fit for rapid iteration.

### Kilo

Controls:
- Similar unified permission model to OpenCode in CLI docs.
- Global/per-tool/per-pattern rules and per-agent overrides.
- Interactive command-approval flow can persist command patterns to `execute.allowed`.

Barriers:
- Also starts permissive unless hardened.

Assessment:
- Good policy ergonomics once defaults are hardened.

## Headless / Automation Fit

### Claude Code

Strengths:
- `claude -p` non-interactive mode.
- Machine-readable output (`json`, `stream-json`).
- Programmatic approval handling path (`--permission-prompt-tool`) and SDK callback patterns.

Risk:
- Approval orchestration complexity is higher if we need fully unattended yet bounded runs.

### Codex CLI

Strengths:
- `codex exec` purpose-built for automation.
- JSONL event stream in non-interactive mode.
- Explicit sandbox + approval combinations and CI guidance.

Risk:
- Provider compatibility for non-OpenAI backends needs careful Responses-path verification.

### OpenCode / Kilo

Strengths:
- Permission model is very configurable and explicit.
- Good for centrally managed command/path/domain boundaries.

Risk:
- Need to verify production-grade non-interactive behavior and observability shape against our requirements (resume semantics, event guarantees, failure states).

## Preliminary Recommendation (For Future Revisit)

- If familiarity-weighted and immediate backend flexibility matter most: Claude Code remains a strong candidate.
- If policy simplicity and explicit allow/ask/deny defaults are top priority: OpenCode (or Kilo) may be easier to operate.
- If enterprise sandbox/governance posture is the primary requirement: Codex or Claude Code are strongest on paper.

## Open Questions to Resolve Before Final Selection

1. Claude Code policy confidence:
   - Validate a hardened headless profile for our exact routine operations (tests, docs fetch, directory creation, package tasks) with minimal prompts.
2. Codex custom-provider stability:
   - Confirm OpenRouter and vLLM responses-path behavior under real multi-turn tool use and failure modes.
3. OpenCode/Kilo production fit:
   - Verify non-interactive reliability under high concurrency and long-running runs.
4. Uniform observability:
   - Confirm each CLI exposes enough structured events to map into our agent tree timeline and postmortem export format.
5. Enforcement correctness:
   - Run adversarial checks against allowed/denied command patterns and path restrictions for whichever runtime we shortlist.

## Suggested Next Evaluation Harness (when resumed)

- Build a common benchmark harness that runs identical tasks across all shortlisted CLIs:
  - read-only analysis task
  - edit + test task
  - tool-heavy task (network + filesystem)
  - delegated subagent task
- For each run, record:
  - success/failure
  - wall time
  - approval interrupts
  - policy violations blocked
  - event-log completeness
  - final output quality

## Sources

- Claude Code CLI reference:
  - https://code.claude.com/docs/en/cli-reference
- Claude Code settings:
  - https://code.claude.com/docs/en/settings
- Claude Code sandboxing:
  - https://code.claude.com/docs/en/sandboxing
- Claude Agent SDK (user approvals/input):
  - https://platform.claude.com/docs/en/agent-sdk/user-input
- Codex security:
  - https://developers.openai.com/codex/security
- Codex config reference:
  - https://developers.openai.com/codex/config-reference
- Codex CLI options:
  - https://developers.openai.com/codex/cli/reference
- Codex non-interactive mode:
  - https://developers.openai.com/codex/noninteractive
- Codex chat/completions deprecation discussion:
  - https://github.com/openai/codex/discussions/7782
- OpenCode permissions:
  - https://opencode.ai/docs/permissions/
- OpenCode providers:
  - https://opencode.ai/docs/providers/
- Kilo CLI:
  - https://kilo.ai/docs/code-with-ai/platforms/cli
- Kilo OpenRouter provider:
  - https://kilo.ai/docs/ai-providers/openrouter
- Kilo OpenAI-compatible providers:
  - https://kilo.ai/docs/ai-providers/openai-compatible
- OpenRouter Claude Code integration:
  - https://openrouter.ai/docs/guides/guides/claude-code-integration
- OpenRouter Responses API overview:
  - https://openrouter.ai/docs/api-reference/responses-api/overview
- vLLM Claude Code integration:
  - https://docs.vllm.ai/en/latest/serving/integrations/claude_code/
- vLLM OpenAI-compatible server:
  - https://docs.vllm.ai/en/latest/serving/openai_compatible_server/
