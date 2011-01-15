"""
The B{0install add-feed} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys
import logging

from zeroinstall import cmd, SafeException, _
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model, writer, handler
from zeroinstall.injector.policy import Policy

syntax = "NEW-FEED"

def add_options(parser):
	parser.add_option("-o", "--offline", help=_("try to avoid using the network"), action='store_true')

def handle(config, options, args, add_ok = True, remove_ok = False):
	if not args: raise UsageError()

	if os.isatty(1):
		h = handler.ConsoleHandler()
	else:
		h = handler.Handler()
	h.dry_run = bool(options.dry_run)

	def find_feed_import(iface, feed_url):
		for f in iface.extra_feeds:
			if f.uri == feed_url:
				return f
		return None

	for x in args:
		print _("Feed '%s':") % x + '\n'
		x = model.canonical_iface_uri(x)
		policy = Policy(x, h)
		if options.offline:
			policy.network_use = model.network_offline

		feed = config.iface_cache.get_feed(x)
		if policy.network_use != model.network_offline and policy.is_stale(feed):
			blocker = policy.fetcher.download_and_import_feed(x, config.iface_cache)
			print _("Downloading feed; please wait...")
			h.wait_for_blocker(blocker)
			print _("Done")

		candidate_interfaces = policy.get_feed_targets(x)
		assert candidate_interfaces
		interfaces = []
		for i in range(len(candidate_interfaces)):
			iface = candidate_interfaces[i]
			if find_feed_import(iface, x):
				if remove_ok:
					print _("%(index)d) Remove as feed for '%(uri)s'") % {'index': i + 1, 'uri': iface.uri}
					interfaces.append(iface)
			else:
				if add_ok:
					print _("%(index)d) Add as feed for '%(uri)s'") % {'index': i + 1, 'uri': iface.uri}
					interfaces.append(iface)
		if not interfaces:
			if remove_ok:
				raise SafeException(_("%(feed)s is not registered as a feed for %(interface)s") %
							{'feed': x, 'interface': candidate_interfaces[0]})
			else:
				raise SafeException(_("%(feed)s already registered as a feed for %(interface)s") %
							{'feed': x, 'interface': candidate_interfaces[0]})
		print
		while True:
			try:
				i = raw_input(_('Enter a number, or CTRL-C to cancel [1]: ')).strip()
			except KeyboardInterrupt:
				print
				raise SafeException(_("Aborted at user request."))
			if i == '':
				i = 1
			else:
				try:
					i = int(i)
				except ValueError:
					i = 0
			if i > 0 and i <= len(interfaces):
				break
			print _("Invalid number. Try again. (1 to %d)") % len(interfaces)
		iface = interfaces[i - 1]
		feed_import = find_feed_import(iface, x)
		if feed_import:
			iface.extra_feeds.remove(feed_import)
		else:
			iface.extra_feeds.append(model.Feed(x, arch = None, user_override = True))
		writer.save_interface(iface)
		print '\n' + _("Feed list for interface '%s' is now:") % iface.get_name()
		if iface.extra_feeds:
			for f in iface.extra_feeds:
				print "- " + f.uri
		else:
			print _("(no feeds)")
