import re
import sys
import os

def fix_web_app():
    """Fix indentation issues in web_app.py"""
    
    # First, ensure imports are at the top
    with open('src/web_app.py', 'r') as f:
        content = f.read()
    
    # Fix the create_app function indentation
    pattern = r'(\s+)return app\n(\s+)except Exception as e:'
    replacement = r'        return app\n    except Exception as e:'
    
    # Apply the replacement
    fixed_content = re.sub(pattern, replacement, content)
    
    # Write the fixed content back to the file
    with open('src/web_app.py', 'w') as f:
        f.write(fixed_content)
    
    print("Fixed indentation in web_app.py")

def fix_scraper():
    """Fix critical indentation issues in scraper.py"""
    
    with open('src/scraper.py', 'r') as f:
        lines = f.readlines()
    
    # Specific fixes for known issues
    fixes = {
        # Fix for _log_final_statistics method
        1328: "                self.logger.info(f\"{k}: {v}\")\n",
        
        # Fix for database close in run method
        1462: "                    await self.db_manager.close()\n"
    }
    
    # Apply the fixes
    for line_num, replacement in fixes.items():
        if 0 <= line_num - 1 < len(lines):
            lines[line_num - 1] = replacement
    
    # Write the fixed content back to the file
    with open('src/scraper.py', 'w') as f:
        f.writelines(lines)
    
    print("Fixed critical indentation issues in scraper.py")

if __name__ == "__main__":
    # Make sure we're in the right directory
    if not os.path.exists('src/web_app.py') or not os.path.exists('src/scraper.py'):
        print("Error: Cannot find source files. Make sure you're running this from the project root.")
        sys.exit(1)
    
    # Fix the files
    fix_web_app()
    fix_scraper()
    
    print("Done fixing indentation issues. Please check the files for any remaining issues.") 