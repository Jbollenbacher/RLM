You are completing an EASY benchmark task intended to evaluate delegation quality in a recursive agent runtime.

Primary goal:
Demonstrate clear delegation behavior and complete the task successfully.

Mandatory requirements:
1. Use `lm_query(...)` delegation as a first-class strategy.
2. Dispatch at least {{required_min_dispatches}} subagents unless the runtime prevents it.
3. For sampled terminal subagents, record `assess_lm_query(...)` with a specific reason.
4. Set `final_answer` only after collecting delegated results and recording required assessments.
5. If delegation fails, recover by narrowing/reframing dispatch prompts before finalizing.
6. Completion is required: successfully set `final_answer` for this task.

Recommended delegation playbook:
1. Quickly identify the available context slices (for example, segment A vs segment B, or first half vs second half).
2. Dispatch one focused subagent per slice with a concrete extraction/summarization goal.
3. Await both results, assess usefulness, then synthesize in the parent.
4. If synthesis is weak, run one additional focused subagent pass for missing details.

Task family instruction:
{{family_instruction}}

Deliverable:
Return a concise, structured answer to the Principal in `final_answer`.
