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

Platform-level changes:
  cue-edit.py platform-annotation add <key> <value>
  cue-edit.py platform-annotation remove <key>

Examples:
  # Add Prometheus scraping annotation to all deployments
  cue-edit.py platform-annotation add prometheus.io/scrape true

  # Remove the annotation
  cue-edit.py platform-annotation remove prometheus.io/scrape
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
    path = Path(file_path).resolve()
    # If it's a file, start from its parent directory
    if path.is_file():
        path = path.parent
    # Check current directory first, then walk up
    while path != path.parent:
        if (path / "cue.mod").exists() or (path / "services").exists():
            return str(path)
        path = path.parent
    # Fallback to original path
    return str(Path(file_path).resolve())


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


# ============================================================================
# PLATFORM-LEVEL ANNOTATION FUNCTIONS
# ============================================================================

def add_platform_annotation(project_root: str, key: str, value: str) -> dict:
    """Add a default pod annotation to the platform layer.

    This modifies two files:
    1. services/core/app.cue - Add/update defaultPodAnnotations struct and pass to template
    2. services/resources/deployment.cue - Accept and use defaultPodAnnotations

    Returns dict with 'app_cue' and 'deployment_cue' keys containing modified content.
    """
    app_cue_path = Path(project_root) / "services" / "core" / "app.cue"
    deployment_cue_path = Path(project_root) / "services" / "resources" / "deployment.cue"

    if not app_cue_path.exists():
        raise ValueError(f"File not found: {app_cue_path}")
    if not deployment_cue_path.exists():
        raise ValueError(f"File not found: {deployment_cue_path}")

    app_content = app_cue_path.read_text()
    deployment_content = deployment_cue_path.read_text()

    # Step 1: Add/update defaultPodAnnotations in app.cue
    app_content = _add_annotation_to_app_cue(app_content, key, value)

    # Step 2: Add defaultPodAnnotations to deployment template call (if not present)
    app_content = _add_annotation_param_to_template_call(app_content)

    # Step 3: Add defaultPodAnnotations parameter to deployment.cue (if not present)
    deployment_content = _add_annotation_param_to_deployment_cue(deployment_content)

    # Step 4: Add _podAnnotations merge logic (if not present)
    deployment_content = _add_annotation_merge_logic(deployment_content)

    # Step 5: Update pod template to use _podAnnotations (if not already)
    deployment_content = _update_pod_template_annotations(deployment_content)

    return {
        'app_cue': app_content,
        'deployment_cue': deployment_content,
        'app_cue_path': str(app_cue_path),
        'deployment_cue_path': str(deployment_cue_path),
    }


def _add_annotation_to_app_cue(content: str, key: str, value: str) -> str:
    """Add or update an annotation in defaultPodAnnotations struct."""
    # Check if defaultPodAnnotations already exists
    if 'defaultPodAnnotations:' in content:
        # Check if this specific key exists
        key_pattern = rf'"{re.escape(key)}":\s*"[^"]*"'
        if re.search(key_pattern, content):
            # Update existing key
            content = re.sub(
                rf'("{re.escape(key)}":\s*)"[^"]*"',
                rf'\1"{value}"',
                content
            )
        else:
            # Add new key to existing struct
            # Find the opening brace of defaultPodAnnotations
            match = re.search(r'defaultPodAnnotations:\s*\{', content)
            if match:
                insert_pos = match.end()
                new_entry = f'\n\t\t"{key}": "{value}"'
                content = content[:insert_pos] + new_entry + content[insert_pos:]
    else:
        # Create new defaultPodAnnotations struct after defaultLabels
        # Find the closing brace of defaultLabels
        match = re.search(r'defaultLabels:\s*\{[^}]+\}', content)
        if match:
            insert_pos = match.end()
            new_struct = f'''

\t// Default pod annotations applied to all deployments
\t// Merged with any podAnnotations provided via appConfig.deployment.podAnnotations
\tdefaultPodAnnotations: {{
\t\t"{key}": "{value}"
\t}}'''
            content = content[:insert_pos] + new_struct + content[insert_pos:]
        else:
            raise ValueError("Could not find defaultLabels block in app.cue")

    return content


