"""
The B{0install config} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys
import logging
import ConfigParser

from zeroinstall import cmd, SafeException, _
from zeroinstall.support import basedir
from zeroinstall.injector import policy, namespaces, model
from zeroinstall.cmd import UsageError

syntax = "[NAME [VALUE]]"

def add_options(parser):
	pass

def handle(options, args):
	config = policy.load_config()
	if len(args) == 0:
		if options.gui is None and os.environ.get('DISPLAY', None):
			options.gui = True
		if options.gui:
			from zeroinstall import helpers
			return helpers.get_selections_gui(None, [])
		else:
			config.write(sys.stdout)
		return
	elif len(args) > 2:
		raise UsageError()

	if '.' not in args[0]:
		raise SafeException(_('Missing section name in "%s" (e.g. try "global.freshness")') % args[0])
	section, option = args[0].split('.', 1)

	if len(args) == 1:
		try:
			print config.get(section, option)
		except ConfigParser.NoOptionError, ex:
			raise SafeException(str(ex))
		except ConfigParser.NoSectionError, ex:
			raise SafeException(str(ex))
	else:
		if section != 'global':
			raise SafeException(_('Unknown section "%s" (try "global")' % section))

		value = args[1]
		if option == 'freshness':
			int(value)
		elif option == 'help_with_testing':
			if value.lower() == 'true':
				value = 'True'
			elif value.lower() == 'false':
				value = 'False'
			else:
				raise SafeException(_('Must be True or False, not "%s"') % value)
		elif option == 'network_use':
			if value not in model.network_levels:
				raise SafeException(_("Must be one of %s") % list(model.network_levels))
		else:
			raise SafeException(_('Unknown option "%s"') % option)

		config.set(section, option, value)
		path = basedir.save_config_path(namespaces.config_site, namespaces.config_prog)
		path = os.path.join(path, 'global')
		config.write(file(path + '.new', 'w'))
		os.rename(path + '.new', path)
