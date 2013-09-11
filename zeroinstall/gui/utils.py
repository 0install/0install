# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os

from logging import warning

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

def get_impl(config, details):
	feed_url = details['from-feed']
	feed = config.iface_cache.get_feed(feed_url)
	if feed is None: return None
	impl_id = details['id']
	if impl_id not in feed.implementations:
		# Python expands paths, whereas the OCaml doesn't. Convert to the Python format.
		if feed.local_path and (impl_id.startswith('.') or impl_id.startswith('/')):
			impl_id = os.path.abspath(os.path.join(os.path.dirname(feed.local_path), impl_id))
	impl = feed.implementations.get(impl_id, None)
	if not impl:
		warning("Implementation '%s' not found in feed '%s'!", impl_id, feed_url)
	return impl
