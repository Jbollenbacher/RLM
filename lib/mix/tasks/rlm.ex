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
          single_turn: :boolean,
          export_logs: :boolean,
          export_logs_path: :string,
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
    export_logs_path = resolve_export_logs_path(opts)

    context = read_stdin()
    web? = Keyword.get(opts, :web, false)

    if web? do
      if export_logs_path do
        Mix.raise("--export-logs cannot be used with --web mode")
      end

      run_web_mode(opts, query, context, workspace_root, workspace_read_only)
    else
      interactive? =
        not Keyword.get(opts, :single_turn, false) and
          is_nil(export_logs_path) and
          (Keyword.get(opts, :interactive, false) or workspace_root != nil or
             (query == "" and context == ""))

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

          maybe_enable_headless_observability(export_logs_path)

          result =
            RLM.run(context, query,
              workspace_root: workspace_root,
              workspace_read_only: workspace_read_only
            )

          exit_code = print_single_turn_result(result)
          maybe_export_logs(export_logs_path)

          if exit_code != 0 do
            System.halt(exit_code)
          end

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

  defp resolve_export_logs_path(opts) do
    path = Keyword.get(opts, :export_logs_path)
    enabled? = Keyword.get(opts, :export_logs, false)

    cond do
      is_binary(path) and String.trim(path) != "" ->
        path

      enabled? ->
        RLM.Helpers.timestamped_filename("rlm_agent_logs")

      true ->
        nil
    end
  end

  defp maybe_enable_headless_observability(nil), do: :ok

  defp maybe_enable_headless_observability(_path) do
    case RLM.Observability.start(serve: false) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("Failed to start observability for export: #{inspect(reason)}")
    end
  end

  defp maybe_export_logs(nil), do: :ok

  defp maybe_export_logs(path) do
    target = normalize_export_path(path)
    File.mkdir_p!(Path.dirname(target))

    export = RLM.Observability.Export.full_agent_logs(include_system: true, debug: false)
    File.write!(target, Jason.encode!(export, pretty: true))

    IO.puts(:stderr, "Saved agent logs to #{target}")
  end

  defp normalize_export_path(path) do
    expanded = Path.expand(path)

    cond do
      File.dir?(expanded) ->
        Path.join(expanded, RLM.Helpers.timestamped_filename("rlm_agent_logs"))

      String.ends_with?(path, "/") ->
        Path.join(expanded, RLM.Helpers.timestamped_filename("rlm_agent_logs"))

      true ->
        expanded
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

  defp print_single_turn_result({:ok, answer}) do
    IO.puts(answer)
    0
  end

  defp print_single_turn_result({:error, reason}) do
    IO.puts(:stderr, "Error: #{reason}")
    1
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
