# Python Command Guide

This document explains how Python commands are used in this project and how to resolve common issues.

## Python Command Naming

This project uses `python3` as the standard command to run Python. This is to ensure compatibility with systems where both Python 2 and Python 3 are installed.

## Required Python Version

This project requires **Python 3.10 or higher**. Older versions may not support all the features used in the codebase.

## Common Issues and Solutions

### "python: command not found" or "python3: command not found"

If you encounter errors like these when running scripts:

```
python: command not found
```

or

```
python3: command not found
```

Here are solutions based on your operating system:

#### Linux

1. **Check if Python is installed:**
   ```bash
   which python
   which python3
   ```

2. **Install Python 3 if not present:**
   - Ubuntu/Debian: `sudo apt-get install python3 python3-pip`
   - Fedora: `sudo dnf install python3 python3-pip`
   - Arch Linux: `sudo pacman -S python python-pip`

3. **Create a symlink if needed:**
   ```bash
   sudo ln -s /usr/bin/python3 /usr/bin/python
   ```

#### macOS

1. **Using Homebrew:**
   ```bash
   brew install python
   ```

2. **Using symlink:**
   ```bash
   ln -s /usr/local/bin/python3 /usr/local/bin/python
   ```

#### Windows

1. **Ensure Python is in PATH:**
   - During installation, make sure to check "Add Python to PATH"
   - Or add it manually: Settings → System → About → Advanced system settings → Environment Variables

2. **Use the Python Launcher:**
   - Use `py -3` instead of `python` or `python3`

### Virtual Environment Issues

When working with virtual environments:

1. **Always activate the environment before running commands:**
   ```bash
   # Linux/macOS
   source venv/bin/activate
   
   # Windows
   venv\Scripts\activate
   ```

2. **Within an activated environment, you can use `python` instead of `python3`** as the virtual environment handles the correct version.

## Project-Specific Scripts

For this project:

1. **Setup script:** Expects `python3` command to be available
2. **Archive script:** Will try multiple Python commands (`python`, `python3`, etc.)
3. **README examples:** Use `python3` in examples for consistency

## Creating Aliases

If you prefer using `python` instead of `python3`, you can create an alias:

```bash
# Add to ~/.bashrc or ~/.zshrc
alias python=python3
```

Then reload your shell:
```bash
source ~/.bashrc  # or source ~/.zshrc
```

## Conclusion

If you encounter any Python command issues while working with this project, please make sure:

1. Python 3.10+ is installed on your system
2. The proper command (`python3`) is available in your PATH
3. Your virtual environment is activated when running commands
4. Dependencies are installed (`pip3 install -r requirements.txt`)

For further assistance, consult the project maintainers. 