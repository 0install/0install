# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
from zeroinstall import support

def get_fetch_info(config, impl):
	"""Get the text for a Fetch column."""
	if impl is None:
		return ""
	elif impl.is_available(config.stores):
		if impl.local_path:
			return _('(local)')
		elif impl.id.startswith('package:'):
			return _('(package)')
		else:
			return _('(cached)')
	else:
		src = config.fetcher.get_best_source(impl)
		if src:
			return support.pretty_size(src.size)
		else:
			return _('(unavailable)')
