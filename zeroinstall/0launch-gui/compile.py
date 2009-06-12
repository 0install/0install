# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, subprocess
import gobject
import dialog
from logging import info

from zeroinstall.injector import reader, iface_cache, model
from zeroinstall.injector.policy import Policy
	
XMLNS_0COMPILE = 'http://zero-install.sourceforge.net/2006/namespaces/0compile'

class Command:
	def __init__(self):
		self.child = None
		self.error = ""

	def run(self, command, success):
		assert self.child is None
		self.success = success
		self.child = subprocess.Popen(command,
						stdout = subprocess.PIPE,
						stderr = subprocess.STDOUT)
		gobject.io_add_watch(self.child.stdout, gobject.IO_IN | gobject.IO_HUP, self.got_data)
	
	def got_data(self, src, cond):
		data = os.read(src.fileno(), 100)
		if data:
			self.error += data
			return True
		else:
			status = self.child.wait()
			self.child = None

			if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0:
				self.success()
			else:
				if os.WIFEXITED(status):
					status = os.WEXITSTATUS(status)
					if status == 1 and not self.error:
						return False # Cancelled
					dialog.alert(None, _("Command failed with exit code %(status)d:\n%(error)s\n") %
						{'status': status, 'error': self.error})
				else:
					dialog.alert(None, _("Command failed:\n%s\n") % self.error)
			return False

def compile(policy, interface, autocompile = False):
	our_min_version = '0.18'	# The oldest version of 0compile we support

	def add_feed():
		# A new local feed may have been registered, so update the interface from the cache
		info(_("0compile command completed successfully. Reloading interface details."))
		reader.update_from_cache(interface)
		policy.recalculate()

	def build():
		# Get the chosen versions
		src_policy = Policy(interface.uri, src = True)
		src_policy.freshness = 0

		src_policy.recalculate()
		if not src_policy.ready:
			raise Exception(_('Internal error: required source components not found!'))

		root_iface = iface_cache.iface_cache.get_interface(src_policy.root)
		impl = src_policy.implementation[root_iface]

		min_version = impl.metadata.get(XMLNS_0COMPILE + ' min-version', our_min_version)
		# Check the syntax is valid and the version is high enough
		if model.parse_version(min_version) < model.parse_version(our_min_version):
			min_version = our_min_version

		# Do the whole build-and-register-feed
		c = Command()
		c.run(("0launch",
			'--message', _('Download the 0compile tool, to compile the source code'),
			'--not-before=' + min_version,
			"http://0install.net/2006/interfaces/0compile.xml",
			'gui',
			'--no-prompt',
			interface.uri), add_feed)

	if autocompile:
		c = Command()
		c.run(("0launch",
			'--message', 'Download the 0compile tool, to compile the source code',
			'--not-before=' + our_min_version,
			"http://0install.net/2006/interfaces/0compile.xml",
			'autocompile',
			'--gui',
			interface.uri), add_feed)
	else:
		# Prompt user to choose source version
		c = Command()
		c.run(['0launch',
			'--message', _('Download the source code to be compiled'),
			'--gui', '--source', '--download-only', interface.uri], build)
