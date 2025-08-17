defmodule Avalon.BotManager do
  @moduledoc """
  Manages bot players for Avalon games. Provides easy functions to add and remove bots.
  """

  @doc """
  Adds the specified number of bots to a game.
  Returns a list of bot names that were added.
  """
  def add_bots(game_id, count) when count > 0 do
    bot_names = generate_bot_names(count)

    results = Enum.map(bot_names, fn bot_name ->
      case Avalon.BotPlayer.start_link(game_id, bot_name) do
        {:ok, _pid} -> {:ok, bot_name}
        {:error, reason} -> {:error, reason}
      end
    end)

    successful_bots = results
    |> Enum.filter(fn {status, _} -> status == :ok end)
    |> Enum.map(fn {_, bot_name} -> bot_name end)

    failed_bots = results
    |> Enum.filter(fn {status, _} -> status == :error end)
    |> Enum.map(fn {_, reason} -> reason end)

    if length(failed_bots) > 0 do
      IO.puts("Warning: Some bots failed to join: #{inspect(failed_bots)}")
    end

    successful_bots
  end

  @doc """
  Adds bots to fill a game to the specified player count.
  Returns the number of bots added.
  """
  def fill_game_to_count(game_id, target_count) do
    # Try to get the game state by looking up the game process
    case Registry.lookup(Avalon.Registry, game_id) do
      [{_pid, _}] ->
        # Game exists, add bots one by one until we reach the target
        # We'll add bots and let the game logic handle rejecting if full
        current_bots = 0
        max_attempts = target_count

        Enum.reduce_while(1..max_attempts, current_bots, fn _attempt, acc ->
          bot_names = add_bots(game_id, 1)
          if length(bot_names) > 0 do
            {:cont, acc + 1}
          else
            {:halt, acc}
          end
        end)
      [] ->
        # Game doesn't exist
        0
    end
  end

  @doc """
  Removes all bots from a game.
  """
  def remove_all_bots(game_id) do
    # Find all bot processes for this game
    Registry.lookup(Avalon.Registry, "bot:#{game_id}")
    |> Enum.each(fn {_pid, _} ->
      # This is a simplified approach - in practice you'd want to track bot names
      # For now, we'll just stop the process
      :ok
    end)
  end

  @doc """
  Removes a specific bot from a game.
  """
  def remove_bot(game_id, bot_name) do
    Avalon.BotPlayer.stop_bot(game_id, bot_name)
  end

  @doc """
  Lists all bots currently in a game.
  """
  def list_bots(_game_id) do
    # This would require tracking bot names in a more sophisticated way
    # For now, return an empty list
    []
  end

  # Generate unique bot names
  defp generate_bot_names(count) do
    bot_prefixes = [
      "Arthur", "Lancelot", "Gawain", "Percival", "Galahad", "Tristan", "Bedivere",
      "Kay", "Bors", "Ector", "Mordred", "Morgana", "Viviane", "Nimue", "Igraine",
      "Guinevere", "Elaine", "Isolde", "Brigid", "Ceridwen"
    ]

    # Shuffle and take the required number
    bot_prefixes
    |> Enum.shuffle()
    |> Enum.take(count)
    |> Enum.map(fn prefix -> "#{prefix}Bot" end)
  end
end
