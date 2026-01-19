#!/usr/bin/env python3
"""
cue-edit.py - Safely add/remove entries in CUE configuration files

This tool provides safe manipulation of CUE files for demo purposes.
It always validates changes with 'cue vet' before writing.

Usage:
  cue-edit.py env-configmap add <file> <env> <app> <key> <value>
  cue-edit.py env-configmap remove <file> <env> <app> <key>
  cue-edit.py app-configmap add <file> <app> <key> <value>
  cue-edit.py app-configmap remove <file> <app> <key>
  cue-edit.py env-field set <file> <env> <app> <field> <value>
  cue-edit.py env-field remove <file> <env> <app> <field>

Examples:
  # Add redis-url to dev environment's ConfigMap
  cue-edit.py env-configmap add env.cue dev exampleApp redis-url "redis://redis.dev:6379"

  # Add cache-ttl to app's default ConfigMap (propagates to all envs)
  cue-edit.py app-configmap add services/apps/example-app.cue exampleApp cache-ttl "300"

  # Set replicas for an app in an environment
  cue-edit.py env-field set env.cue dev exampleApp replicas 2

Note: App names use CUE identifiers (e.g., "exampleApp" not "example-app")
"""

import argparse
import re
import subprocess
import sys
import tempfile
import shutil
from pathlib import Path


