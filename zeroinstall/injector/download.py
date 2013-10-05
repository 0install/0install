"""
Handles URL downloads.

This is the low-level interface for downloading interfaces, implementations, icons, etc.

@see: L{fetch} higher-level API for downloads that uses this module
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import SafeException
from zeroinstall import _

download_fetching = "fetching"	# In progress
download_complete = "complete"	# Downloaded and cached OK
download_failed = "failed"

class DownloadError(SafeException):
	"""Download process failed."""
	pass

class DownloadAborted(DownloadError):
	"""Download aborted because of a call to L{Download.abort}"""
	def __init__(self, message = None):
		SafeException.__init__(self, message or _("Download aborted at user's request"))
