from __future__ import print_function

import locale
from logging import warn
try:
	locale.setlocale(locale.LC_ALL, '')
except locale.Error:
	warn('Error setting locale (eg. Invalid locale)')

import os, sys

## PATH ##

from optparse import OptionParser
import logging
from zeroinstall import SafeException

from zeroinstall.zerostore import cli, BadDigest

parser = OptionParser(usage="usage: 0install store " + 
			  '\n       0install store '.join([c.__doc__ for c in cli.commands]))
parser.add_option("-v", "--verbose", help="more verbose output", action='count')
parser.add_option("-V", "--version", help="display version information", action='store_true')
parser.disable_interspersed_args()

def main(argv):
	(options, args) = parser.parse_args(argv)

	if options.verbose:
		logger = logging.getLogger()
		if options.verbose == 1:
			logger.setLevel(logging.INFO)
		else:
			logger.setLevel(logging.DEBUG)
		hdlr = logging.StreamHandler()
		fmt = logging.Formatter("%(levelname)s:%(message)s")
		hdlr.setFormatter(fmt)
		logger.addHandler(hdlr)

	if len(args) < 1:
		parser.print_help()
		sys.exit(1)

	try:
		cli.init_stores()

		pattern = args[0].lower()
		matches = [c for c in cli.commands if c.__name__[3:].startswith(pattern)]
		if len(matches) == 0:
			parser.print_help()
			sys.exit(1)
		if len(matches) > 1:
			raise SafeException("What do you mean by '%s'?\n%s" %
				(pattern, '\n'.join(['- ' + x.__name__[3:] for x in matches])))
		matches[0](args[1:])
	except KeyboardInterrupt as ex:
		print("Interrupted", file=sys.stderr)
		sys.exit(1)
	except OSError as ex:
		if options.verbose: raise
		print(str(ex), file=sys.stderr)
		sys.exit(1)
	except IOError as ex:
		if options.verbose: raise
		print(str(ex), file=sys.stderr)
		sys.exit(1)
	except cli.UsageError as ex:
		print(str(ex), file=sys.stderr)
		print("usage: 0install store " + matches[0].__doc__, file=sys.stderr)
		sys.exit(1)
	except SafeException as ex:
		if options.verbose: raise
		print(str(ex), file=sys.stderr)
		sys.exit(1)
