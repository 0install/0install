"""
A simple non-interactive policy.

This module provides a simple policy that will select, download and run a suitable set of
implementations. It is not interactive. This is the policy used when you run B{0launch -c}, and
is also the policy used to run the injector's GUI.

@deprecated: The interesting functionality has moved into the L{policy.Policy} base-class.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
from logging import info

from zeroinstall.injector import policy
from zeroinstall.injector.handler import Handler

class AutoPolicy(policy.Policy):
	def __init__(self, interface_uri, download_only = False, dry_run = False, src = False, handler = None, command = 'run'):
		"""@param handler: (new in 0.30) handler to use, or None to create a L{Handler}"""
		assert download_only is False
		handler = handler or Handler()
		if dry_run:
			info(_("Note: dry_run is deprecated. Pass it to the handler instead!"))
			handler.dry_run = True
		policy.Policy.__init__(self, interface_uri, handler, src = src, command = command)
