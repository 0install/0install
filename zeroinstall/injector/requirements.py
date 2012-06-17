"""
Holds information about what the user asked for (which program, version constraints, etc).
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

class Requirements(object):
	"""
	Holds information about what the user asked for (which program, version constraints, etc).
	"""

	# Note: apps.py serialises our __slots__
	__slots__ = [
		'interface_uri',
		'command',
		'source',
		'before', 'not_before',
		'os', 'cpu',
		'message',
	]

	def __init__(self, interface_uri):
		self.interface_uri = interface_uri
		self.command = 'run'
		self.source = False
		self.before = self.not_before = None
		self.os = self.cpu = None
		self.message = None

	def parse_options(self, options):
		self.not_before = options.not_before
		self.before = options.before

		self.source = bool(options.source)
		self.message = options.message

		self.cpu = options.cpu
		self.os = options.os

		# (None becomes 'run', while '' becomes None)
		if options.command is None:
			if self.source:
				self.command = 'compile'
			else:
				self.command = 'run'
		else:
			self.command = options.command or None

	def parse_update_options(self, options):
		"""Update the settings based on the options (used for "0install update APP").
		@return: whether any settings were changed
		@rtype: bool
		@since: 1.9"""
		changed = False
		for key in ['not_before', 'before', 'message', 'cpu', 'os', 'command']:
			value = getattr(options, key)
			if value is not None:
				changed = changed or value != getattr(self, key)
				setattr(self, key, value)
		if options.source and not self.source:
			# (partly because it doesn't make much sense, and partly because you
			# can't undo it, as there's no --not-source option)
			from zeroinstall import SafeException
			raise SafeException("Can't update from binary to source type!")
		return changed

	def get_as_options(self):
		gui_args = []
		if self.not_before:
			gui_args.insert(0, self.not_before)
			gui_args.insert(0, '--not-before')
		if self.before:
			gui_args.insert(0, self.before)
			gui_args.insert(0, '--before')
		if self.source:
			gui_args.insert(0, '--source')
		if self.message:
			gui_args.insert(0, self.message)
			gui_args.insert(0, '--message')
		if self.cpu:
			gui_args.insert(0, self.cpu)
			gui_args.insert(0, '--cpu')
		if self.os:
			gui_args.insert(0, self.os)
			gui_args.insert(0, '--os')
		gui_args.append('--command')
		gui_args.append(self.command or '')

		return gui_args
