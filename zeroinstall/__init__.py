"""
The Python implementation of the Zero Install injector is divided into four sub-packages:

 - L{zeroinstall.injector} contains most of the interesting stuff for managing feeds, keys and downloads and for selecting versions
 - L{zeroinstall.zerostore} contains low-level code for handling the implementation cache (where unpacked packages are stored)
 - L{zeroinstall.gtkui} contains code for making GTK user-interfaces
 - L{zeroinstall.support} contains helper code (not really specific to Zero Install)

@copyright: (C) 2009, Thomas Leonard
@see: U{http://0install.net}

@var _: a function for translating strings using the zero-install domain (for use internally by Zero Install)
"""

version = '0.44'

import gettext

translation = gettext.translation('zero-install', fallback = True)
_ = translation.ugettext

class SafeException(Exception):
	"""An exception that can be reported to the user without a stack trace.
	The command-line interface's C{--verbose} option will display the full stack trace."""

class NeedDownload(SafeException):
	"""Thrown by L{injector.autopolicy.AutoPolicy} if we tried to start a download
	and downloading is disabled."""
	def __init__(self, url):
		Exception.__init__(self, _("Would download '%s'") % url)
