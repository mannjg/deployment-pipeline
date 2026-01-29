// Package core provides shared utilities for CUE templates
package core

import "list"

// #MergeEnvVars merges multiple lists of env var structs by name.
// Later lists override earlier lists for matching names.
// Non-matching entries are preserved from all lists.
//
// This solves the env var override problem where list.Concat creates
// duplicates that kubectl apply deduplicates incorrectly (first wins).
//
// Usage:
//   (#MergeEnvVars & {
//       base:      baseEnvVars     // First priority (lowest)
//       app:       appEnvVars      // Second priority
//       env:       envEnvVars      // Third priority (highest)
//       additional: additionalEnv  // Fourth priority (highest)
//   }).out
//
// Example:
//   base: [{name: "A", value: "1"}]
//   env:  [{name: "A", value: "2"}, {name: "B", value: "3"}]
//   Output: [{name: "A", value: "2"}, {name: "B", value: "3"}]
//
#MergeEnvVars: {
	// Input lists at different priority levels (all optional)
	base: [...{name: string, ...}] | *[]
	app: [...{name: string, ...}] | *[]
	env: [...{name: string, ...}] | *[]
	additional: [...{name: string, ...}] | *[]

	// Collect keys from higher-priority lists
	_additionalKeys: {for item in additional {(item.name): true}}
	_envKeys: {for item in env {(item.name): true}}
	_appKeys: {for item in app {(item.name): true}}

	// Filter each list to exclude items overridden by higher-priority lists
	_filteredBase: [for item in base if _appKeys[item.name] == _|_ && _envKeys[item.name] == _|_ && _additionalKeys[item.name] == _|_ {item}]
	_filteredApp: [for item in app if _envKeys[item.name] == _|_ && _additionalKeys[item.name] == _|_ {item}]
	_filteredEnv: [for item in env if _additionalKeys[item.name] == _|_ {item}]

	// Concatenate filtered lists (order: base, app, env, additional)
	out: list.Concat([_filteredBase, _filteredApp, _filteredEnv, additional])
}
