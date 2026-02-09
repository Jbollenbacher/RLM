defmodule Mix.Tasks.Rlm do
  use Mix.Task

  @shortdoc "Run an RLM query"

  @spec run([String.t()]) :: :ok | no_return()
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [file: :string, interactive: :boolean, verbose: :boolean, debug: :boolean],
        aliases: [i: :interactive]
      )

    configure_logger(opts)
    query = Enum.join(positional, " ")

    context =
      case Keyword.get(opts, :file) do
        nil ->
          read_stdin()

        path ->
          File.read!(path)
      end

    interactive? =
      Keyword.get(opts, :interactive, false) or
        (query == "" and Keyword.get(opts, :file) == nil and context == "")

    cond do
      interactive? ->
        IO.puts(:stderr, "RLM session ready (#{byte_size(context)} bytes). Type your query.")
        session = RLM.Session.start(context)

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
        Mix.raise("Usage: mix rlm [--file FILE] [--interactive] \"query\"")

      true ->
        IO.puts(:stderr, "Running RLM on #{byte_size(context)} bytes...")

        case RLM.run(context, query) do
          {:ok, answer} ->
            IO.puts(answer)

          {:error, reason} ->
            IO.puts(:stderr, "Error: #{reason}")
            System.halt(1)
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

  defp configure_logger(opts) do
    cond do
      Keyword.get(opts, :debug, false) -> Logger.configure(level: :debug)
      Keyword.get(opts, :verbose, false) -> Logger.configure(level: :info)
      true -> Logger.configure(level: :warning)
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
