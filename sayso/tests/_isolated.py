"""Imported first by every test: all engine state (sessions, limits,
settings, symbol masters) goes to a throwaway folder, never the live one."""

import os
import tempfile

os.environ["SAYSO_HOME"] = tempfile.mkdtemp(prefix="sayso-test-")
os.environ.pop("SAYSO_ACCOUNT", None)
