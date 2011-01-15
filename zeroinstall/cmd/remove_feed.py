"""
The B{0install remove-feed} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

syntax = "FEED"

from zeroinstall.cmd import add_feed

add_options = add_feed.add_options

def handle(config, options, args):
	return add_feed.handle(config, options, args, add_ok = False, remove_ok = True)
