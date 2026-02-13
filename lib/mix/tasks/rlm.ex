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
          web: :boolean,
          web_port: :integer
        ],
        aliases: [w: :workspace, i: :interactive]
      )

    configure_logger(opts)
    query = Enum.join(positional, " ")

    workspace_root = Keyword.get(opts, :workspace)
    validate_workspace_root(workspace_root)
    workspace_read_only = Keyword.get(opts, :read_only, false)
    validate_read_only(workspace_root, workspace_read_only)

    context = read_stdin()
    web? = Keyword.get(opts, :web, false)

    if web? do
      run_web_mode(opts, query, context, workspace_root, workspace_read_only)
    else
      interactive? =
        Keyword.get(opts, :interactive, false) or workspace_root != nil or
          (query == "" and context == "")

      cond do
        interactive? ->
          IO.puts(:stderr, "RLM session ready (#{byte_size(context)} bytes). Type your query.")

          session = start_session(context, workspace_root, workspace_read_only)

          session =
            if query != "" do
              ask_and_print(session, query, interactive: true)
            else
              session
            end

          interactive_loop(session)

        query == "" ->
          Mix.raise("Usage: mix rlm [--workspace PATH] [--read-only] [-i] [--web] \"query\"")

        true ->
          IO.puts(:stderr, "Running RLM on #{byte_size(context)} bytes...")

          context
          |> start_session(workspace_root, workspace_read_only)
          |> ask_and_print(query, interactive: false)

          :ok
      end
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

  defp run_web_mode(opts, query, context, workspace_root, workspace_read_only) do
    if query != "" do
      IO.puts(:stderr, "Ignoring positional query in --web mode. Use the web chat panel.")
    end

    port = Keyword.get(opts, :web_port) || env_port("RLM_WEB_PORT") || 4005

    :ok =
      RLM.Observability.start(
        port: port,
        chat_opts: [
          context: context,
          workspace_root: workspace_root,
          workspace_read_only: workspace_read_only
        ]
      )

    IO.puts(:stderr, "Web UI: http://127.0.0.1:#{port}")
    wait_forever()
  end

  defp env_port(name) do
    case System.get_env(name) do
      nil -> nil
      value -> String.to_integer(value)
    end
  end

  defp wait_forever do
    receive do
      _ -> wait_forever()
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
          session = ask_and_print(session, query, interactive: true)
          interactive_loop(session)
        end
    end
  end

  defp start_session(context, workspace_root, workspace_read_only) do
    RLM.Session.start(context,
      workspace_root: workspace_root,
      workspace_read_only: workspace_read_only
    )
  end

  defp ask_and_print(session, query, opts) do
    {result, next_session} = RLM.Session.ask(session, query)
    print_result(result, opts)
    next_session
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
