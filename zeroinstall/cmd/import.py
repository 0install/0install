"""
The B{0install import} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os

from zeroinstall import SafeException, _, logger
from zeroinstall.cmd import UsageError
from zeroinstall.injector import gpg
from zeroinstall.injector.iface_cache import PendingFeed
from zeroinstall.support import tasks
from xml.dom import minidom

syntax = "FEED"

def add_options(parser):
	pass

def handle(config, options, args):
	if not args:
		raise UsageError()

	for x in args:
		if not os.path.isfile(x):
			raise SafeException(_("File '%s' does not exist") % x)
		logger.info(_("Importing from file '%s'"), x)
		with open(x, 'rb') as signed_data:
			data, sigs = gpg.check_stream(signed_data)
			doc = minidom.parseString(data.read())
			uri = doc.documentElement.getAttribute('uri')
			if not uri:
				raise SafeException(_("Missing 'uri' attribute on root element in '%s'") % x)
			logger.info(_("Importing information about interface %s"), uri)
			signed_data.seek(0)

			pending = PendingFeed(uri, signed_data)

			def run():
				keys_downloaded = tasks.Task(pending.download_keys(config.fetcher), "download keys")
				yield keys_downloaded.finished
				tasks.check(keys_downloaded.finished)
				if not config.iface_cache.update_feed_if_trusted(uri, pending.sigs, pending.new_xml):
					blocker = config.trust_mgr.confirm_keys(pending)
					if blocker:
						yield blocker
						tasks.check(blocker)
					if not config.iface_cache.update_feed_if_trusted(uri, pending.sigs, pending.new_xml):
						raise SafeException(_("No signing keys trusted; not importing"))

			task = tasks.Task(run(), "import feed")

			tasks.wait_for_blocker(task.finished)

def complete(completion, args, cword):
	"""@type completion: L{zeroinstall.cmd._Completion}
	@type args: [str]
	@type cword: int"""
	if len(args) != 1: return
	completion.expand_files()
