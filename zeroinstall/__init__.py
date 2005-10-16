version = '0.17'

class SafeException(Exception):
	"""An exception that can be reported to the user without a stack
	trace."""

class NeedDownload(SafeException):
	"""Thrown if we tried to start a download with allow_downloads = False"""
	def __init__(self, url):
		Exception.__init__(self, "Would download '%s'" % url)
