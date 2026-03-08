# OpenClaw Guardian Development Protocol

This document defines the safety protocols to ensure system stability and prevent regressions.

## 🛡️ Core Rules

1.  **Main Branch Focus**: The `main` branch is the single source of truth. All production code, stability fixes, and feature releases directly target `main`.
2.  **Explicit Branching**: Dedicated branches (e.g., `feature/...`) should only be created when explicitly requested by the USER for large or experimental experimental research.
3.  **Pre-flight Linting**: Before every push to `main`, the automated linter must be run to catch potential syntax errors:
    ```bash
    python3 scripts/lint_guardian.py
    ```

## 🏗️ Versioning Strategy

-   **Production Sync**: Every push is considered a potential release candidate.
-   **Stable Tags**: Use git tags (e.g., `v1.8.x`) to mark stable milestones.

## 📜 Lessons Learned (The v1.8.8 Incident)
-   Avoid "Puppet Nesting" (Shell within Python within Shell) without rigorous escaping.
-   Large-scale surgical code deletion is safer than cumulative hot-patching.
-   Always verify the generated script's syntax, not just the parent script's syntax.
