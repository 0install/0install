"""
Useful support routines (for internal use).

These functions aren't really Zero Install specific; they're things we might
wish were in the standard library.

@since: 0.27
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys, os

def ro_rmtree(root):
	"""Like shutil.rmtree, except that we also delete read-only items.
	@param root: the root of the subtree to remove
	@type root: str
	@since: 0.28"""
	import shutil
	import platform
	if (os.getcwd() + os.path.sep).startswith(root + os.path.sep):
		import warnings
		warnings.warn("Removing tree ({tree}) containing the current directory ({cwd}) - this will not work on Windows".format(cwd = os.getcwd(), tree = root), stacklevel = 2)

	if os.path.isfile(root):
		os.chmod(root, 0o700)
		os.remove(root)
	else:
		if platform.system() == 'Windows':
			for main, dirs, files in os.walk(root):
				for i in files + dirs:
					os.chmod(os.path.join(main, i), 0o700)
			os.chmod(root, 0o700)
		else:
			for main, dirs, files in os.walk(root):
				os.chmod(main, 0o700)
		shutil.rmtree(root)

if sys.version_info[0] > 2:
	# Python 3
	unicode = str

else:
	# Python 2
	unicode = unicode		# (otherwise it can't be imported)
