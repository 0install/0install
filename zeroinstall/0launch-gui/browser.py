# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import os, sys

def open_in_browser(link):
	browser = os.environ.get('BROWSER', 'firefox')
	child = os.fork()
	if child == 0:
		# We are the child
		try:
			os.spawnlp(os.P_NOWAIT, browser, browser, link)
			os._exit(0)
		except Exception as ex:
			print("Error", ex, file=sys.stderr)
			os._exit(1)
	os.waitpid(child, 0)
