defmodule RLM.Survey do
  @moduledoc false

  @dispatch_quality_id "dispatch_quality"
  @subagent_usefulness_id "subagent_usefulness"

  @type verdict :: :satisfied | :dissatisfied

  @type t :: %{
          id: String.t(),
          scope: atom(),
          question: String.t(),
          required: boolean(),
          response_schema: term(),
          response: term(),
          status: :pending | :answered | :missing,
          requested_at: integer() | nil,
          answered_at: integer() | nil,
          metadata: map()
        }

  @type state :: %{optional(String.t()) => t()}

  @spec dispatch_quality_id() :: String.t()
  def dispatch_quality_id, do: @dispatch_quality_id

  @spec subagent_usefulness_id() :: String.t()
  def subagent_usefulness_id, do: @subagent_usefulness_id

  @spec parse_verdict(term()) :: {:ok, verdict()} | :error
  def parse_verdict(value) when value in [:satisfied, :dissatisfied], do: {:ok, value}

  def parse_verdict(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "satisfied" -> {:ok, :satisfied}
      "dissatisfied" -> {:ok, :dissatisfied}
      _ -> :error
    end
  end

  def parse_verdict(_), do: :error

  @spec init_state() :: state()
  def init_state, do: %{}

  @spec ensure_dispatch_quality(state(), boolean()) :: state()
  def ensure_dispatch_quality(state, required) when is_boolean(required) do
    {state, _survey} =
      ensure_survey(state, %{
        id: @dispatch_quality_id,
        scope: :agent,
        question: "Rate dispatch quality",
        required: required,
        response_schema: :verdict
      })

    state
  end

  @spec ensure_subagent_usefulness(state(), boolean()) :: state()
  def ensure_subagent_usefulness(state, required) when is_boolean(required) do
    {state, _survey} =
      ensure_survey(state, %{
        id: @subagent_usefulness_id,
        scope: :child,
        question: "Rate subagent usefulness",
        required: required,
        response_schema: :verdict
      })

    state
  end

  @spec ensure_survey(state(), map()) :: {state(), t()}
  def ensure_survey(state, attrs) when is_map(state) and is_map(attrs) do
    id = attrs |> Map.get(:id) |> to_string()
    now = System.system_time(:millisecond)
    existing = Map.get(state, id)
    merged = build_survey(existing, id, attrs, now)
    {Map.put(state, id, merged), merged}
  end

  @spec answer(state(), String.t(), term(), String.t()) ::
          {:ok, state(), t()} | {:error, String.t()}
  def answer(state, survey_id, response, reason \\ "")
      when is_map(state) and is_binary(survey_id) and is_binary(reason) do
    now = System.system_time(:millisecond)
    default = build_survey(nil, survey_id, %{id: survey_id}, now)
    survey = Map.get(state, survey_id, default)

    with {:ok, normalized_response} <-
           validate_response(response, Map.get(survey, :response_schema)) do
      answered =
        survey
        |> Map.put(:status, :answered)
        |> Map.put(:response, normalized_response)
        |> Map.put(:answered_at, now)
        |> put_reason(reason)

      {:ok, Map.put(state, survey_id, answered), answered}
    end
  end

  @spec merge_answers(state(), map()) :: state()
  def merge_answers(state, answers) when is_map(state) and is_map(answers) do
    Enum.reduce(answers, state, fn {raw_id, value}, acc ->
      survey_id = to_string(raw_id)
      response = Map.get(value, :response, Map.get(value, "response"))
      reason = value |> Map.get(:reason, Map.get(value, "reason", "")) |> to_string()

      case answer(acc, survey_id, response, reason) do
        {:ok, updated, _survey} -> updated
        {:error, _reason} -> acc
      end
    end)
  end

  @spec mark_missing(state(), String.t()) :: state()
  def mark_missing(state, survey_id) when is_map(state) and is_binary(survey_id) do
    case Map.get(state, survey_id) do
      nil ->
        state

      survey ->
        Map.put(state, survey_id, %{survey | status: :missing})
    end
  end

  @spec clear_response(state(), String.t()) :: state()
  def clear_response(state, survey_id) when is_map(state) and is_binary(survey_id) do
    case Map.get(state, survey_id) do
      nil ->
        state

      survey ->
        metadata =
          survey
          |> Map.get(:metadata, %{})
          |> Map.delete(:reason)

        Map.put(state, survey_id, %{
          survey
          | status: :pending,
            response: nil,
            answered_at: nil,
            metadata: metadata
        })
    end
  end

  @spec pending_required(state()) :: [t()]
  def pending_required(state) when is_map(state) do
    state
    |> Map.values()
    |> Enum.filter(fn survey ->
      Map.get(survey, :required, false) and Map.get(survey, :status) != :answered
    end)
    |> Enum.sort_by(&Map.get(&1, :id, ""))
  end

  @spec pending_all(state()) :: [t()]
  def pending_all(state) when is_map(state) do
    state
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, :status) != :answered))
    |> Enum.sort_by(&Map.get(&1, :id, ""))
  end

  @spec answered_all(state()) :: [t()]
  def answered_all(state) when is_map(state) do
    state
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, :status) == :answered))
    |> Enum.sort_by(&Map.get(&1, :id, ""))
  end

  @spec dispatch_assessment(state()) :: map() | nil
  def dispatch_assessment(state) when is_map(state) do
    case Map.get(state, @dispatch_quality_id) do
      %{response: response, metadata: metadata} when is_map(metadata) ->
        case parse_verdict(response) do
          {:ok, verdict} ->
            %{verdict: verdict, reason: to_string(Map.get(metadata, :reason, ""))}

          :error ->
            nil
        end

      _ ->
        nil
    end
  end

  @spec normalize_answers(term()) :: map()
  def normalize_answers(%{} = answers) do
    Enum.into(answers, %{}, fn {id, value} ->
      survey_id = to_string(id)

      normalized =
        case value do
          %{} = map ->
            %{
              response: Map.get(map, "response", Map.get(map, :response)),
              reason: map |> Map.get("reason", Map.get(map, :reason, "")) |> to_string()
            }

          _ ->
            %{response: value, reason: ""}
        end

      {survey_id, normalized}
    end)
  end

  def normalize_answers(_), do: %{}

  defp build_survey(existing, id, attrs, now) do
    base =
      existing ||
        %{
          id: id,
          scope: :agent,
          question: "",
          required: false,
          response_schema: nil,
          response: nil,
          status: :pending,
          requested_at: now,
          answered_at: nil,
          metadata: %{}
        }

    updated =
      base
      |> Map.put(:scope, attrs |> Map.get(:scope, Map.get(base, :scope)) |> normalize_scope())
      |> Map.put(:question, attrs |> Map.get(:question, Map.get(base, :question)) |> to_string())
      |> Map.put(:required, Map.get(attrs, :required, Map.get(base, :required, false)) == true)
      |> Map.put(
        :response_schema,
        Map.get(attrs, :response_schema, Map.get(base, :response_schema))
      )
      |> Map.put(:metadata, merge_metadata(base, attrs))

    status = merged_status(updated, base)
    %{updated | status: status}
  end

  defp merged_status(updated, base) do
    if Map.get(updated, :response) != nil do
      :answered
    else
      Map.get(base, :status, :pending)
    end
  end

  defp merge_metadata(base, attrs) do
    current = Map.get(base, :metadata, %{})
    incoming = Map.get(attrs, :metadata, %{})

    if is_map(current) and is_map(incoming) do
      Map.merge(current, incoming)
    else
      %{}
    end
  end

  defp put_reason(survey, reason) do
    metadata = Map.get(survey, :metadata, %{})
    Map.put(survey, :metadata, Map.put(metadata, :reason, reason))
  end

  defp validate_response(response, nil), do: {:ok, response}

  defp validate_response(response, :verdict) do
    case parse_verdict(response) do
      {:ok, verdict} -> {:ok, verdict}
      :error -> {:error, "Invalid survey response. Use `satisfied` or `dissatisfied`."}
    end
  end

  defp validate_response(response, _schema), do: {:ok, response}

  defp normalize_scope(scope) when scope in [:agent, :child], do: scope
  defp normalize_scope(_), do: :agent
end
