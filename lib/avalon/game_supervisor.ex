defmodule Avalon.GameSupervisor do
  @moduledoc """
  DynamicSupervisor for managing game processes.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_game(game_id) do
    DynamicSupervisor.start_child(__MODULE__, {Avalon.Game, game_id})
  end

  def stop_game(game_id) do
    case Registry.lookup(Avalon.Registry, game_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
