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
    store_opts = Keyword.get(opts, :store_opts, [])
    chat_opts = Keyword.get(opts, :chat_opts)

    children =
      [
        {RLM.Observability.Store, store_opts}
      ] ++
        maybe_chat_child(chat_opts) ++
        [
          {Bandit, plug: RLM.Observability.Router, scheme: :http, port: port, ip: ip}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_chat_child(nil), do: []
  defp maybe_chat_child(opts), do: [{RLM.Observability.Chat, opts}]
end
