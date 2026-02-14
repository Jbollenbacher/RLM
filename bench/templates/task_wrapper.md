You are completing a benchmark task intended to evaluate delegation quality in a recursive agent runtime.

Mandatory requirements:
1. Use `lm_query(...)` delegation as a first-class strategy.
2. Dispatch at least {{required_min_dispatches}} subagents unless the runtime prevents it.
3. For sampled terminal subagents, record `assess_lm_query(...)` with a specific reason.
4. Set `final_answer` only after collecting delegated results and recording required assessments.
5. If delegation fails, recover by narrowing/reframing dispatch prompts before finalizing.

Task family instruction:
{{family_instruction}}

Deliverable:
Return a concise, structured answer to the Principal in `final_answer`.
