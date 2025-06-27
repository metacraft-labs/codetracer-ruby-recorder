# Ruby Debugging Setup for VS Code

This repository includes a comprehensive Ruby debugging setup for Visual Studio Code, similar to the one in the agents-workflow repository.

## Files Created

### VS Code Configuration (`.vscode/`)

- **`tasks.json`** - VS Code tasks for running and debugging Ruby code
- **`launch.json`** - Debug configurations for rdbg debugger
- **`settings.json`** - Ruby LSP settings and debugging preferences

### Scripts

- **`scripts/rdbg-wrapper`** - Wrapper script to locate and run rdbg without hardcoded paths

## Available Tasks

Use `Cmd+Shift+P` (macOS) or `Ctrl+Shift+P` (Windows/Linux) and search for "Tasks: Run Task":

1. **Run Current Test File** - Execute the currently open test file
2. **Run All Tests** - Execute all tests using the main test runner
3. **Debug Current Test with Pry** - Run current test with Pry for interactive debugging
4. **Simple Test Run (No Debug)** - Basic test execution without debug features

## Debug Configurations

Use the Debug panel (F5 or Run → Start Debugging):

1. **Debug Current Ruby File** - Debug any Ruby file with rdbg
2. **Debug Current Test File** - Debug test files with proper load paths
3. **Debug All Tests** - Debug the complete test suite

## Required Gems

To use the debugging features, install these gems:

```bash
gem install debug pry
```

### For Nix Users

If you're using the nix development environment and encounter compilation issues:

1. Use system Ruby for gem installation:

   ```bash
   # Exit nix shell first
   gem install debug pry
   ```

2. Or install globally and ensure they're available in PATH

## Usage

1. **Setting Breakpoints**: Click in the gutter next to line numbers or use `F9`
2. **Interactive Debugging**: Use the "Debug Current Test with Pry" task for REPL-style debugging
3. **Variable Inspection**: Hover over variables or use the Variables panel during debugging
4. **Step Through Code**: Use F10 (step over), F11 (step into), Shift+F11 (step out)

## Ruby LSP Features

The setup includes full Ruby Language Server Protocol support:

- Code completion and IntelliSense
- Go to definition/implementation
- Syntax highlighting and error detection
- Code formatting and refactoring
- Document symbols and workspace search

## Troubleshooting

- **"debug gem not found"**: Install the debug gem with `gem install debug`
- **Compilation errors in nix**: Try using system Ruby for gem installation
- **rdbg not found**: The rdbg-wrapper script should handle this automatically
- **Breakpoints not working**: Ensure the debug gem is installed and accessible

## Integration with Editor

The configuration integrates seamlessly with VS Code's built-in features:

- Debug console for evaluating expressions
- Call stack navigation
- Automatic variable inspection
- Terminal integration for task execution
