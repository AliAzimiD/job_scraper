#!/usr/bin/env python3
"""
Script to fix syntax errors in the scraper.py file
"""
import re
import sys

def fix_scraper_file(filepath):
    print(f"Reading file: {filepath}")
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Fix the try block at line 180
    print("Fixing try block at line ~180")
    pattern1 = r"try:(\s+)self\.logger\.info.*?async with self\.semaphore:"
    replacement1 = r"try:\1self.logger.info\1async with self.semaphore:\1    try:"
    content = re.sub(pattern1, replacement1, content, flags=re.DOTALL)
    
    # Fix other similar issues - incomplete try blocks
    pattern2 = r"try:(\s+)([^\n]+)(\s+)([^\n]+)"
    replacement2 = r"try:\1\2\3    try:\3        \4"
    content = re.sub(pattern2, replacement2, content)
    
    # Fix indentation issues
    lines = content.split('\n')
    fixed_lines = []
    in_try_block = False
    expected_except = False
    
    for i, line in enumerate(lines):
        if "try:" in line and "except" not in line:
            in_try_block = True
            expected_except = True
        elif expected_except and line.strip() and not line.strip().startswith("except") and not line.strip().startswith("finally"):
            # Adjust indentation for lines in try block
            indent = len(line) - len(line.lstrip())
            fixed_lines.append(" " * indent + "try:")
            fixed_lines.append(line)
            expected_except = False
        else:
            fixed_lines.append(line)
            if line.strip().startswith("except") or line.strip().startswith("finally"):
                expected_except = False
    
    fixed_content = '\n'.join(fixed_lines)
    
    # Write the fixed content back
    print(f"Writing fixed content to: {filepath}")
    with open(filepath, 'w') as f:
        f.write(fixed_content)
    
    print("Fix completed")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python fix_scraper.py <filepath>")
        sys.exit(1)
    
    filepath = sys.argv[1]
    success = fix_scraper_file(filepath)
    sys.exit(0 if success else 1)
