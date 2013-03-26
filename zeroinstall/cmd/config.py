"""
The B{0install config} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import SafeException, _
from zeroinstall.injector import model
from zeroinstall.cmd import UsageError

syntax = "[NAME [VALUE]]"

def add_options(parser):
	pass

class String(object):
	@staticmethod
	def format(value):
		"""@type value: str
		@rtype: str"""
		return value

	@staticmethod
	def parse(value):
		"""@type value: str
		@rtype: str"""
		return value

class TimeInterval(object):
	@staticmethod
	def format(value):
		"""@type value: float
		@rtype: str"""
		def s(v):
			if int(v) == v:
				return str(int(v))
			else:
				return str(v)
		value = float(value)
		if value < 60:
			return s(value) + "s"
		value /= 60
		if value < 60:
			return s(value) + "m"
		value /= 60
		if value < 24:
			return s(value) + "h"
		value /= 24
		return s(value) + "d"

	@staticmethod
	def parse(value):
		"""@type value: str
		@rtype: int"""
		v = float(value[:-1])
		unit = value[-1]
		if unit == 's':
			return int(v)
		v *= 60
		if unit == 'm':
			return int(v)
		v *= 60
		if unit == 'h':
			return int(v)
		v *= 24
		if unit == 'd':
			return int(v)
		raise SafeException(_('Unknown unit "%s" - use e.g. 5d for 5 days') % unit)

class Boolean(object):
	@staticmethod
	def format(value):
		"""@type value: bool
		@rtype: str"""
		return str(value)

	@staticmethod
	def parse(value):
		"""@type value: str
		@rtype: bool"""
		if value.lower() == 'true':
			return True
		elif value.lower() == 'false':
			return False
		else:
			raise SafeException(_('Must be True or False, not "%s"') % value)

settings = {
	'network_use': String,
	'freshness': TimeInterval,
	'help_with_testing': Boolean,
	'auto_approve_keys': Boolean,
}

def handle(config, options, args):
	"""@type config: L{zeroinstall.injector.config.Config}
	@type args: [str]"""
	if len(args) == 0:
		from zeroinstall import helpers
		if helpers.get_selections_gui(None, [], use_gui = options.gui) == helpers.DontUseGUI:
			for key, setting_type in settings.items():
				value = getattr(config, key)
				print(key, "=", setting_type.format(value))
		# (else we displayed the preferences dialog in the GUI)
		return
	elif len(args) > 2:
		raise UsageError()

	option = args[0]
	if option not in settings:
		raise SafeException(_('Unknown option "%s"') % option)

	if len(args) == 1:
		value = getattr(config, option)
		print(settings[option].format(value))
	else:
		value = settings[option].parse(args[1])
		if option == 'network_use' and value not in model.network_levels:
			raise SafeException(_("Must be one of %s") % list(model.network_levels))
		setattr(config, option, value)

		config.save_globals()

def complete(completion, args, cword):
	"""@type completion: L{zeroinstall.cmd._Completion}
	@type args: [str]
	@type cword: int"""
	if cword == 0:
		for name in settings:
			completion.add_filtered(name)
	elif cword == 1:
		option = args[0]
		if settings.get(option, None) == Boolean:
			completion.add_filtered("true")
			completion.add_filtered("false")
		elif option == 'network_use':
			for level in model.network_levels:
				completion.add_filtered(level)
		elif option in settings:
			value = getattr(completion.config, option)
			completion.add_filtered(settings[option].format(value))
