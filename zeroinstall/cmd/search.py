"""
The B{0install search} command-line interface.
"""

# Copyright (C) 2013, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys

from zeroinstall.injector import qdom
from zeroinstall.cmd import UsageError
from zeroinstall import logger

if sys.version_info[0] > 2:
	from urllib import request as urllib2
	from urllib.parse import quote
else:
	from urllib import quote
	import urllib2

syntax = "QUERY"

def add_options(parser):
	pass

def handle(config, options, args):
	if len(args) == 0:
		raise UsageError()

	url = config.mirror + '/search/?q=' + quote(' '.join(args))
	logger.info("Fetching %s...", url)
	root = qdom.parse(urllib2.urlopen(url))
	assert root.name == 'results'

	first = True
	for child in root.childNodes:
		if child.name != 'result': continue

		if first:
			first = False
		else:
			print()

		print(child.attrs['uri'])
		score = child.attrs['score']

		details = {}
		for detail in child.childNodes:
			details[detail.name] = detail.content
		print("  {name} - {summary} [{score}%]".format(
			name = child.attrs['name'],
			summary = details.get('summary', ''),
			score = score))
