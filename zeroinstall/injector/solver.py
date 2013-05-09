"""
Chooses a set of components to make a running program.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, logger
import locale
import collections

from zeroinstall.injector.reader import MissingLocalFeed
from zeroinstall.injector import model, sat, selections, arch, qdom

class CommandInfo(object):
	def __init__(self, name, command, impl, arch):
		"""@type name: str
		@type command: L{zeroinstall.injector.model.Command}
		@type impl: L{zeroinstall.injector.model.Implementation}
		@type arch: L{zeroinstall.injector.arch.Architecture}"""
		self.name = name
		self.command = command
		self.impl = impl
		self.arch = arch

	def __repr__(self):
		"""@rtype: str"""
		name = "%s_%s_%s_%s" % (self.impl.feed.get_name(), self.impl.get_version(), self.impl.arch, self.name)
		return name.replace('-', '_').replace('.', '_')

class ImplInfo(object):
	is_dummy = False

	def __init__(self, iface, impl, arch, dummy = False):
		"""@type iface: L{zeroinstall.injector.model.Interface}
		@type impl: L{zeroinstall.injector.model.Implementation} | L{_DummyImpl}
		@type arch: L{zeroinstall.injector.arch.Architecture}
		@type dummy: bool"""
		self.iface = iface
		self.impl = impl
		self.arch = arch
		if dummy:
			self.is_dummy = True

	def __repr__(self):
		"""@rtype: str"""
		name = "%s_%s_%s" % (self.impl.feed.get_name(), self.impl.get_version(), self.impl.arch)
		return name.replace('-', '_').replace('.', '_')

class _DummyImpl(object):
	requires = []
	version = None
	arch = None
	commands = {}

	def __repr__(self):
		return "dummy"

	feed = property(lambda self: self)

	def get_version(self):
		"""@rtype: str"""
		return "dummy"

	def get_name(self):
		"""@rtype: str"""
		return "dummy"

class _ForceImpl(model.Restriction):
	"""Used by L{SATSolver.justify_decision}."""

	reason = "Excluded by justify_decision"		# not shown to user

	def __init__(self, impl):
		"""@type impl: L{zeroinstall.injector.model.Implementation}"""
		self.impl = impl

	def meets_restriction(self, impl):
		"""@type impl: L{zeroinstall.injector.model.Implementation}
		@rtype: bool"""
		return impl.id == self.impl.id

	def __str__(self):
		"""@rtype: str"""
		return _("implementation {version} ({impl})").format(version = self.impl.get_version(), impl = self.impl.id)

class Solver(object):
	"""Chooses a set of implementations to satisfy the requirements of a program and its user.
	Typical use:
	 1. Create a Solver object and configure it
	 2. Call L{solve}.
	 3. If any of the returned feeds_used are stale or missing, you may like to start downloading them
	 4. If it is 'ready' then you can download and run the chosen versions.
	@ivar selections: the chosen implementation of each interface
	@type selections: L{selections.Selections}
	@ivar requires: the selected dependencies for each chosen version
	@type requires: {L{model.Interface}: [L{model.Dependency}]}
	@ivar feeds_used: the feeds which contributed to the choice in L{selections}
	@type feeds_used: set(str)
	@ivar record_details: whether to record information about unselected implementations
	@type record_details: {L{Interface}: [(L{Implementation}, str)]}
	@ivar details: extra information, if record_details mode was used
	@type details: {str: [(Implementation, comment)]}
	"""
	__slots__ = ['selections', 'requires', 'feeds_used', 'details', 'record_details', 'ready']

	def __init__(self):
		self.selections = self.requires = self.feeds_used = self.details = None
		self.record_details = False
		self.ready = False

	def solve_for(self, requirements):
		"""Solve for given requirements.
		@param requirements: the interface, architecture and command to solve for
		@type requirements: L{requirements.Requirements}
		@postcondition: self.ready, self.selections and self.feeds_used are updated
		@since: 1.8"""
		return self.solve(requirements.interface_uri, self.get_arch_for(requirements), requirements.command)

	def solve(self, root_interface, root_arch, command_name = 'run'):
		"""Get the best implementation of root_interface and all of its dependencies.
		@param root_interface: the URI of the program to be solved
		@type root_interface: str
		@param root_arch: the desired target architecture
		@type root_arch: L{arch.Architecture}
		@param command_name: which <command> element to select
		@type command_name: str | None
		@postcondition: self.ready, self.selections and self.feeds_used are updated"""
		raise NotImplementedError("Abstract")

	def get_arch_for(self, requirements, interface = None):
		"""Return the Architecture we would use when solving for this interface.
		Normally, this architecture is constructed from the OS and CPU type in the requirements,
		using the host platform's settings if these are not given.
		If interface is the root, then we wrap this in a SourceArchitecture if looking
		for source code and (for backwards compatibility) we enable use="testing" dependencies
		if the command is "test".
		@param requirements: the overall requirements for the solve
		@type requirements: L{requirements.Requirements}
		@param interface: the interface of interest
		@type interface: L{model.Interface}
		@return: the architecture that would be used
		@rtype: L{architecture.Architecture}
		@since: 1.9"""
		root_arch = arch.get_architecture(requirements.os, requirements.cpu)
		if interface is None or interface.uri == requirements.interface_uri:
			if requirements.source:
				root_arch = arch.SourceArchitecture(root_arch)
			if requirements.command == 'test':
				# This is for old feeds that have use='testing' instead of the newer
				# 'test' command for giving test-only dependencies.
				root_arch = arch.Architecture(root_arch.os_ranks, root_arch.machine_ranks)
				root_arch.use = frozenset([None, "testing"])
			return root_arch
		# Assume we use the same arch for all descendants
		return root_arch.child_arch

class SATSolver(Solver):
	"""Converts the problem to a set of pseudo-boolean constraints and uses a PB solver to solve them.
	@ivar langs: the preferred languages (e.g. ["es_ES", "en"]). Initialised to the current locale.
	@type langs: str"""

	__slots__ = ['_impls_for_iface', '_iface_to_vars', '_problem', 'config', 'extra_restrictions', '_lang_ranks', '_langs']

	@property
	def iface_cache(self):
		return self.config.iface_cache	# (deprecated; used by 0compile)

	def __init__(self, config, extra_restrictions = None):
		"""@param config: policy preferences (e.g. stability), the iface_cache and the stores to use
		@type config: L{policy.Config}
		@param extra_restrictions: extra restrictions on the chosen implementations
		@type extra_restrictions: {L{model.Interface}: [L{model.Restriction}]}"""
		Solver.__init__(self)
		assert not isinstance(config, str), "API change!"
		self.config = config
		self.extra_restrictions = extra_restrictions or {}

		# By default, prefer the current locale's language first and English second
		self.langs = [locale.getlocale()[0] or 'en', 'en']

	def set_langs(self, langs):
		"""Set the preferred languages.
		@param langs: languages (and regions), first choice first
		@type langs: [str]"""
		# _lang_ranks is a map from locale string to score (higher is better)
		_lang_ranks = {}
		score = 0
		i = len(langs)
		# (is there are duplicates, the first occurance takes precedence)
		while i > 0:
			i -= 1
			lang = langs[i].replace('_', '-')
			_lang_ranks[lang.split('-')[0]] = score
			_lang_ranks[lang] = score + 1
			score += 2
		self._langs = langs
		self._lang_ranks = _lang_ranks

	langs = property(lambda self: self._langs, set_langs)

	def get_rating(self, interface, impl, arch):
		"""@type interface: L{zeroinstall.injector.model.Interface}
		@type impl: L{zeroinstall.injector.model.Implementation}
		@type arch: L{zeroinstall.injector.arch.Architecture}
		@rtype: [object]"""
		impl_langs = (impl.langs or 'en').split()
		my_langs = self._lang_ranks

		stores = self.config.stores
		is_available = impl.is_available(stores)

		# Stability
		stab_policy = interface.stability_policy
		if not stab_policy:
			if self.config.help_with_testing: stab_policy = model.testing
			else: stab_policy = model.stable

		stability = impl.get_stability()
		if stability >= stab_policy:
			stability_limited = model.preferred
		else:
			stability_limited = stability

		# Note: this list must match _ranking_component_reason above
		return [
			# Languages we understand come first
			max(my_langs.get(l.split('-')[0], -1) for l in impl_langs),

			# Preferred versions come first
			stability == model.preferred,

			# Prefer available implementations next if we have limited network access
			self.config.network_use != model.network_full and is_available,

			# Packages that require admin access to install come last
			not impl.requires_root_install,

			# Prefer more stable versions, but treat everything over stab_policy the same
			# (so we prefer stable over testing if the policy is to prefer "stable", otherwise
			# we don't care)
			stability_limited,

			# Newer versions come before older ones (ignoring modifiers)
			impl.version[0],

			# Prefer native packages if the main part of the versions are the same
			impl.id.startswith('package:'),

			# Full version compare (after package check, since comparing modifiers between native and non-native
			# packages doesn't make sense).
			impl.version,

			# Get best OS
			-arch.os_ranks.get(impl.os, 999),

			# Get best machine
			-arch.machine_ranks.get(impl.machine, 999),

			# Slightly prefer languages specialised to our country
			# (we know a and b have the same base language at this point)
			max(my_langs.get(l, -1) for l in impl_langs),

			# Slightly prefer cached versions
			is_available,

			# Order by ID so the order isn't random
			impl.id
		]

	def solve(self, root_interface, root_arch, command_name = 'run', closest_match = False):
		"""@type root_interface: str
		@type root_arch: L{zeroinstall.injector.arch.Architecture}
		@type command_name: str | None
		@type closest_match: bool"""

		# closest_match is used internally. It adds a lowest-ranked
		# by valid implementation to every interface, so we can always
		# select something. Useful for diagnostics.

		# The basic plan is this:
		# 1. Scan the root interface and all dependencies recursively, building up a SAT problem.
		# 2. Solve the SAT problem. Whenever there are multiple options, try the most preferred one first.
		# 3. Create a Selections object from the results.
		#
		# All three involve recursively walking the tree in a similar way:
		# 1) we follow every dependency of every implementation (order not important)
		# 2) we follow every dependency of every selected implementation (better versions first)
		# 3) we follow every dependency of every selected implementation (order doesn't matter)
		#
		# In all cases, a dependency may be on an <implementation> or on a specific <command>.

		# TODO: We need some way to figure out which feeds to include.
		# Currently, we include any feed referenced from anywhere but
		# this is probably too much. We could insert a dummy optimial
		# implementation in stale/uncached feeds and see whether it
		# selects that.
		iface_cache = self.config.iface_cache

		problem = sat.SATProblem()

		# For each (interface, impl) we have a sat variable which, if true, means that we have selected
		# that impl as the implementation of the interface. We have to index on interface and impl (not
		# just impl) because the same feed can provide implementations for different interfaces. This
		# happens, for example, when an interface is renamed and the new interface imports the old feed:
		# old versions of a program are likely to use the old interface name while new ones use the new
		# name.
		iface_to_vars = collections.defaultdict(lambda: {})	# Iface -> (Impl -> sat var)

		self.feeds_used = set()
		self.requires = {}
		self.ready = False
		self.details = {} if self.record_details or closest_match else False

		self.selections = None

		# Only set if there is an error
		self._impls_for_iface = None
		self._iface_to_vars = None
		self._problem = None

		ifaces_processed = set()

		machine_groups = arch.machine_groups
		impls_for_machine_group = {0 : []}		# Machine group (e.g. "64") to [impl] in that group
		for machine_group in machine_groups.values():
			impls_for_machine_group[machine_group] = []

		impls_for_iface = {}	# Iface -> [impl]

		# For each interface, the group clause says we can't select two implementations of it at once.
		# We use this map at the end to find out what was actually selected.
		group_clause_for = {}	# Iface URI -> AtMostOneClause
		group_clause_for_command = {}	# (Iface URI, command name) -> AtMostOneClause | bool

		# Return the dependencies of impl that we should consider.
		# Skips dependencies if the use flag isn't what we need.
		# (note: impl may also be a model.Command)
		def deps_in_use(impl, arch):
			for dep in impl.requires:
				use = dep.metadata.get("use", None)
				if use not in arch.use:
					continue

				# Ignore dependency if 'os' attribute is present and doesn't match
				os = dep.metadata.get("os", None)
				if os and os not in arch.os_ranks:
					continue

				yield dep

		def clone_command_for(command, arch):
			# This is a bit messy. We need to make a copy of the command, without the
			# unnecessary <requires> elements.
			all_dep_elems = set(dep.qdom for dep in command.requires)
			required_dep_elems = set(dep.qdom for dep in deps_in_use(command, arch))
			if all_dep_elems == required_dep_elems:
				return command		# No change
			dep_elems_to_remove = all_dep_elems - required_dep_elems
			old_root = command.qdom
			new_qdom = qdom.Element(old_root.uri, old_root.name, old_root.attrs)
			new_qdom.childNodes = [node for node in command.qdom.childNodes if
					       node not in dep_elems_to_remove]
			return model.Command(new_qdom, command._local_dir)

		# Must have already done add_iface on dependency.interface.
		# If dependency is essential:
		#   Add a clause so that if requiring_impl_var is True then an implementation
		#   matching 'dependency' must also be selected.
		# If dependency is optional:
		#   Require that no incompatible version is selected.
		# This ignores any 'command' required. Handle that separately.
		def find_dependency_candidates(requiring_impl_var, dependency):
			def meets_restrictions(candidate):
				for r in dependency.restrictions:
					if not r.meets_restriction(candidate):
						#warn("%s rejected due to %s", candidate.get_version(), r)
						return False
				return True

			essential = dependency.importance == model.Dependency.Essential

			dep_iface = iface_cache.get_interface(dependency.interface)
			dep_union = [sat.neg(requiring_impl_var)]	# Either requiring_impl_var is False, or ...

			impl_to_var = iface_to_vars[dep_iface]		# Impl -> sat var

			for candidate in impls_for_iface[dep_iface]:
				if (candidate.__class__ is _DummyImpl) or meets_restrictions(candidate):
					if essential:
						c_var = impl_to_var.get(candidate, None)
						if c_var is not None:
							dep_union.append(c_var)
						# else we filtered that version out, so ignore it
				else:
					# Candidate doesn't meet our requirements
					# If the dependency is optional add a rule to make sure we don't
					# select this candidate.
					# (for essential dependencies this isn't necessary because we must
					# select a good version and we can't select two)
					if not essential:
						c_var = impl_to_var.get(candidate, None)
						if c_var is not None:
							problem.add_clause(dep_union + [sat.neg(c_var)])
						# else we filtered that version out, so ignore it

			if essential:
				problem.add_clause(dep_union)

		def is_unusable(impl, restrictions, arch):
			"""@return: whether this implementation is unusable.
			@rtype: bool"""
			return get_unusable_reason(impl, restrictions, arch) != None

		def get_unusable_reason(impl, restrictions, arch):
			"""
			@param impl: Implementation to test.
			@param restrictions: user-provided restrictions (extra_restrictions)
			@type restrictions: [L{model.Restriction}]
			@return: The reason why this impl is unusable, or None if it's OK.
			@rtype: str
			@note: The restrictions are for the interface being requested, not the feed
			of the implementation; they may be different when feeds are being used."""
			for r in restrictions:
				if not r.meets_restriction(impl):
					return r.reason
			stability = impl.get_stability()
			if stability <= model.buggy:
				return stability.name
			if (self.config.network_use == model.network_offline or not impl.download_sources) and not impl.is_available(self.config.stores):
				if not impl.download_sources:
					return _("No retrieval methods")
				for method in impl.download_sources:
					if not method.requires_network:
						break
				else:
					return _("Not cached and we are off-line")
			if impl.os not in arch.os_ranks:
				return _("Unsupported OS")
			if impl.machine not in arch.machine_ranks:
				if impl.machine == 'src':
					return _("Source code")
				elif 'src' in arch.machine_ranks:
					return _("Not source code")
				return _("Unsupported machine type")
			return None

		def usable_feeds(iface, arch):
			"""Return all feeds for iface that support arch.
			@rtype: generator(ZeroInstallFeed)"""
			yield iface.uri

			for f in iface_cache.get_feed_imports(iface):
				# Note: when searching for src, None is not in machine_ranks
				if f.os in arch.os_ranks and \
				   (f.machine is None or f.machine in arch.machine_ranks):
					yield f.uri
				else:
					logger.debug(_("Skipping '%(feed)s'; unsupported architecture %(os)s-%(machine)s"),
						{'feed': f, 'os': f.os, 'machine': f.machine})

		# If requiring_var is True then all of requirer's dependencies must be satisfied.
		# requirer can be a <command> or an <implementation>
		def process_dependencies(requiring_var, requirer, arch):
			for d in deps_in_use(requirer, arch):
				#logger.debug(_("Considering command dependency %s"), d)

				add_iface(d.interface, arch.child_arch)

				for c in d.get_required_commands():
					# We depend on a specific command within the implementation.
					command_vars = add_command_iface(d.interface, arch.child_arch, c)

					# If the parent command/impl is chosen, one of the candidate commands
					# must be too. If there aren't any, then this command is unselectable.
					problem.add_clause([sat.neg(requiring_var)] + command_vars)

				# Must choose one version of d if impl is selected
				find_dependency_candidates(requiring_var, d)

		replacement_for = {}		# Interface -> Replacement Interface

		def add_iface(uri, arch):
			"""Name implementations from feed and assert that only one can be selected."""
			if uri in ifaces_processed: return
			ifaces_processed.add(uri)

			iface = iface_cache.get_interface(uri)

			main_feed = iface_cache.get_feed(uri)
			if main_feed:
				replacement = main_feed.get_replaced_by()
				if replacement is not None:
					replacement_for[iface] = iface_cache.get_interface(replacement)

			impls = []
			for f in usable_feeds(iface, arch):
				self.feeds_used.add(f)
				logger.debug(_("Processing feed %s"), f)

				try:
					feed = iface_cache.get_feed(f)
					if feed is None: continue
					#if feed.name and iface.uri != feed.url and iface.uri not in feed.feed_for:
					#	info(_("Missing <feed-for> for '%(uri)s' in '%(feed)s'"), {'uri': iface.uri, 'feed': f})

					if feed.implementations:
						impls.extend(feed.implementations.values())

					distro_feed_url = feed.get_distro_feed()
					if distro_feed_url:
						self.feeds_used.add(distro_feed_url)
						distro_feed = iface_cache.get_feed(distro_feed_url)
						if distro_feed.implementations:
							impls.extend(distro_feed.implementations.values())
				except MissingLocalFeed as ex:
					logger.warning(_("Missing local feed; if it's no longer required, remove it with:") +
							'\n0install remove-feed ' + iface.uri + ' ' + f,
						{'feed': f, 'interface': iface, 'exception': ex})
				except model.SafeException as ex:
					logger.warning(_("Failed to load feed %(feed)s for %(interface)s: %(exception)s"), {'feed': f, 'interface': iface, 'exception': ex})
					#raise
				except Exception as ex:
					import logging
					logger.warning(_("Failed to load feed %(feed)s for %(interface)s: %(exception)s"), {'feed': f, 'interface': iface, 'exception': ex},
							exc_info = True if logger.isEnabledFor(logging.INFO) else None)

			impls.sort(key = lambda impl: self.get_rating(iface, impl, arch), reverse = True)

			impls_for_iface[iface] = filtered_impls = []

			my_extra_restrictions = self.extra_restrictions.get(iface, [])

			if self.details is not False:
				self.details[iface] = [(impl, get_unusable_reason(impl, my_extra_restrictions, arch)) for impl in impls]

			impl_to_var = iface_to_vars[iface]		# Impl -> sat var

			var_names = []
			for impl in impls:
				if is_unusable(impl, my_extra_restrictions, arch):
					continue

				filtered_impls.append(impl)

				assert impl not in impl_to_var, impl
				v = problem.add_variable(ImplInfo(iface, impl, arch))
				impl_to_var[impl] = v
				var_names.append(v)

				if impl.machine and impl.machine != 'src':
					impls_for_machine_group[machine_groups.get(impl.machine, 0)].append(v)

				process_dependencies(v, impl, arch)

			if closest_match:
				dummy_impl = _DummyImpl()
				dummy_var = problem.add_variable(ImplInfo(iface, dummy_impl, arch, dummy = True))
				var_names.append(dummy_var)
				impl_to_var[dummy_impl] = dummy_var
				filtered_impls.append(dummy_impl)

			# Only one implementation of this interface can be selected
			if uri == root_interface:
				if var_names:
					clause = problem.at_most_one(var_names)
					problem.add_clause(var_names)	# at least one
				else:
					problem.impossible()
					clause = False
			elif var_names:
				clause = problem.at_most_one(var_names)
			else:
				# Don't need to add to group_clause_for because we should
				# never get a possible selection involving this.
				return

			assert clause is not True
			assert clause is not None
			if clause is not False:
				group_clause_for[uri] = clause

		def add_command_iface(uri, arch, command_name):
			"""Add every <command> in interface 'uri' with this name.
			Each one depends on the corresponding implementation and only
			one can be selected. If closest_match is on, include a dummy
			command that can always be selected."""

			# Check whether we've already processed this (interface,command) pair
			existing = group_clause_for_command.get((uri, command_name), None)
			if existing is not None:
				return existing.lits

			# First ensure that the interface itself has been processed
			# We'll reuse the ordering of the implementations to order
			# the commands too.
			add_iface(uri, arch)

			iface = iface_cache.get_interface(uri)
			filtered_impls = impls_for_iface[iface]
			impl_to_var = iface_to_vars[iface]		# Impl -> sat var

			var_names = []
			for impl in filtered_impls:
				command = impl.commands.get(command_name, None)
				if not command:
					if not isinstance(impl, _DummyImpl):
						# Mark implementation as unselectable
						problem.add_clause([sat.neg(impl_to_var[impl])])
					continue

				# We have a candidate <command>. Require that if it's selected
				# then we select the corresponding <implementation> too.
				command_var = problem.add_variable(CommandInfo(command_name, command, impl, arch))
				problem.add_clause([impl_to_var[impl], sat.neg(command_var)])

				var_names.append(command_var)

				process_dependencies(command_var, command, arch)

			# Tell the user why we couldn't use this version
			if self.details is not False:
				def new_reason(impl, old_reason):
					if command_name in impl.commands:
						return old_reason
					return old_reason or (_('No %s command') % command_name)
				self.details[iface] = [(impl, new_reason(impl, reason)) for (impl, reason) in self.details[iface]]

			if closest_match:
				dummy_command = problem.add_variable(None)
				var_names.append(dummy_command)

			if var_names:
				# Can't select more than one of them.
				assert (uri, command_name) not in group_clause_for_command
				group_clause_for_command[(uri, command_name)] = problem.at_most_one(var_names)

			return var_names

		if command_name is None:
			add_iface(root_interface, root_arch)
		else:
			commands = add_command_iface(root_interface, root_arch, command_name)
			if len(commands) > int(closest_match):
				# (we have at least one non-dummy command)
				problem.add_clause(commands)		# At least one
			else:
				# (note: might be because we haven't cached it yet)
				logger.info("No %s <command> in %s", command_name, root_interface)

				problem.impossible()

		# Require m<group> to be true if we select an implementation in that group
		m_groups = []
		for machine_group, impls in impls_for_machine_group.items():
			m_group = 'm%d' % machine_group
			group_var = problem.add_variable(m_group)
			if impls:
				for impl in impls:
					problem.add_clause([group_var, sat.neg(impl)])
			m_groups.append(group_var)
		if m_groups:
			m_groups_clause = problem.at_most_one(m_groups)
		else:
			m_groups_clause = None

		# Can't select an implementation of an interface and of its replacement
		for original, replacement in replacement_for.items():
			if original == replacement:
				logger.warning("Interface %s replaced-by itself!", original)
				continue
			rep_impls = iface_to_vars.get(replacement, None)
			if rep_impls is None:
				# We didn't even look at the replacement interface, so no risk here
				continue
			# Must select one implementation out of all candidates from both interface.
			# Dummy implementations don't conflict, though.
			all_impls = []
			for impl, var in rep_impls.items():
				if not isinstance(impl, _DummyImpl):
					all_impls.append(var)
			for impl, var in iface_to_vars[original].items():
				if not isinstance(impl, _DummyImpl):
					all_impls.append(var)
			if all_impls:
				problem.at_most_one(all_impls)
			# else: neither feed has any usable impls anyway

		def decide():
			"""This is called by the SAT solver when it cannot simplify the problem further.
			Our job is to find the most-optimal next selection to try.
			Recurse through the current selections until we get to an interface with
			no chosen version, then tell the solver to try the best version from that."""

			def find_undecided_dep(impl_or_command, arch):
				# Check for undecided dependencies of impl_or_command
				for dep in deps_in_use(impl_or_command, arch):
					# Restrictions don't express that we do or don't want the
					# dependency, so skip them here.
					if dep.importance == model.Dependency.Restricts: continue

					for c in dep.get_required_commands():
						dep_lit = find_undecided_command(dep.interface, c)
						if dep_lit is not None:
							return dep_lit
					dep_lit = find_undecided(dep.interface)
					if dep_lit is not None:
						return dep_lit
				return None

			seen = set()
			def find_undecided(uri):
				if uri in seen:
					return	# Break cycles
				seen.add(uri)

				group = group_clause_for.get(uri, None)

				if group is None:
					# (can be None if the selected impl has an optional dependency on 
					# a feed with no implementations)
					return

				#print "Group for %s = %s" % (uri, group)
				lit = group.current
				if lit is None:
					return group.best_undecided()
				# else there was only one choice anyway

				# Check for undecided dependencies
				lit_info = problem.get_varinfo_for_lit(lit).obj
				return find_undecided_dep(lit_info.impl, lit_info.arch)

			def find_undecided_command(uri, name):
				if name is None: return find_undecided(uri)

				group = group_clause_for_command[(uri, name)]
				lit = group.current
				if lit is None:
					return group.best_undecided()
				# else we've already chosen which <command> to use

				# Check for undecided command-specific dependencies, and then for
				# implementation dependencies.
				lit_info = problem.get_varinfo_for_lit(lit).obj
				if lit_info is None:
					assert closest_match
					return None	# (a dummy command added for better diagnostics; has no dependencies)
				return find_undecided_dep(lit_info.command, lit_info.arch) or \
				       find_undecided_dep(lit_info.impl, lit_info.arch)

			best = find_undecided_command(root_interface, command_name)
			if best is not None:
				return best

			# If we're chosen everything we need, we can probably
			# set everything else to False.
			for group in list(group_clause_for.values()) + list(group_clause_for_command.values()) + [m_groups_clause]:
				if group.current is None:
					best = group.best_undecided()
					if best is not None:
						return sat.neg(best)

			return None			# Failed to find any valid combination

		ready = problem.run_solver(decide) is True

		if not ready and not closest_match:
			# We failed while trying to do a real solve.
			# Try a closest match solve to get a better
			# error report for the user.
			self.solve(root_interface, root_arch, command_name = command_name, closest_match = True)
		else:
			self.ready = ready and not closest_match
			self.selections = selections.Selections(None)
			self.selections.interface = root_interface

			if not self.ready:
				# Store some things useful for get_failure_reason()
				self._impls_for_iface = impls_for_iface
				self._iface_to_vars = iface_to_vars
				self._problem = problem

			sels = self.selections.selections

			commands_needed = []

			# Populate sels with the selected implementations.
			# Also, note down all the commands we need.
			for uri, group in group_clause_for.items():
				if group.current is not None:
					lit_info = problem.get_varinfo_for_lit(group.current).obj
					if lit_info.is_dummy:
						sels[lit_info.iface.uri] = None
					else:
						# We selected an implementation for interface 'uri'
						impl = lit_info.impl

						for b in impl.bindings:
							c = b.command
							if c is not None:
								commands.append((uri, c))

						deps = self.requires[lit_info.iface] = []
						for dep in deps_in_use(lit_info.impl, lit_info.arch):
							deps.append(dep)
							for c in dep.get_required_commands():
								commands_needed.append((dep.interface, c))
	
						sel = sels[lit_info.iface.uri] = selections.ImplSelection(lit_info.iface.uri, impl, deps)
						sel.__arch = lit_info.arch

			# Now all all the commands in too.
			def add_command(iface, name):
				sel = sels.get(iface, None)
				if sel:
					command = sel.impl.commands[name]
					if name in sel._used_commands:
						return	# Already added
					sel._used_commands[name] = clone_command_for(command, sel.__arch)

					for dep in command.requires:
						for dep_command_name in dep.get_required_commands():
							add_command(dep.interface, dep_command_name)

					# A <command> can depend on another <command> in the same interface
					# (e.g. the tests depending on the main program)
					for b in command.bindings:
						c = b.command
						if c is not None:
							add_command(iface, c)

			for iface, command in commands_needed:
				add_command(iface, command)

			if command_name is not None:
				self.selections.command = command_name
				add_command(root_interface, command_name)

			if root_interface not in sels:
				sels[root_interface] = None		# Useful for get_failure_reason()

	def get_failure_reason(self):
		"""Return an exception explaining why the solve failed.
		@rtype: L{zeroinstall.SafeException}"""
		assert not self.ready

		sels = self.selections.selections

		iface_cache = self.config.iface_cache

		problem = self._problem
		impls_for_iface = self._impls_for_iface
		assert impls_for_iface

		def show(iface_uri):
			# Find all restrictions that are in play and affect this interface
			sel = sels[iface_uri]
			if sel:
				msg = '{version} ({impl})'.format(version = sel.version, impl = sel.id)
			else:
				msg = "(problem)"

			iface = iface_cache.get_interface(iface_uri)
		
			impls = impls_for_iface[iface_cache.get_interface(iface_uri)]
			impls = [i for i in impls if not isinstance(i, _DummyImpl)]

			def apply_restrictions(impls, restrictions):
				for r in restrictions:
					impls = [i for i in impls if r.meets_restriction(i)]
				return impls

			# orig_impls is all the implementations passed to the SAT solver (these are the
			# ones with a compatible OS, CPU, etc). They are sorted most desirable first.
			orig_impls = impls

			def get_machine_group(impl):
				machine = impl.machine
				if machine and machine != 'src':
					return arch.machine_groups.get(machine, 0)
				return None

			example_machine_impl = None		# An example chosen impl with a machine type

			our_feed = iface_cache.get_feed(iface_uri)
			our_replacement = our_feed.get_replaced_by() if our_feed else None

			# For each selected implementation...
			for other_uri, other_sel in sels.items():
				# Check for interface-level conflicts
				other_iface = iface_cache.get_feed(other_uri)
				if other_iface and other_iface.get_replaced_by() == iface_uri:
					msg += "\n    " + _("Replaces (and therefore conflicts with) {old}").format(old = other_uri)
					if other_sel:
						impls = []

				if our_replacement == other_uri:
					msg += "\n    " + _("Replaced by (and therefore conflicts with) {old}").format(old = other_uri)
					if other_sel:
						impls = []

				# Otherwise, if we didn't select an implementation then that can't be causing a problem
				if not other_sel: continue

				if example_machine_impl is None:
					required_machine_group = get_machine_group(other_sel.impl)
					if required_machine_group is not None:
						example_machine_impl = other_sel.impl

				for dep in other_sel.impl.requires:
					if not isinstance(dep, model.InterfaceRestriction): continue
					# If it depends on us and has restrictions...
					if dep.interface == iface_uri:
						if dep.restrictions:
							# Report the restriction
							msg += "\n    " + _("{iface} {version} requires {reqs}").format(
									iface = other_uri,
									version = other_sel.version,
									reqs = ', '.join(str(r) for r in dep.restrictions))

							# Remove implementations incompatible with the other selections
							impls = apply_restrictions(impls, dep.restrictions)
						for command in dep.get_required_commands():
							msg += "\n    " + _("{iface} {version} requires '{command}' command").format(
									iface = other_uri,
									version = other_sel.version,
									command = command)

			# Check for user-supplied restrictions
			user = self.extra_restrictions.get(iface, [])
			if user:
				msg += "\n    " + _("User requested {reqs}").format(
								reqs = ', '.join(str(r) for r in user))
				impls = apply_restrictions(impls, user)

			if sel is None:
				# Report on available implementations
				# all_impls = all known implementations
				# orig_impls = impls valid on their own (e.g. incompatible archs removed)
				# impls = impls compatible with other selections used in this example
				all_impls = self.details.get(iface, {})
				if not impls:
					if not all_impls:
						msg += "\n    " + _("No known implementations at all")
					else:
						if orig_impls:
							msg += "\n    " + _("No usable implementations satisfy the restrictions:")
						else:
							# No implementations were passed to the solver.
							msg += "\n    " + _("No usable implementations:")
						for i, reason in all_impls[:5]:
							msg += "\n      {impl} ({version}): {reason}".format(impl = i,
									version = i.get_version(),
									reason = reason or _('incompatible with restrictions'))
						if len(all_impls) > 5:
							msg += "\n      ..."
				else:
					# Might still be unusable e.g. if missing a required command. Show reasons, if any.
					shown = 0
					candidate_impls = set(impls)
					for i, reason in all_impls:
						if reason is _ForceImpl.reason:
							# We're doing a justify_decision, and this wasn't the one the user specified
							continue

						if i not in candidate_impls:
							# Skip, as hopefully obvious from above restrictions why not chosen
							continue

						if reason is None and example_machine_impl:
							# Could be an architecture problem
							this_machine_group = get_machine_group(i)
							if this_machine_group is not None and this_machine_group != required_machine_group:
								reason = _("Can't use {this_arch} with selection of {other_name} ({other_arch})").format(
										this_arch = i.machine,
										other_name = example_machine_impl.feed.get_name(),
										other_arch = example_machine_impl.machine)

						if reason is None:
							# Check if our requirements conflict with an existing selection
							for dep in i.requires:
								if not isinstance(dep, model.InterfaceRestriction): continue
								dep_selection = sels.get(dep.interface)
								if dep_selection is not None:
									for r in dep.restrictions:
										if not r.meets_restriction(dep_selection.impl):
											reason = _("requires {iface} {reqs}").format(
													iface = dep.interface,
													reqs = ', '.join(str(r) for r in dep.restrictions))
											break

						if reason is None:
							var = self._iface_to_vars[iface].get(i, None)
							if var is None:
								reason = "BUG: no var for impl!"
							else:
								varinfo = problem.get_varinfo_for_lit(var)
								reason = "Hard to explain. Internal reason: {reason} => {assignment}".format(
									reason = varinfo.reason,
									assignment = varinfo)

						if reason is not _ForceImpl.reason:
							if shown >= 5:
								msg += "\n      ..."
								break
							if shown == 0:
								msg += "\n    " + _("Rejected candidates:")
							msg += "\n      {impl}: {reason}".format(impl = i, reason = reason)
							shown += 1

			return msg

		msg = _("Can't find all required implementations:") + '\n' + \
				'\n'.join(["- %s -> %s" % (iface, show(iface)) for iface in sorted(sels)])

		if self.config.network_use == model.network_offline:
			msg += "\nNote: 0install is in off-line mode"

		return model.SafeException(msg)

	def justify_decision(self, requirements, iface, impl):
		"""Run a solve with impl_id forced to be selected, and explain why it wasn't (or was)
		selected in the normal case.
		@type requirements: L{zeroinstall.injector.requirements.Requirements}
		@type iface: L{zeroinstall.injector.model.Interface}
		@type impl: L{zeroinstall.injector.model.Implementation}
		@rtype: str"""
		assert isinstance(iface, model.Interface), iface

		restrictions = self.extra_restrictions.copy()
		restrictions[iface] = restrictions.get(iface, []) + [_ForceImpl(impl)]
		s = SATSolver(self.config, restrictions)
		s.record_details = True
		s.solve_for(requirements)

		wanted = "{iface} {version}".format(iface = iface.get_name(), version = impl.get_version())

		# Could a selection involving impl even be valid?
		if not s.ready or iface.uri not in s.selections.selections:
			reasons = s.details.get(iface, [])
			for (rid, rstr) in reasons:
				if rid.id == impl.id and rstr is not None:
					return _("{wanted} cannot be used (regardless of other components): {reason}").format(
							wanted = wanted,
							reason = rstr)

			if not s.ready:
				return _("There is no possible selection using {wanted}.\n{reason}").format(
					wanted = wanted,
					reason = s.get_failure_reason())

		actual_selection = self.selections.get(iface, None)
		if actual_selection is not None:
			# Was impl actually selected anyway?
			if actual_selection.id == impl.id:
				return _("{wanted} was selected as the preferred version.").format(wanted = wanted)

			# Was impl ranked below the selected version?
			iface_arch = arch.get_architecture(requirements.os, requirements.cpu)
			if requirements.source and iface.uri == requirements.interface_uri:
				iface_arch = arch.SourceArchitecture(iface_arch)
			wanted_rating = self.get_rating(iface, impl, arch)
			selected_rating = self.get_rating(iface, actual_selection, arch)

			if wanted_rating < selected_rating:
				_ranking_component_reason = [
					_("natural languages we understand are preferred"),
					_("preferred versions come first"),
					_("locally-available versions are preferred when network use is limited"),
					_("packages that don't require admin access to install are preferred"),
					_("more stable versions preferred"),
					_("newer versions are preferred"),
					_("native packages are preferred"),
					_("newer versions are preferred"),
					_("better OS match"),
					_("better CPU match"),
					_("better locale match"),
					_("is locally available"),
					_("better ID (tie-breaker)"),
				]

				actual = actual_selection.get_version()
				if impl.get_version() == actual:
					def detail(i):
						if len(i.id) < 18:
							return " (" + i.id + ")"
						else:
							return " (" + i.id[:16] + "...)"

					wanted += detail(impl)
					actual += detail(actual_selection)

				for i in range(len(wanted_rating)):
					if wanted_rating[i] < selected_rating[i]:
						return _("{wanted} is ranked lower than {actual}: {why}").format(
								wanted = wanted,
								actual = actual,
								why = _ranking_component_reason[i])

		used_impl = iface.uri in s.selections.selections

		# Impl is selectable and ranked higher than the selected version. Selecting it would cause
		# a problem elsewhere.
		changes = []
		for old_iface, old_sel in self.selections.selections.items():
			if old_iface == iface.uri and used_impl: continue
			new_sel = s.selections.selections.get(old_iface, None)
			if new_sel is None:
				changes.append(_("{interface}: no longer used").format(interface = old_iface))
			elif old_sel.version != new_sel.version:
				changes.append(_("{interface}: {old} to {new}").format(interface = old_iface, old = old_sel.version, new = new_sel.version))
			elif old_sel.id != new_sel.id:
				changes.append(_("{interface}: {old} to {new}").format(interface = old_iface, old = old_sel.id, new = new_sel.id))

		if changes:
			changes_text = '\n\n' + _('The changes would be:') + '\n\n' + '\n'.join(changes)
		else:
			changes_text = ''

		if used_impl:
			return _("{wanted} is selectable, but using it would produce a less optimal solution overall.").format(wanted = wanted) + changes_text
		else:
			return _("If {wanted} were the only option, the best available solution wouldn't use it.").format(wanted = wanted) + changes_text

DefaultSolver = SATSolver