def run_cue_vet(file_path: str, project_root: str) -> tuple[bool, str]:
    """Run cue vet on a file and return (success, output)."""
    try:
        result = subprocess.run(
            ["cue", "vet", file_path],
            cwd=project_root,
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.returncode == 0, result.stderr or result.stdout
    except subprocess.TimeoutExpired:
        return False, "CUE validation timed out"
    except FileNotFoundError:
        return False, "CUE command not found - install from https://cuelang.org/docs/install/"


def find_project_root(file_path: str) -> str:
    """Find the project root (directory containing cue.mod or services/)."""
    path = Path(file_path).resolve().parent
    while path != path.parent:
        if (path / "cue.mod").exists() or (path / "services").exists():
            return str(path)
        path = path.parent
    # Fallback to file's directory
    return str(Path(file_path).resolve().parent)


def find_block_end(content: str, start_pos: int) -> int:
    """Find the position of the closing brace that matches the opening brace at start_pos."""
    depth = 0
    in_string = False
    escape_next = False

    for i, char in enumerate(content[start_pos:], start=start_pos):
        if escape_next:
            escape_next = False
            continue
        if char == '\\':
            escape_next = True
            continue
        if char == '"' and not escape_next:
            in_string = not in_string
            continue
        if in_string:
            continue
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return i
    return -1


def add_env_configmap_entry(content: str, env: str, app: str, key: str, value: str) -> str:
    """Add a ConfigMap entry to an environment's app config in env.cue.

    Structure: <env>: <app>: apps.<appRef> & {
        appConfig: {
            ...
            configMap: {
                data: {
                    "key": "value"
                }
            }
        }
    }
    """
    # Pattern to find the app definition within the environment
    # Matches: dev: exampleApp: apps.exampleApp & {
    app_pattern = rf'^({env}:\s*{app}:\s*apps\.\w+\s*&\s*\{{)'
    app_match = re.search(app_pattern, content, re.MULTILINE)

    if not app_match:
        raise ValueError(f"Could not find app '{app}' in environment '{env}'")

    app_start = app_match.end()

    # Find the end of this app block
    app_block_end = find_block_end(content, app_match.start() + content[app_match.start():].index('{'))
    app_block = content[app_start:app_block_end]

    # Look for existing configMap.data block
    data_pattern = r'(configMap:\s*\{\s*data:\s*\{)'
    data_match = re.search(data_pattern, app_block)

    if data_match:
        # Found existing configMap.data block
        insert_pos = app_start + data_match.end()

        # Check if key already exists
        existing_pattern = rf'"{re.escape(key)}":\s*"[^"]*"'
        if re.search(existing_pattern, app_block):
            # Replace existing value
            content = re.sub(
                rf'("{re.escape(key)}":\s*)"[^"]*"',
                rf'\1"{value}"',
                content
            )
            return content

        # Add new entry after the opening brace of data
        new_entry = f'\n\t\t\t\t"{key}": "{value}"'
        return content[:insert_pos] + new_entry + content[insert_pos:]

    # Look for existing configMap block (without data)
    configmap_pattern = r'(configMap:\s*\{)'
    configmap_match = re.search(configmap_pattern, app_block)

    if configmap_match:
        insert_pos = app_start + configmap_match.end()
        new_block = f'\n\t\t\tdata: {{\n\t\t\t\t"{key}": "{value}"\n\t\t\t}}'
        return content[:insert_pos] + new_block + content[insert_pos:]

    # Look for appConfig block
    appconfig_pattern = r'(appConfig:\s*\{)'
    appconfig_match = re.search(appconfig_pattern, app_block)

    if appconfig_match:
        insert_pos = app_start + appconfig_match.end()
        new_block = f'\n\t\tconfigMap: {{\n\t\t\tdata: {{\n\t\t\t\t"{key}": "{value}"\n\t\t\t}}\n\t\t}}'
        return content[:insert_pos] + new_block + content[insert_pos:]

    raise ValueError(f"Could not find appConfig block for app '{app}' in environment '{env}'")


def remove_env_configmap_entry(content: str, env: str, app: str, key: str) -> str:
    """Remove a ConfigMap entry from an environment's app config."""
    # Pattern to match the key-value pair with proper indentation handling
    # Handles both with and without trailing comma, and surrounding whitespace
    pattern = rf'(\n\s*)"{re.escape(key)}":\s*"[^"]*"\s*'

    # Find the app block first to scope the replacement
    app_pattern = rf'^{env}:\s*{app}:\s*apps\.\w+\s*&\s*\{{'
    app_match = re.search(app_pattern, content, re.MULTILINE)

    if not app_match:
        return content  # Nothing to remove if app doesn't exist

    app_start = app_match.start()
    app_block_end = find_block_end(content, app_start + content[app_start:].index('{'))

    # Only remove within this app's block
    before = content[:app_start]
    app_block = content[app_start:app_block_end + 1]
    after = content[app_block_end + 1:]

    # Remove the entry from the app block
    app_block = re.sub(pattern, r'\1', app_block)

    return before + app_block + after


def add_app_configmap_entry(content: str, app: str, key: str, value: str) -> str:
    """Add a ConfigMap entry to an app's default config in services/apps/*.cue.

    Structure: exampleApp: core.#App & {
        appName: "example-app"
        appEnvVars: [...]
        appConfig: {
            configMap: {
                data: {
                    "key": "value"
                }
            }
        }
    }
    """
    # Look for existing configMap.data block
    data_pattern = r'(appConfig:\s*\{[^}]*?configMap:\s*\{[^}]*?data:\s*\{)'
    data_match = re.search(data_pattern, content, re.DOTALL)

    if data_match:
        insert_pos = data_match.end()

        # Check if key already exists
        if re.search(rf'"{re.escape(key)}":\s*"[^"]*"', content[data_match.start():]):
            # Replace existing value
            return re.sub(
                rf'("{re.escape(key)}":\s*)"[^"]*"',
                rf'\1"{value}"',
                content
            )

        new_entry = f'\n\t\t\t"{key}": "{value}"'
        return content[:insert_pos] + new_entry + content[insert_pos:]

    # Look for existing configMap block (without data)
    configmap_pattern = r'(appConfig:\s*\{[^}]*?configMap:\s*\{)'
    configmap_match = re.search(configmap_pattern, content, re.DOTALL)

    if configmap_match:
        insert_pos = configmap_match.end()
        new_block = f'\n\t\tdata: {{\n\t\t\t"{key}": "{value}"\n\t\t}}'
        return content[:insert_pos] + new_block + content[insert_pos:]

    # Look for appConfig block
    appconfig_pattern = r'(appConfig:\s*\{)'
    appconfig_match = re.search(appconfig_pattern, content)

    if appconfig_match:
        insert_pos = appconfig_match.end()
        new_block = f'\n\t\tconfigMap: {{\n\t\t\tdata: {{\n\t\t\t\t"{key}": "{value}"\n\t\t\t}}\n\t\t}}'
        return content[:insert_pos] + new_block + content[insert_pos:]

    raise ValueError("Could not find appConfig block in file")


def remove_app_configmap_entry(content: str, app: str, key: str) -> str:
    """Remove a ConfigMap entry from an app's default config."""
    pattern = rf'(\n\s*)"{re.escape(key)}":\s*"[^"]*"\s*'
    return re.sub(pattern, r'\1', content)


def set_env_field(content: str, env: str, app: str, field: str, value: str) -> str:
    """Set a field value for an app in an environment."""
    # Determine if value should be quoted
    try:
        if '.' in value:
            float(value)
            formatted_value = value
        else:
            int(value)
            formatted_value = value
    except ValueError:
        if value.lower() in ('true', 'false'):
            formatted_value = value.lower()
        else:
            formatted_value = f'"{value}"'

    # Find the app block
    app_pattern = rf'^({env}:\s*{app}:\s*apps\.\w+\s*&\s*\{{)'
    app_match = re.search(app_pattern, content, re.MULTILINE)

    if not app_match:
        raise ValueError(f"Could not find app '{app}' in environment '{env}'")

    app_start = app_match.end()
    app_block_end = find_block_end(content, app_match.start() + content[app_match.start():].index('{'))
    app_block = content[app_start:app_block_end]

    # Look for existing field in appConfig
    field_pattern = rf'(appConfig:\s*\{{[^}}]*?)({field}:\s*)[^\n,}}]+'
    field_match = re.search(field_pattern, app_block, re.DOTALL)

    if field_match:
        # Replace existing field
        new_app_block = (
            app_block[:field_match.start(2)] +
            f'{field}: {formatted_value}' +
            app_block[field_match.end():]
        )
        return content[:app_start] + new_app_block + content[app_block_end:]

    # Field doesn't exist, add it after appConfig: {
    appconfig_pattern = r'(appConfig:\s*\{)'
    appconfig_match = re.search(appconfig_pattern, app_block)

    if appconfig_match:
        insert_pos = app_start + appconfig_match.end()
        new_field = f'\n\t\t{field}: {formatted_value}'
        return content[:insert_pos] + new_field + content[insert_pos:]

    raise ValueError(f"Could not find appConfig block for app '{app}' in environment '{env}'")


def remove_env_field(content: str, env: str, app: str, field: str) -> str:
    """Remove a field from an app's environment config."""
    # Find the app block
    app_pattern = rf'^{env}:\s*{app}:\s*apps\.\w+\s*&\s*\{{'
    app_match = re.search(app_pattern, content, re.MULTILINE)

    if not app_match:
        return content

    app_start = app_match.start()
    app_block_end = find_block_end(content, app_start + content[app_start:].index('{'))

    before = content[:app_start]
    app_block = content[app_start:app_block_end + 1]
    after = content[app_block_end + 1:]

    # Remove the field line
    pattern = rf'\n\s*{field}:\s*[^\n,}}]+,?\s*'
    app_block = re.sub(pattern, '\n', app_block)

    return before + app_block + after


def main():
    parser = argparse.ArgumentParser(
        description='Safely edit CUE configuration files',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    subparsers = parser.add_subparsers(dest='command', help='Command to run')

    # env-configmap subcommand
    env_cm = subparsers.add_parser('env-configmap', help='Modify environment-level ConfigMap entries')
    env_cm_sub = env_cm.add_subparsers(dest='action')

    env_cm_add = env_cm_sub.add_parser('add', help='Add a ConfigMap entry')
    env_cm_add.add_argument('file', help='CUE file to modify')
    env_cm_add.add_argument('env', help='Environment name (dev/stage/prod)')
    env_cm_add.add_argument('app', help='App name (CUE identifier, e.g., exampleApp)')
    env_cm_add.add_argument('key', help='ConfigMap key')
    env_cm_add.add_argument('value', help='ConfigMap value')

    env_cm_remove = env_cm_sub.add_parser('remove', help='Remove a ConfigMap entry')
    env_cm_remove.add_argument('file', help='CUE file to modify')
    env_cm_remove.add_argument('env', help='Environment name')
    env_cm_remove.add_argument('app', help='App name (CUE identifier)')
    env_cm_remove.add_argument('key', help='ConfigMap key to remove')

    # app-configmap subcommand
    app_cm = subparsers.add_parser('app-configmap', help='Modify app-level ConfigMap entries')
    app_cm_sub = app_cm.add_subparsers(dest='action')

    app_cm_add = app_cm_sub.add_parser('add', help='Add a ConfigMap entry')
    app_cm_add.add_argument('file', help='CUE file to modify')
    app_cm_add.add_argument('app', help='App name (CUE identifier)')
    app_cm_add.add_argument('key', help='ConfigMap key')
    app_cm_add.add_argument('value', help='ConfigMap value')

    app_cm_remove = app_cm_sub.add_parser('remove', help='Remove a ConfigMap entry')
    app_cm_remove.add_argument('file', help='CUE file to modify')
    app_cm_remove.add_argument('app', help='App name (CUE identifier)')
    app_cm_remove.add_argument('key', help='ConfigMap key to remove')

    # env-field subcommand
    env_field = subparsers.add_parser('env-field', help='Modify environment-level fields')
    env_field_sub = env_field.add_subparsers(dest='action')

    env_field_set = env_field_sub.add_parser('set', help='Set a field value')
    env_field_set.add_argument('file', help='CUE file to modify')
    env_field_set.add_argument('env', help='Environment name')
    env_field_set.add_argument('app', help='App name (CUE identifier)')
    env_field_set.add_argument('field', help='Field name')
    env_field_set.add_argument('value', help='Field value')

    env_field_remove = env_field_sub.add_parser('remove', help='Remove a field')
    env_field_remove.add_argument('file', help='CUE file to modify')
    env_field_remove.add_argument('env', help='Environment name')
    env_field_remove.add_argument('app', help='App name (CUE identifier)')
    env_field_remove.add_argument('field', help='Field name to remove')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Read the file
    file_path = Path(args.file).resolve()
    if not file_path.exists():
        print(f"Error: File not found: {file_path}", file=sys.stderr)
        sys.exit(1)

    content = file_path.read_text()
    project_root = find_project_root(str(file_path))

    # Apply the modification
    try:
        if args.command == 'env-configmap':
            if args.action == 'add':
                new_content = add_env_configmap_entry(content, args.env, args.app, args.key, args.value)
            elif args.action == 'remove':
                new_content = remove_env_configmap_entry(content, args.env, args.app, args.key)
            else:
                print(f"Error: Unknown action: {args.action}", file=sys.stderr)
                sys.exit(1)
        elif args.command == 'app-configmap':
            if args.action == 'add':
                new_content = add_app_configmap_entry(content, args.app, args.key, args.value)
            elif args.action == 'remove':
                new_content = remove_app_configmap_entry(content, args.app, args.key)
            else:
                print(f"Error: Unknown action: {args.action}", file=sys.stderr)
                sys.exit(1)
        elif args.command == 'env-field':
            if args.action == 'set':
                new_content = set_env_field(content, args.env, args.app, args.field, args.value)
            elif args.action == 'remove':
                new_content = remove_env_field(content, args.env, args.app, args.field)
            else:
                print(f"Error: Unknown action: {args.action}", file=sys.stderr)
                sys.exit(1)
        else:
            print(f"Error: Unknown command: {args.command}", file=sys.stderr)
            sys.exit(1)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    # Write to temp file and validate
    with tempfile.NamedTemporaryFile(mode='w', suffix='.cue', delete=False) as tmp:
        tmp.write(new_content)
        tmp_path = tmp.name

    try:
        # Copy to original location for validation (CUE needs proper module context)
        backup_path = str(file_path) + '.bak'
        shutil.copy(str(file_path), backup_path)

        try:
            # Write new content
            file_path.write_text(new_content)

            # Validate
            valid, output = run_cue_vet(str(file_path), project_root)

            if not valid:
                # Restore original
                shutil.move(backup_path, str(file_path))
                print(f"Error: CUE validation failed:\n{output}", file=sys.stderr)
                sys.exit(1)

            # Success - remove backup
            Path(backup_path).unlink(missing_ok=True)
            print(f"Successfully modified {file_path}")

        except Exception as e:
            # Restore on any error
            if Path(backup_path).exists():
                shutil.move(backup_path, str(file_path))
            raise

    finally:
        Path(tmp_path).unlink(missing_ok=True)


if __name__ == '__main__':
    main()
