# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, subprocess
import gobject
import dialog
from StringIO import StringIO

from zeroinstall.injector import model, selections, qdom

XMLNS_0COMPILE = 'http://zero-install.sourceforge.net/2006/namespaces/0compile'

class Command:
	def __init__(self):
		self.child = None
		self.error = ""
		self.stdout = ""
		self.watched_streams = 0

	def run(self, command, success, get_stdout = False):
		assert self.child is None
		self.success = success
		if get_stdout:
			self.child = subprocess.Popen(command,
							stdout = subprocess.PIPE,
							stderr = subprocess.PIPE)
			gobject.io_add_watch(self.child.stdout, gobject.IO_IN | gobject.IO_HUP, self.got_stdout)
			gobject.io_add_watch(self.child.stderr, gobject.IO_IN | gobject.IO_HUP, self.got_errors)
			self.watched_streams = 2
		else:
			self.child = subprocess.Popen(command,
							stdout = subprocess.PIPE,
							stderr = subprocess.STDOUT)
			gobject.io_add_watch(self.child.stdout, gobject.IO_IN | gobject.IO_HUP, self.got_errors)
			self.watched_streams = 1

	def got_stdout(self, src, cond):
		data = os.read(src.fileno(), 100)
		if data:
			self.stdout += data
			return True
		else:
			self.done()
			return False

	def done(self):
		self.watched_streams -= 1
		if self.watched_streams == 0:
			status = self.child.wait()
			self.child = None

			if status == 0:
				self.success(self.stdout)
			else:
				if status == 1 and not self.error:
					return False # Cancelled
				dialog.alert(None, _("Command failed with exit code %(status)d:\n%(error)s\n") %
					{'status': status, 'error': self.error})

	def got_errors(self, src, cond):
		data = os.read(src.fileno(), 100)
		if data:
			self.error += data
			return True
		else:
			self.done()
			return False

def compile(on_success, interface_uri, autocompile = False):
	our_min_version = '0.18'	# The oldest version of 0compile we support

	def build(selections_xml):
		# Get the chosen versions
		sels = selections.Selections(qdom.parse(StringIO(selections_xml)))

		impl = sels.selections[interface_uri]

		min_version = impl.attrs.get(XMLNS_0COMPILE + ' min-version', our_min_version)
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
			interface_uri), lambda unused: on_success())

	if autocompile:
		c = Command()
		c.run(("0launch",
			'--message', 'Download the 0compile tool, to compile the source code',
			'--not-before=' + our_min_version,
			"http://0install.net/2006/interfaces/0compile.xml",
			'autocompile',
			'--gui',
			interface_uri), lambda unused: on_success())
	else:
		# Prompt user to choose source version
		c = Command()
		c.run(['0install', 'download', '--xml',
			'--message', _('Download the source code to be compiled'),
			'--gui', '--source', '--', interface_uri], build, get_stdout = True)
