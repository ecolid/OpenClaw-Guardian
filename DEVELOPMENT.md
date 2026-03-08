# OpenClaw Guardian Development Protocol

This document defines the safety protocols to ensure system stability and prevent regressions.

## 🛡️ Core Rules

1.  **Main Branch Protection**: NEVER commit experimental or unverified changes directly to the `main` branch. The `main` branch must always contain a "Known Good" state (currently v1.8.1-stable).
2.  **Laboratory Branch (`dev`)**: All new features, optimizations, or rhythm adjustments MUST happen on the `dev` branch.
3.  **Pre-flight Linting**: Before merge or push, you must run the automated linter to catch syntax errors in embedded scripts:
    ```bash
    python3 scripts/lint_guardian.py
    ```

## 🏗️ Versioning Strategy

-   **Minor/Patch Updates**: Bug fixes and robust improvements go to `dev`, then merged to `main`.
-   **Experimental Features**: Use dedicated feature branches like `feature/absolute-rhythm`.

## 📜 Lessons Learned (The v1.8.8 Incident)
-   Avoid "Puppet Nesting" (Shell within Python within Shell) without rigorous escaping.
-   Large-scale surgical code deletion is safer than cumulative hot-patching.
-   Always verify the generated script's syntax, not just the parent script's syntax.
