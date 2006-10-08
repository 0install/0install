"""
The Python implementation of the Zero Install injector is divided into three packages:

 - zeroinstall (this package) just defines a couple of exceptions and the version number.
 - L{zeroinstall.injector} contains most of the interesting stuff.
 - L{zeroinstall.zerostore} contains low-level code for handling the
   implementation cache.

@copyright: (C) 2006, Thomas Leonard
@see: U{http://0install.net}
"""

version = '0.23'

class SafeException(Exception):
	"""An exception that can be reported to the user without a stack trace.
	The command-line interface's C{--verbose} option will display the full stack trace."""

class NeedDownload(SafeException):
	"""Thrown by L{injector.autopolicy.AutoPolicy} if we tried to start a download
	and downloading is disabled."""
	def __init__(self, url):
		Exception.__init__(self, "Would download '%s'" % url)