def _add_annotation_param_to_template_call(content: str) -> str:
    """Add defaultPodAnnotations parameter to deployment template call."""
    if '"defaultPodAnnotations":' in content:
        return content  # Already present

    # Find the deployment template call and add the parameter after appEnvFrom
    pattern = r'("appEnvFrom":\s*_computedAppEnvFrom)'
    replacement = r'\1\n\t\t\t"defaultPodAnnotations": defaultPodAnnotations'
    content = re.sub(pattern, replacement, content)

    return content


def _add_annotation_param_to_deployment_cue(content: str) -> str:
    """Add defaultPodAnnotations parameter to #DeploymentTemplate."""
    if 'defaultPodAnnotations:' in content:
        return content  # Already present

    # Add after appEnvFrom parameter definition
    pattern = r'(appEnvFrom:\s*\[\.\.\.[^\]]+\]\s*\|\s*\*\[\])'
    replacement = r'''\1

\t// Default pod annotations (provided by app.cue)
\t// Merged with appConfig.deployment.podAnnotations
\tdefaultPodAnnotations: [string]: string'''
    content = re.sub(pattern, replacement, content)

    return content


def _add_annotation_merge_logic(content: str) -> str:
    """Add _podAnnotations computed field that merges defaults with config."""
    if '_podAnnotations:' in content:
        return content  # Already present

    # Add after _labels definition
    pattern = r'(_labels:\s*_defaultLabels\s*&\s*appConfig\.labels)'
    replacement = r'''\1

\t// Computed pod annotations - merge defaults with config
\t_podAnnotations: defaultPodAnnotations & (appConfig.deployment.podAnnotations | {})'''
    content = re.sub(pattern, replacement, content)

    return content


def _update_pod_template_annotations(content: str) -> str:
    """Update pod template to always render annotations using _podAnnotations."""
    if 'annotations: _podAnnotations' in content:
        return content  # Already updated

    # Replace the conditional annotation block with direct assignment
    # Pattern matches the if block for podAnnotations in the template metadata
    pattern = r'if appConfig\.deployment\.podAnnotations != _\|_ \{\s*\n\s*annotations: appConfig\.deployment\.podAnnotations\s*\n\s*\}'
    replacement = 'annotations: _podAnnotations'
    content = re.sub(pattern, replacement, content)

    return content


