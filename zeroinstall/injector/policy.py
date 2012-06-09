"""
@deprecated: see L{driver} instead.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall.injector.config import load_config

_config = None
def get_deprecated_singleton_config():
	global _config
	if _config is None:
		_config = load_config()
	return _config
