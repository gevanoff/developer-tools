"""Pure display logic for the dashboard: status tones and the Sync & Run preview.

Nothing here touches Qt, Git, ADB, or the filesystem, so it can be unit tested
without a display. The preview mirrors ``core.build_install(sync=True)`` and must
be kept in step with it.
"""
from __future__ import annotations

from dataclasses import dataclass, field

# Tones describe what a status means for the next Sync & Run, not just whether
# it is "good". Colour is never the only signal: the status text is always shown.
OK = "ok"            # nothing to do
ACTION = "action"    # Sync & Run will act on this (pull, build, install)
WARN = "warn"        # needs a decision or setting before Sync & Run can proceed
ERROR = "error"      # something failed or the state is unsafe
NEUTRAL = "neutral"  # informational, pending, or not yet known

_EXACT = {
    "Current": OK, "Fresh": OK, "Same": OK,
    "Stale": ACTION, "No APK": ACTION, "Different": ACTION, "Not installed": ACTION,
    "Dirty": WARN, "No upstream": WARN, "Detached": WARN,
    "Ambiguous": WARN, "Preferred missing": WARN, "Preferred invalid": WARN,
    "Configuration needed": WARN, "No project": WARN, "No Gradle": WARN,
    "No device": WARN, "Choose device": WARN, "Preferred absent": WARN,
    "Fetch failed": ERROR, "Git error": ERROR, "Git unavailable": ERROR,
    "Missing": ERROR, "Failed": ERROR, "Timed out": ERROR,
}
_PREFIX = (("Behind", ACTION), ("Diverged", ERROR), ("Ahead", NEUTRAL))


def tone(status: str | None) -> str:
    """Return the tone for a Git, Local Build, or Device status string."""
    text = (status or "").strip()
    if text in _EXACT:
        return _EXACT[text]
    for prefix, value in _PREFIX:
        if text.startswith(prefix + " ") or text == prefix:
            return value
    return NEUTRAL


@dataclass
class SyncPreview:
    """What Sync & Run is expected to do, based on the last status check."""
    ready: bool
    headline: str
    steps: list[str] = field(default_factory=list)
    fix: str = ""


_GIT_STOPS = {
    "Dirty": "the working tree has local changes",
    "No upstream": "the branch has no upstream",
    "Unknown": "Git status could not be checked",
}


def sync_preview(git: str, build: str, device: str, auto_launch: bool) -> SyncPreview:
    """Predict the Sync & Run path from cached status strings.

    Mirrors ``core.build_install(project, sync=True)``: the build plan and then
    the device are resolved first, Git must be clean and not diverged, a stale or missing APK is
    rebuilt, installation is skipped only when the hashes match, and launch
    follows the project's auto-launch setting.
    """
    git, build, device = (git or "").strip(), (build or "").strip(), (device or "").strip()

    if git in ("", "Queued", "Checking…") or build in ("", "Queued", "Checking…"):
        return SyncPreview(False, "Status not checked yet.", fix="Refresh to see what Sync & Run will do.")

    if build == "Configuration needed":
        return SyncPreview(False, "Sync & Run will stop: the build needs configuring.",
                           fix="Open Settings, then Godot / custom build.")
    if device == "No device":
        return SyncPreview(False, "Sync & Run will stop: no usable device.",
                           fix="Connect and authorise one device, or save a preferred device in Settings.")
    if git in _GIT_STOPS:
        return SyncPreview(False, f"Sync & Run will stop: {_GIT_STOPS[git]}.",
                           fix="Resolve it in Git, or use Build & Install to build the current files.")
    if git.startswith("Diverged"):
        return SyncPreview(False, "Sync & Run will stop: the branch has diverged from its upstream.",
                           fix="Resolve the branch in Git, or use Build & Install to build the current files.")

    steps: list[str] = []
    if git.startswith("Behind"):
        count = git.split(" ", 1)[1].strip() if " " in git else ""
        steps.append(f"Pull {count} commit{'' if count == '1' else 's'}" if count else "Pull")
    if build in ("Stale", "No APK", "Preferred missing", "Ambiguous"):
        steps.append("Build")
    if device == "Same":
        # A pull or rebuild changes the APK, so the cached comparison no longer holds.
        steps.append("Install if changed" if steps else "Skip install (same APK)")
    else:
        steps.append("Install")
    steps.append("Launch" if auto_launch else "No launch")

    fix = ""
    if build in ("Ambiguous", "Preferred missing"):
        fix = "If the build leaves several APKs, set a Preferred APK in Settings."
    return SyncPreview(True, "Sync & Run will: " + " → ".join(steps) + ".", steps, fix)
