defmodule Mix.Tasks.Rlm do
  use Mix.Task

  @shortdoc "Run an RLM query"

  @spec run([String.t()]) :: :ok | no_return()
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          workspace: :string,
          read_only: :boolean,
          interactive: :boolean,
          verbose: :boolean,
          debug: :boolean,
          observe: :boolean,
          observe_port: :integer
        ],
        aliases: [w: :workspace, i: :interactive]
      )

    configure_logger(opts)
    maybe_start_observability(opts)
    query = Enum.join(positional, " ")

    workspace_root = Keyword.get(opts, :workspace)
    validate_workspace_root(workspace_root)
    workspace_read_only = Keyword.get(opts, :read_only, false)
    validate_read_only(workspace_root, workspace_read_only)

    context = read_stdin()

    interactive? =
      Keyword.get(opts, :interactive, false) or workspace_root != nil or
        (query == "" and context == "")

    cond do
      interactive? ->
        IO.puts(:stderr, "RLM session ready (#{byte_size(context)} bytes). Type your query.")
        session =
          RLM.Session.start(context,
            workspace_root: workspace_root,
            workspace_read_only: workspace_read_only
          )

        session =
          if query != "" do
            {result, session} = RLM.Session.ask(session, query)
            print_result(result, interactive: true)
            session
          else
            session
          end

        interactive_loop(session)

      query == "" ->
        Mix.raise("Usage: mix rlm [--workspace PATH] [--read-only] [-i] \"query\"")

      true ->
        IO.puts(:stderr, "Running RLM on #{byte_size(context)} bytes...")
        session =
          RLM.Session.start(context,
            workspace_root: workspace_root,
            workspace_read_only: workspace_read_only
          )
        {result, _session} = RLM.Session.ask(session, query)
        print_result(result, interactive: false)
    end
  end

  defp read_stdin do
    task = Task.async(fn -> IO.read(:stdio, 1) end)

    case Task.yield(task, 20) || Task.shutdown(task, :brutal_kill) do
      {:ok, :eof} ->
        ""

      {:ok, data} when is_binary(data) ->
        data <> read_stdin_rest()

      nil ->
        ""
    end
  end

  defp read_stdin_rest do
    case IO.read(:stdio, :eof) do
      :eof -> ""
      data -> data
    end
  end

  defp validate_workspace_root(nil), do: :ok

  defp validate_workspace_root(path) do
    if File.dir?(path) do
      :ok
    else
      Mix.raise("Workspace path is not a directory: #{path}")
    end
  end

  defp validate_read_only(nil, true),
    do: Mix.raise("--read-only requires --workspace PATH")

  defp validate_read_only(_workspace_root, _read_only), do: :ok

  defp configure_logger(opts) do
    cond do
      Keyword.get(opts, :debug, false) -> Logger.configure(level: :debug)
      Keyword.get(opts, :verbose, false) -> Logger.configure(level: :info)
      true -> Logger.configure(level: :warning)
    end
  end

  defp maybe_start_observability(opts) do
    observe_flag = Keyword.get(opts, :observe, false)
    observe_env = System.get_env("RLM_OBSERVE") in ["1", "true", "TRUE"]

    if observe_flag or observe_env do
      port =
        Keyword.get(opts, :observe_port) ||
          case System.get_env("RLM_OBSERVE_PORT") do
            nil -> 4005
            value -> String.to_integer(value)
          end

      :ok = RLM.Observability.start(port: port)
      IO.puts(:stderr, "Observability UI: http://127.0.0.1:#{port}")
    end
  end

  defp interactive_loop(session) do
    IO.write(:stderr, "rlm> ")

    case IO.gets(:stdio, "") do
      nil ->
        :ok

      line ->
        query = String.trim(line)

        if query == "" do
          interactive_loop(session)
        else
          {result, session} = RLM.Session.ask(session, query)
          print_result(result, interactive: true)
          interactive_loop(session)
        end
    end
  end

  defp print_result({:ok, answer}, _opts) do
    IO.puts(answer)
  end

  defp print_result({:error, reason}, opts) do
    IO.puts(:stderr, "Error: #{reason}")

    if Keyword.get(opts, :interactive, false) do
      :ok
    else
      System.halt(1)
    end
  end
end
