# Copyright (C) 2013, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys
import locale
from logging import warn
try:
	locale.setlocale(locale.LC_ALL, '')
except locale.Error:
	warn('Error setting locale (eg. Invalid locale)')

from zeroinstall.cmd import main
import sys
main(sys.argv[1:])
