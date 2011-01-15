"""
The B{0install import} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys
import logging

from zeroinstall import cmd, SafeException, _
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model, autopolicy, selections, gpg, fetch
from zeroinstall.injector.iface_cache import PendingFeed
from zeroinstall.support import tasks
from xml.dom import minidom

syntax = "FEED"

def add_options(parser):
	pass

def handle(config, options, args):
	if not args:
		raise UsageError()

	h = config.handler

	for x in args:
		if not os.path.isfile(x):
			raise SafeException(_("File '%s' does not exist") % x)
		logging.info(_("Importing from file '%s'"), x)
		signed_data = file(x)
		data, sigs = gpg.check_stream(signed_data)
		doc = minidom.parseString(data.read())
		uri = doc.documentElement.getAttribute('uri')
		if not uri:
			raise SafeException(_("Missing 'uri' attribute on root element in '%s'") % x)
		logging.info(_("Importing information about interface %s"), uri)
		signed_data.seek(0)

		pending = PendingFeed(uri, signed_data)

		def run():
			keys_downloaded = tasks.Task(pending.download_keys(h), "download keys")
			yield keys_downloaded.finished
			tasks.check(keys_downloaded.finished)
			if not config.iface_cache.update_feed_if_trusted(uri, pending.sigs, pending.new_xml):
				fetcher = fetch.Fetcher(h)
				blocker = h.confirm_keys(pending, fetcher.fetch_key_info)
				if blocker:
					yield blocker
					tasks.check(blocker)
				if not config.iface_cache.update_feed_if_trusted(uri, pending.sigs, pending.new_xml):
					raise SafeException(_("No signing keys trusted; not importing"))

		task = tasks.Task(run(), "import feed")

		errors = h.wait_for_blocker(task.finished)
		if errors:
			raise SafeException(_("Errors during download: ") + '\n'.join(errors))
