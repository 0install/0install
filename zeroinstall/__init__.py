# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

version = '0.18'

class SafeException(Exception):
	"""An exception that can be reported to the user without a stack
	trace."""

class NeedDownload(SafeException):
	"""Thrown if we tried to start a download with allow_downloads = False"""
	def __init__(self, url):
		Exception.__init__(self, "Would download '%s'" % url)
