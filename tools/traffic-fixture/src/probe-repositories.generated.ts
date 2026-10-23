import type { ProbeRepository } from './probe-repositories'

// Default source tree exposes no run-specific probe repositories.
// Generate an allowlist explicitly for a physical test deployment.
export const PROBE_REPOSITORIES: readonly ProbeRepository[] = Object.freeze([])
