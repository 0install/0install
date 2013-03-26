"""
Holds information about what the user asked for (which program, version constraints, etc).
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import SafeException

class Requirements(object):
	"""
	Holds information about what the user asked for (which program, version constraints, etc).
	"""

	# Note: apps.py serialises our __slots__
	__slots__ = [
		'interface_uri',
		'command',
		'source',
		'extra_restrictions',		# {str: str} (iface -> range)
		'os', 'cpu',
		'message',
	]

	def __init__(self, interface_uri):
		"""@type interface_uri: str"""
		self.interface_uri = interface_uri
		self.command = 'run'
		self.source = False
		self.os = self.cpu = None
		self.message = None
		self.extra_restrictions = {}

	def parse_options(self, options):
		self.extra_restrictions = self._handle_restrictions(options)

		for uri, expr in self.extra_restrictions.items():
			if not expr:
				raise SafeException("Missing version expression for {uri}".format(uri = uri))

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
		restriction_updates = self._handle_restrictions(options)

		changed = False
		for key in ['message', 'cpu', 'os', 'command']:
			value = getattr(options, key)
			if value is not None:
				changed = changed or value != getattr(self, key)
				setattr(self, key, value)

		for uri, expr in restriction_updates.items():
			old = self.extra_restrictions.get(uri, None)
			changed = expr != old
			if expr:
				self.extra_restrictions[uri] = expr
			elif uri in self.extra_restrictions:
				del self.extra_restrictions[uri]

		if options.source and not self.source:
			# (partly because it doesn't make much sense, and partly because you
			# can't undo it, as there's no --not-source option)
			raise SafeException("Can't update from binary to source type!")
		return changed

	def get_as_options(self):
		"""@rtype: [str]"""
		gui_args = []
		if self.extra_restrictions:
			# Currently, we only handle the case of restrictions on the root
			for uri, r in self.extra_restrictions.items():
				gui_args.insert(0, r)
				gui_args.insert(0, uri)
				gui_args.insert(0, '--version-for')
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

	def get_extra_restrictions(self, iface_cache):
		"""Create list of L{model.Restriction}s for each interface, based on these requirements.
		@type iface_cache: L{zeroinstall.injector.iface_cache.IfaceCache}
		@rtype: tuple"""
		from zeroinstall.injector import model

		return dict((iface_cache.get_interface(uri), [model.VersionExpressionRestriction(expr)])
				for uri, expr in self.extra_restrictions.items())

	def _handle_restrictions(self, options):
		"""Gets the list of restrictions specified by the user.
		Handles --before, --not-before, --version and --version-for options.
		If a mapping isn't present, then the user didn't specify a restriction.
		If an entry maps to None, the user wishes to remove the restriction."""
		version = options.version

		interface_uri = self.interface_uri

		# Convert old --before and --not_before to new --version-for
		if options.before is not None or options.not_before is not None:
			if version is not None:
				raise SafeException("Can't use --before or --not-before with --version")
			if options.before or options.not_before:
				version = (options.not_before or '') + '..'
				if options.before:
					version += '!' + options.before
			else:
				version = ''		# Reset

		restrictions = dict((uri, (expr or None)) for (uri, expr) in (options.version_for or []))

		# Convert the --version short-cut to --version-for
		if version is not None:
			if interface_uri in restrictions:
				raise SafeException("Can't use --version and --version-for to set {uri}".format(uri = interface_uri))
			restrictions[interface_uri] = version or None

		return restrictions

