# Multi-Agent Orchestration Backlog

This backlog is intentionally upstream of `TASKS.md`. The items here are design candidates for review, annotation, and prioritization before they become implementation work.

## Foundation

- Introduce a first-class `workspace` concept above individual sandboxes.
  Refinement notes:
  One workspace should own a repo, a shared mission, multiple agent containers, and the policies that tie them together.

- Add orchestration metadata as a control plane.
  Refinement notes:
  Track role, assigned task, branch or worktree, status, last heartbeat, auth state, and dependency edges between agents.

- Define reusable agent-role templates.
  Refinement notes:
  Start with roles such as `planner`, `implementer`, `reviewer`, `tester`, and `integrator`, each with default stack, CLI, egress policy, and privileges.

## Coordination

- Add a machine-readable task graph and task claiming flow.
  Refinement notes:
  Agents should claim explicit work items instead of relying on a human to manually steer every sandbox.

- Add inter-agent communication primitives.
  Refinement notes:
  This can start with durable handoff notes, inbox or outbox files, and explicit artifact links before moving to a richer message bus.

- Add rendezvous and merge stages.
  Refinement notes:
  Define standard flows such as implement -> review -> integrate -> test so the system can coordinate multi-agent work instead of just running multiple isolated sessions.

## Execution

- Give each agent its own git worktree or branch automatically.
  Refinement notes:
  This reduces merge conflicts, makes ownership visible, and creates safer integration points than sharing one mutable checkout.

- Add conflict detection before merge time.
  Refinement notes:
  Detect overlapping file ownership, drifting branches, and incompatible edits early so the orchestrator can reassign or sequence work.

- Add safe artifact and cache sharing.
  Refinement notes:
  Shared dependency caches, test fixtures, and build outputs can preserve isolation while removing needless repeated setup costs.

## Observability

- Build a workspace-level status view.
  Refinement notes:
  One screen should show every agent, its task, branch, auth state, sandbox health, and test or CI status.

- Add session replay and audit logs.
  Refinement notes:
  Capture prompts, commands, outputs, commits, and handoffs so runs can be resumed, reviewed, or debugged.

## Product Direction Questions

- Decide how much orchestration should be declarative versus interactive.
  Refinement notes:
  A YAML or JSON workspace spec is reproducible, while an interactive command is easier to discover; the repo may want both.

- Decide where coordination state should live.
  Refinement notes:
  Options include Incus metadata, a repo-local control directory, or a lightweight local database. Each choice changes portability and inspectability.

- Decide how opinionated branch integration should be.
  Refinement notes:
  The orchestrator can stop at branch creation and status tracking, or it can actively manage rebases, merges, and integration branches.
