"""
The B{0install remove-feed} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

syntax = "[INTERFACE] FEED"

from zeroinstall import SafeException, _
from zeroinstall.injector import model, writer, reader
from zeroinstall.cmd import add_feed, UsageError, list_feeds

add_options = add_feed.add_options

def handle(config, options, args):
	"""@type args: [str]"""
	if len(args) == 2:
		iface = config.iface_cache.get_interface(model.canonical_iface_uri(args[0]))
		try:
			feed_url = model.canonical_iface_uri(args[1])
		except SafeException:
			feed_url = args[1]		# File might not exist any longer

		feed_import = add_feed.find_feed_import(iface, feed_url)
		if not feed_import:
			raise SafeException(_('Interface %(interface)s has no feed %(feed)s') %
						{'interface': iface.uri, 'feed': feed_url})
		iface.extra_feeds.remove(feed_import)
		writer.save_interface(iface)
	elif len(args) == 1:
		add_feed.handle(config, options, args, add_ok = False, remove_ok = True)
	else:
		raise UsageError()

def complete(completion, args, cword):
	"""@type completion: L{zeroinstall.cmd._Completion}
	@type args: [str]
	@type cword: int"""
	if cword > 1: return
	if cword == 0:
		list_feeds.complete(completion, args[:1], 1)
		# Or it could be a feed directly
		completion.expand_files()

	if cword == 1:
		# With two arguments, we can only remove a feed that is registered
		dummy = model.Interface(args[0])
		reader.update_user_overrides(dummy)
		for feed in dummy.extra_feeds:
			completion.add_filtered(feed.uri)
