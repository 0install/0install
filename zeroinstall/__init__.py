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

version = '2.5.1-post'

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
