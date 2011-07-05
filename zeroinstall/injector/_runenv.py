"""
Helper script for <executable> bindings.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys

def main():
	envname = os.path.basename(sys.argv[0])
	import json
	args = json.loads(os.environ["0install-runenv-" + envname])
	os.execv(args[0], args + sys.argv[1:])
