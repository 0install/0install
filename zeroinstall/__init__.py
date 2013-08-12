"""
The Python implementation of the Zero Install injector is divided into five sub-packages:

 - L{zeroinstall.cmd} contains one module for each 0install sub-command (providing the shell-scripting interface)
 - L{zeroinstall.injector} contains most of the interesting stuff for managing feeds, keys and downloads and for selecting versions
 - L{zeroinstall.zerostore} contains low-level code for handling the implementation cache (where unpacked packages are stored)
 - L{zeroinstall.gtkui} contains code for making GTK user-interfaces
 - L{zeroinstall.support} contains helper code (not really specific to Zero Install)

@copyright: (C) 2011, Thomas Leonard
@see: U{http://0install.net}

@var _: a function for translating strings using the zero-install domain (for use internally by Zero Install)
"""

version = '2.3.3'

import logging

logger = logging.getLogger('0install')

# Configure some basic logging, if the caller hasn't already done so.
logging.basicConfig()

import gettext
from os.path import dirname, join

try:
	localedir = None
	translation = gettext.translation('zero-install', fallback = False)
except:
	localedir = join(dirname(dirname(__file__)), 'share', 'locale')
	translation = gettext.translation('zero-install',
				localedir = localedir,
				fallback = True)
try:
	_ = translation.ugettext	# Python 2
except AttributeError:
	_ = translation.gettext		# Python 3

class SafeException(Exception):
	"""An exception that can be reported to the user without a stack trace.
	The command-line interface's C{--verbose} option will display the full stack trace."""

class NeedDownload(SafeException):
	"""Thrown if we tried to start a download and downloading is
	disabled."""
	def __init__(self, url):
		"""@type url: str"""
		Exception.__init__(self, _("Would download '%s'") % url)

class DryRun(SafeException):
	"""We can't do something because this is a dry run (--dry-run).
	@since: 1.14"""
