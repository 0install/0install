"""
Convenience routines for performing common operations.
@since: 0.28
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import os
from zeroinstall import SafeException

DontUseGUI = object()

def should_use_gui(use_gui):
	if use_gui is False:
		return False

	if not os.environ.get('DISPLAY', None):
		if use_gui is None:
			return False
		else:
			raise SafeException("Can't use GUI because $DISPLAY is not set")

	from zeroinstall.gui import main
	if main.gui_is_available(use_gui):
		return True

	if use_gui is None:
		return False
	else:
		raise SafeException("No GUI available")
