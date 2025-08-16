defmodule Avalon.Registry do
  @moduledoc """
  Registry for managing game processes.
  """

  def start_link(opts) do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end
end
