# Bot System for Avalon

The Avalon game now includes a bot system that allows you to play with AI-controlled players. This makes it much easier to test the game and play with fewer than 5 human players.

## Features

- **Automatic Bot Players**: Bots join games and play automatically
- **Role-Aware Actions**: Bots make decisions based on their assigned roles
- **Natural Delays**: Bots add random delays to make their actions feel more human
- **Easy Management**: Simple interface to add and remove bots

## How to Use

### Quick Start with Bots

1. Go to the home page (http://localhost:4000)
2. Use the "Quick Start with Bots" section
3. Select the number of players you want (5-10)
4. Click "Start Game with Bots"
5. Join the game with your name
6. The bots will automatically fill the remaining slots

### Manual Bot Management

You can also manually add bots to existing games:

1. Create or join a game
2. Use the "Bot Management" section on the home page
3. Enter the game ID and select how many bots to add
4. Or use "Fill Game to Player Count" to automatically fill to a specific number

### Programmatic Usage

You can also add bots programmatically:

```elixir
# Add 3 bots to a game
bot_names = Avalon.BotManager.add_bots("game_id", 3)

# Fill a game to 7 players
bots_added = Avalon.BotManager.fill_game_to_count("game_id", 7)

# Remove a specific bot
Avalon.BotManager.remove_bot("game_id", "ArthurBot")
```

## Bot Behavior

### Team Building
- Bots propose random teams of the correct size
- They include themselves and other random players

### Voting
- Bots vote randomly (approve or reject)
- This creates realistic uncertainty in team approval

### Quest Cards
- **Good players** (including Merlin): Always play success
- **Evil players** (including Assassin): Tend to play fail (2/3 chance) but sometimes play success to blend in

### Assassination
- The Assassin bot targets random good players
- Excludes known evil players from the target list

### Lady of the Lake
- Bots use the Lady of the Lake on random valid targets
- They avoid previously used targets and themselves

## Bot Names

Bots are automatically named using Arthurian legend characters:
- ArthurBot, LancelotBot, GawainBot, PercivalBot, etc.
- Names are randomly selected from a pool of 20 characters

## Technical Details

### Architecture
- Each bot is a separate GenServer process
- Bots subscribe to game updates via Phoenix PubSub
- Bots make decisions based on game state and their role
- All bot actions go through the same game logic as human players

### Safety
- Bots cannot break game rules (they use the same validation as humans)
- Bots automatically handle timeouts and edge cases
- Bot processes are properly managed and cleaned up

## Future Enhancements

The bot system is designed to be easily extensible:

1. **Smarter Strategy**: Replace random decisions with strategic logic
2. **Personality Types**: Different bots could have different playing styles
3. **Learning**: Bots could learn from game outcomes
4. **Difficulty Levels**: Easy, medium, and hard bot difficulties

## Demo

Run the demo script to see the bot system in action:

```bash
elixir demo_bots.exs
```

This will create a game with bots and show you how they interact.