def remove_platform_annotation(project_root: str, key: str) -> dict:
    """Remove a default pod annotation from the platform layer.

    Returns dict with modified content for both files.
    """
    app_cue_path = Path(project_root) / "services" / "core" / "app.cue"
    deployment_cue_path = Path(project_root) / "services" / "resources" / "deployment.cue"

    if not app_cue_path.exists():
        raise ValueError(f"File not found: {app_cue_path}")

    app_content = app_cue_path.read_text()
    deployment_content = deployment_cue_path.read_text()

    # Remove the specific annotation key from defaultPodAnnotations
    # Pattern to match the key-value line with surrounding whitespace
    pattern = rf'\n\s*"{re.escape(key)}":\s*"[^"]*"'
    app_content = re.sub(pattern, '', app_content)

    # Check if defaultPodAnnotations is now empty
    empty_struct_pattern = r'defaultPodAnnotations:\s*\{\s*\}'
    if re.search(empty_struct_pattern, app_content):
        # Remove the entire defaultPodAnnotations block including comment
        full_block_pattern = r'\n\s*// Default pod annotations[^\n]*\n\s*// Merged with[^\n]*\n\s*defaultPodAnnotations:\s*\{\s*\}'
        app_content = re.sub(full_block_pattern, '', app_content)

        # Also remove from template call
        app_content = re.sub(r'\n\s*"defaultPodAnnotations":\s*defaultPodAnnotations', '', app_content)

        # Revert deployment.cue changes
        # Remove _podAnnotations line
        deployment_content = re.sub(
            r'\n\s*// Computed pod annotations[^\n]*\n\s*_podAnnotations:[^\n]+',
            '',
            deployment_content
        )

        # Remove defaultPodAnnotations parameter
        deployment_content = re.sub(
            r'\n\s*// Default pod annotations[^\n]*\n\s*// Merged with[^\n]*\n\s*defaultPodAnnotations:[^\n]+',
            '',
            deployment_content
        )

        # Revert to conditional annotation rendering
        deployment_content = re.sub(
            r'annotations: _podAnnotations',
            '''if appConfig.deployment.podAnnotations != _|_ {
\t\t\t\t\tannotations: appConfig.deployment.podAnnotations
\t\t\t\t}''',
            deployment_content
        )

    return {
        'app_cue': app_content,
        'deployment_cue': deployment_content,
        'app_cue_path': str(app_cue_path),
        'deployment_cue_path': str(deployment_cue_path),
    }


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

    # platform-annotation subcommand
    platform_ann = subparsers.add_parser('platform-annotation', help='Modify platform-level pod annotations')
    platform_ann_sub = platform_ann.add_subparsers(dest='action')

    platform_ann_add = platform_ann_sub.add_parser('add', help='Add a default pod annotation')
    platform_ann_add.add_argument('key', help='Annotation key (e.g., prometheus.io/scrape)')
    platform_ann_add.add_argument('value', help='Annotation value (e.g., true)')

    platform_ann_remove = platform_ann_sub.add_parser('remove', help='Remove a default pod annotation')
    platform_ann_remove.add_argument('key', help='Annotation key to remove')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Handle platform-annotation separately (it operates on project root, not a single file)
    if args.command == 'platform-annotation':
        # Find project root from current directory
        project_root = find_project_root(str(Path.cwd()))

        try:
            if args.action == 'add':
                results = add_platform_annotation(project_root, args.key, args.value)
            elif args.action == 'remove':
                results = remove_platform_annotation(project_root, args.key)
            else:
                print(f"Error: Unknown action: {args.action}", file=sys.stderr)
                sys.exit(1)

            # Write both files and validate
            app_cue_path = Path(results['app_cue_path'])
            deployment_cue_path = Path(results['deployment_cue_path'])

            # Backup both files
            app_backup = str(app_cue_path) + '.bak'
            deployment_backup = str(deployment_cue_path) + '.bak'
            shutil.copy(str(app_cue_path), app_backup)
            shutil.copy(str(deployment_cue_path), deployment_backup)

            try:
                # Write new content
                app_cue_path.write_text(results['app_cue'])
                deployment_cue_path.write_text(results['deployment_cue'])

                # Validate with cue vet -c=false (main branch env.cue is incomplete by design)
                result = subprocess.run(
                    ["cue", "vet", "-c=false", "./..."],
                    cwd=project_root,
                    capture_output=True,
                    text=True,
                    timeout=30
                )

                if result.returncode != 0:
                    # Restore backups
                    shutil.move(app_backup, str(app_cue_path))
                    shutil.move(deployment_backup, str(deployment_cue_path))
                    print(f"Error: CUE validation failed:\n{result.stderr}", file=sys.stderr)
                    sys.exit(1)

                # Success - remove backups
                Path(app_backup).unlink(missing_ok=True)
                Path(deployment_backup).unlink(missing_ok=True)
                print(f"Successfully modified {app_cue_path}")
                print(f"Successfully modified {deployment_cue_path}")
                sys.exit(0)

            except Exception as e:
                # Restore on any error
                if Path(app_backup).exists():
                    shutil.move(app_backup, str(app_cue_path))
                if Path(deployment_backup).exists():
                    shutil.move(deployment_backup, str(deployment_cue_path))
                raise

        except ValueError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)

    # Read the file (for non-platform-annotation commands)
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
