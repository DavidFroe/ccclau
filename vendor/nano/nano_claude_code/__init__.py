"""Nano Claude Code — Python agent converted from nano-claude-code (TypeScript)."""

__version__ = "0.2.0"

import os as _os
# Anzeigename/-version (clau.sh setzt CLAU_NANO_NAME / CLAU_NANO_VERSION; zentral dort ändern)
DISPLAY_NAME = _os.environ.get("CLAU_NANO_NAME", "").strip() or "Qode"
DISPLAY_VERSION = _os.environ.get("CLAU_NANO_VERSION", "").strip() or "0.0.1a"
