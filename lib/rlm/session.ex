defmodule RLM.Session do
  @moduledoc "Multi-turn session API for RLM."

  defstruct [:history, :bindings, :model, :config, :depth]

  @type t :: %__MODULE__{
          history: [map()],
          bindings: keyword(),
          model: String.t(),
          config: RLM.Config.t(),
          depth: non_neg_integer()
        }

  @spec start(String.t(), keyword()) :: t()
  def start(context, opts \\ []) do
    config = Keyword.get_lazy(opts, :config, fn -> RLM.Config.load() end)
    model = Keyword.get(opts, :model, config.model_large)
    depth = Keyword.get(opts, :depth, 0)

    lm_query_fn = RLM.Loop.build_lm_query(config, depth)

    bindings = [
      context: context,
      lm_query: lm_query_fn,
      final_answer: nil,
      last_stdout: "",
      last_stderr: "",
      last_result: nil
    ]

    history = [%{role: :system, content: RLM.Prompt.system_prompt()}]

    %__MODULE__{
      history: history,
      bindings: bindings,
      model: model,
      config: config,
      depth: depth
    }
  end

  @spec ask(t(), String.t()) :: {{:ok, String.t()} | {:error, String.t()}, t()}
  def ask(%__MODULE__{} = session, query) do
    history = session.history
    bindings = session.bindings

    user_message =
      if length(history) == 1 do
        context = Keyword.fetch!(bindings, :context)
        RLM.Prompt.initial_user_message(context, query)
      else
        RLM.Prompt.followup_user_message(query)
      end

    history = history ++ [%{role: :user, content: user_message}]
    bindings = Keyword.put(bindings, :final_answer, nil)

    {result, new_history, new_bindings} =
      RLM.Loop.run_turn(history, bindings, session.model, session.config, session.depth)

    new_session = %__MODULE__{session | history: new_history, bindings: new_bindings}
    {result, new_session}
  end
end
