run_integration? = System.get_env("RLM_RUN_INTEGRATION") in ["1", "true", "TRUE"]

ExUnit.start(exclude: if(run_integration?, do: [], else: [:integration]))
