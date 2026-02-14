defmodule RLM.Observability.Supervisor do
  use Supervisor

  @default_port 4005

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    serve = Keyword.get(opts, :serve, true)
    store_opts = Keyword.get(opts, :store_opts, [])
    chat_opts = Keyword.get(opts, :chat_opts)

    children =
      [
        {RLM.Observability.Store, store_opts},
        {RLM.Observability.AgentWatcher, []}
      ] ++
        maybe_chat_child(chat_opts, serve) ++
        maybe_http_child(serve, port, ip)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_chat_child(_chat_opts, false), do: []
  defp maybe_chat_child(nil, _serve), do: []
  defp maybe_chat_child(opts, true), do: [{RLM.Observability.Chat, opts}]

  defp maybe_http_child(false, _port, _ip), do: []

  defp maybe_http_child(true, port, ip),
    do: [{Bandit, plug: RLM.Observability.Router, scheme: :http, port: port, ip: ip}]
end
