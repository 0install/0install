# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys

def open_in_browser(link):
	browser = os.environ.get('BROWSER', 'firefox')
	child = os.fork()
	if child == 0:
		# We are the child
		try:
			os.spawnlp(os.P_NOWAIT, browser, browser, link)
			os._exit(0)
		except Exception, ex:
			print >>sys.stderr, "Error", ex
			os._exit(1)
	os.waitpid(child, 0)
