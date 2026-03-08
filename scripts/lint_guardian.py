#!/usr/bin/env python3
import re
import sys
import ast

def lint_file(filepath):
    print(f"🔍 Linting {filepath}...")
    with open(filepath, "r") as f:
        content = f.read()

    # 1. Extract Python Bot Code
    # Pattern: cat > "$BACKUP_DIR/guardian-bot.py" <<EOF ... EOF
    py_match = re.search(r'cat > "\$BACKUP_DIR/guardian-bot.py" <<EOF\n(.*?)\nEOF', content, re.DOTALL)
    if not py_match:
        print("⚠️ Warning: Could not find guardian-bot.py heredoc.")
    else:
        py_code = py_match.group(1)
        # Handle shell variable interpolation in python code if any (simplified)
        # For linting, we just want to ensure the Python syntax is valid
        # Note: We need to be careful with f-strings and $ signs which are escaped in the shell script
        try:
            ast.parse(py_code)
            print("✅ Python Bot Syntax: OK")
        except SyntaxError as e:
            print(f"❌ Python Bot Syntax Error: {e}")
            print(f"Line {e.lineno}: {e.text}")
            return False

    # 2. Extract Backup Script Code
    # Pattern: cat > "$BACKUP_DIR/backup.sh" <<EOF ... EOF
    sh_match = re.search(r'cat > "\$BACKUP_DIR/backup.sh" <<EOF\n(.*?)\nEOF', content, re.DOTALL)
    if not sh_match:
        print("⚠️ Warning: Could not find backup.sh heredoc.")
    else:
        # Basic check for unclosed quotes or brackets in shell
        sh_code = sh_match.group(1)
        if sh_code.count('"') % 2 != 0:
            print("❌ Shell Script Error: Unbalanced double quotes in backup.sh")
            return False
        print("✅ Backup Script (Basic Check): OK")

    print("🎉 Linting passed!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        file_to_lint = "deploy-guardian.sh"
    else:
        file_to_lint = sys.argv[1]
    
    if not lint_file(file_to_lint):
        sys.exit(1)
