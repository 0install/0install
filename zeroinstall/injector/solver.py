"""
Chooses a set of components to make a running program.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import locale
from logging import debug, warn, info

from zeroinstall.injector.reader import MissingLocalFeed
from zeroinstall.injector.arch import machine_groups
from zeroinstall.injector import model, sat, selections

class CommandInfo:
	def __init__(self, name, command, impl, arch):
		self.name = name
		self.command = command
		self.impl = impl
		self.arch = arch

	def __repr__(self):
		name = "%s_%s_%s_%s" % (self.impl.feed.get_name(), self.impl.get_version(), self.impl.arch, self.name)
		return name.replace('-', '_').replace('.', '_')

class ImplInfo:
	is_dummy = False

	def __init__(self, iface, impl, arch, dummy = False):
		self.iface = iface
		self.impl = impl
		self.arch = arch
		if dummy:
			self.is_dummy = True

	def __repr__(self):
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
		return "dummy"

	def get_name(self):
		return "dummy"

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

class SATSolver(Solver):
	"""Converts the problem to a set of pseudo-boolean constraints and uses a PB solver to solve them.
	@ivar langs: the preferred languages (e.g. ["es_ES", "en"]). Initialised to the current locale.
	@type langs: str"""

	__slots__ = ['_failure_reason', 'config', 'extra_restrictions', '_lang_ranks', '_langs']

	@property
	def iface_cache(self):
		return self.config.iface_cache	# (deprecated; used by 0compile)

	def __init__(self, config, extra_restrictions = None):
		"""
		@param config: policy preferences (e.g. stability), the iface_cache and the stores to use
		@type config: L{policy.Config}
		@param extra_restrictions: extra restrictions on the chosen implementations
		@type extra_restrictions: {L{model.Interface}: [L{model.Restriction}]}
		"""
		Solver.__init__(self)
		assert not isinstance(config, str), "API change!"
		self.config = config
		self.extra_restrictions = extra_restrictions or {}

		# By default, prefer the current locale's language first and English second
		self.langs = [locale.getlocale()[0] or 'en', 'en']

	def set_langs(self, langs):
		"""Set the preferred languages.
		@param langs: languages (and regions), first choice first
		@type langs: [str]
		"""
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

		impl_to_var = {}	# Impl -> sat var
		self.feeds_used = set()
		self.requires = {}
		self.ready = False
		self.details = self.record_details and {}

		self.selections = None
		self._failure_reason = None

		ifaces_processed = set()

		impls_for_machine_group = {0 : []}		# Machine group (e.g. "64") to [impl] in that group
		for machine_group in machine_groups.values():
			impls_for_machine_group[machine_group] = []

		impls_for_iface = {}	# Iface -> [impl]

		group_clause_for = {}	# Iface URI -> AtMostOneClause | bool
		group_clause_for_command = {}	# (Iface URI, command name) -> AtMostOneClause | bool

		# Return the dependencies of impl that we should consider.
		# Skips dependencies if the use flag isn't what we need.
		# (note: impl may also be a model.Command)
		def deps_in_use(impl, arch):
			for dep in impl.requires:
				use = dep.metadata.get("use", None)
				if use not in arch.use:
					continue
				yield dep

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
			@type restrictions: [L{model.Restriction}]
			@return: The reason why this impl is unusable, or None if it's OK.
			@rtype: str
			@note: The restrictions are for the interface being requested, not the feed
			of the implementation; they may be different when feeds are being used."""
			for r in restrictions:
				if not r.meets_restriction(impl):
					return _("Incompatible with another selected implementation")
			stability = impl.get_stability()
			if stability <= model.buggy:
				return stability.name
			if (self.config.network_use == model.network_offline or not impl.download_sources) and not impl.is_available(self.config.stores):
				if not impl.download_sources:
					return _("No retrieval methods")
				return _("Not cached and we are off-line")
			if impl.os not in arch.os_ranks:
				return _("Unsupported OS")
			if impl.machine not in arch.machine_ranks:
				if impl.machine == 'src':
					return _("Source code")
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
					debug(_("Skipping '%(feed)s'; unsupported architecture %(os)s-%(machine)s"),
						{'feed': f, 'os': f.os, 'machine': f.machine})

		# If requiring_var is True then all of requirer's dependencies must be satisfied.
		# requirer can be a <command> or an <implementation>
		def process_dependencies(requiring_var, requirer, arch):
			for d in deps_in_use(requirer, arch):
				debug(_("Considering command dependency %s"), d)

				add_iface(d.interface, arch.child_arch)

				for c in d.get_required_commands():
					# We depend on a specific command within the implementation.
					command_vars = add_command_iface(d.interface, arch.child_arch, c)

					# If the parent command/impl is chosen, one of the candidate commands
					# must be too. If there aren't any, then this command is unselectable.
					problem.add_clause([sat.neg(requiring_var)] + command_vars)

				# Must choose one version of d if impl is selected
				find_dependency_candidates(requiring_var, d)

		def add_iface(uri, arch):
			"""Name implementations from feed and assert that only one can be selected."""
			if uri in ifaces_processed: return
			ifaces_processed.add(uri)

			iface = iface_cache.get_interface(uri)

			impls = []
			for f in usable_feeds(iface, arch):
				self.feeds_used.add(f)
				debug(_("Processing feed %s"), f)

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
					warn(_("Missing local feed; if it's no longer required, remove it with:") +
							'\n0install remove-feed ' + iface.uri + ' ' + f,
						{'feed': f, 'interface': iface, 'exception': ex})
				except Exception as ex:
					warn(_("Failed to load feed %(feed)s for %(interface)s: %(exception)s"), {'feed': f, 'interface': iface, 'exception': ex})
					#raise

			impls.sort(key = lambda impl: self.get_rating(iface, impl, arch), reverse = True)

			impls_for_iface[iface] = filtered_impls = []

			my_extra_restrictions = self.extra_restrictions.get(iface, [])

			if self.record_details:
				self.details[iface] = [(impl, get_unusable_reason(impl, my_extra_restrictions, arch)) for impl in impls]

			var_names = []
			for impl in impls:
				if is_unusable(impl, my_extra_restrictions, arch):
					continue

				filtered_impls.append(impl)

				assert impl not in impl_to_var
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
			if self.record_details:
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
				info("No %s <command> in %s", command_name, root_interface)

				impls = impls_for_iface[iface_cache.get_interface(root_interface)]
				if impls == [] or (len(impls) == 1 and isinstance(impls[0], _DummyImpl)):
					# There were no candidates at all.
					if self.config.network_use == model.network_offline:
						self._failure_reason = _("Interface '%s' has no usable implementations in the cache (and 0install is in off-line mode)") % root_interface
					else:
						self._failure_reason = _("Interface '%s' has no usable implementations") % root_interface
				else:
					# We had some candidates implementations, but none for the command we need
					self._failure_reason = _("Interface '%s' cannot be executed directly; it is just a library "
						    "to be used by other programs (or missing '%s' command)") % (root_interface, command_name)

				problem.impossible()

		# Require m<group> to be true if we select an implementation in that group
		m_groups = []
		for machine_group, impls in impls_for_machine_group.iteritems():
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

		def decide():
			"""Recurse through the current selections until we get to an interface with
			no chosen version, then tell the solver to try the best version from that."""

			def find_undecided_dep(impl_or_command, arch):
				# Check for undecided dependencies of impl_or_command
				for dep in deps_in_use(impl_or_command, arch):
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
			for group in group_clause_for.values() + group_clause_for_command.values() + [m_groups_clause]:
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

			sels = self.selections.selections

			commands_needed = []

			# Popular sels with the selected implementations.
			# Also, note down all the commands we need.
			for uri, group in group_clause_for.iteritems():
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
	
						sels[lit_info.iface.uri] = selections.ImplSelection(lit_info.iface.uri, impl, deps)

			# Now all all the commands in too.
			def add_command(iface, name):
				sel = sels.get(iface, None)
				if sel:
					command = sel.impl.commands[name]
					if name in sel._used_commands:
						return	# Already added
					sel._used_commands.add(name)

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

	def get_failure_reason(self):
		"""Return an exception explaining why the solve failed."""
		assert not self.ready

		if self._failure_reason:
			return model.SafeException(self._failure_reason)

		return model.SafeException(_("Can't find all required implementations:") + '\n' +
				'\n'.join(["- %s -> %s" % (iface, self.selections[iface])
					   for iface  in self.selections]))

DefaultSolver = SATSolver
