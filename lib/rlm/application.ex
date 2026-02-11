defmodule RLM.Application do
  use Application

  def start(_type, _args) do
    http_pool_size = Application.get_env(:rlm, :http_pool_size, 100)
    http_pool_count = Application.get_env(:rlm, :http_pool_count, 1)

    children = [
      RLM.AgentLimiter,
      {Registry, keys: :unique, name: RLM.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: RLM.SessionSupervisor},
      {Finch, name: RLM.Finch, pools: %{default: [size: http_pool_size, count: http_pool_count]}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RLM.Supervisor)
  end
end
