// Environment configuration template
//
// This file is intentionally empty in the main branch.
// Each environment branch (dev, stage, prod) should have its own
// env.cue with environment-specific settings.
//
// See example-env.cue for a reference configuration.
//
package envs

import (
	"deployments.local/k8s-deployments/services/apps"
)

// Environment configurations are defined per-branch:
// - dev branch: dev: exampleApp: apps.exampleApp & { ... }
// - stage branch: stage: exampleApp: apps.exampleApp & { ... }
// - prod branch: prod: exampleApp: apps.exampleApp & { ... }
