"""
The Python implementation of the Zero Install injector is divided into four sub-packages:

 - L{zeroinstall.injector} contains most of the interesting stuff for managing feeds, keys and downloads and for selecting versions
 - L{zeroinstall.zerostore} contains low-level code for handling the implementation cache (where unpacked packages are stored)
 - L{zeroinstall.gtkui} contains code for making GTK user-interfaces
 - L{zeroinstall.support} contains helper code (not really specific to Zero Install)

@copyright: (C) 2009, Thomas Leonard
@see: U{http://0install.net}
"""

version = '0.41'

#locale and setlocale are not required and may fail, and the program will run
#anyway
import locale
import gettext
import __builtin__
from logging import warn

try:
	locale.setlocale(locale.LC_ALL, '')
except locale.Error:
	warn('Error setting locale (eg. Invalid locale)')
#gettext.install('zero-install', names=['ngettext'])
#Unicode required for using non ascii chars in optparse
gettext.install('zero-install', unicode=True, names=['ngettext'])

def N_(message): return message
__builtin__.__dict__['N_'] = N_


class SafeException(Exception):
	"""An exception that can be reported to the user without a stack trace.
	The command-line interface's C{--verbose} option will display the full stack trace."""

class NeedDownload(SafeException):
	"""Thrown by L{injector.autopolicy.AutoPolicy} if we tried to start a download
	and downloading is disabled."""
	def __init__(self, url):
		Exception.__init__(self, _("Would download '%s'") % url)
