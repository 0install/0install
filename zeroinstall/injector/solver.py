"""
Chooses a set of components to make a running program.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os, locale
from logging import debug, warn, info

from zeroinstall.zerostore import BadDigest, NotStored

from zeroinstall.injector.arch import machine_groups
from zeroinstall.injector import model, sat, selections

def _get_cached(stores, impl):
	"""Check whether an implementation is available locally.
	@type impl: model.Implementation
	@rtype: bool
	"""
	if isinstance(impl, model.DistributionImplementation):
		return impl.installed
	if impl.local_path:
		return os.path.exists(impl.local_path)
	else:
		try:
			if not impl.digests:
				warn("No digests given for %s!", impl)
				return False
			path = stores.lookup_any(impl.digests)
			assert path
			return True
		except BadDigest:
			return False
		except NotStored:
			return False

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

def _get_command_name(runner):
	"""Returns the 'command' attribute of a <runner>, or 'run' if there isn't one."""
	return runner.qdom.attrs.get('command', 'run')

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
	__slots__ = ['_failure_reason', 'config', 'extra_restrictions', 'langs']

	@property
	def iface_cache(self):
		return self.config.iface_cache	# (deprecated; used by 0compile)

	"""Converts the problem to a set of pseudo-boolean constraints and uses a PB solver to solve them.
	@ivar langs: the preferred languages (e.g. ["es_ES", "en"]). Initialised to the current locale.
	@type langs: str"""
	def __init__(self, config, extra_restrictions = None):
		"""
		@param network_use: how much use to make of the network
		@type network_use: L{model.network_levels}
		@param config: policy preferences (e.g. stability), the iface_cache and the stores to use
		@type config: L{policy.Config}
		@param extra_restrictions: extra restrictions on the chosen implementations
		@type extra_restrictions: {L{model.Interface}: [L{model.Restriction}]}
		"""
		Solver.__init__(self)
		assert not isinstance(config, str), "API change!"
		self.config = config
		self.extra_restrictions = extra_restrictions or {}

		self.langs = [locale.getlocale()[0] or 'en']

	def compare(self, interface, b, a, arch):
		"""Compare a and b to see which would be chosen first.
		Does not consider whether the implementations are usable (check for that yourself first).
		@param interface: The interface we are trying to resolve, which may
		not be the interface of a or b if they are from feeds.
		@rtype: int"""

		# Languages we understand come first
		a_langs = (a.langs or 'en').split()
		b_langs = (b.langs or 'en').split()
		main_langs = set(l.split('_')[0] for l in self.langs)
		r = cmp(any(l.split('_')[0] in main_langs for l in a_langs),
			any(l.split('_')[0] in main_langs for l in b_langs))
		if r: return r

		a_stab = a.get_stability()
		b_stab = b.get_stability()

		# Preferred versions come first
		r = cmp(a_stab == model.preferred, b_stab == model.preferred)
		if r: return r

		stores = self.config.stores
		if self.config.network_use != model.network_full:
			r = cmp(_get_cached(stores, a), _get_cached(stores, b))
			if r: return r

		# Packages that require admin access to install come last
		r = cmp(b.requires_root_install, a.requires_root_install)
		if r: return r

		# Stability
		stab_policy = interface.stability_policy
		if not stab_policy:
			if self.config.help_with_testing: stab_policy = model.testing
			else: stab_policy = model.stable

		if a_stab >= stab_policy: a_stab = model.preferred
		if b_stab >= stab_policy: b_stab = model.preferred

		r = cmp(a_stab, b_stab)
		if r: return r

		# Newer versions come before older ones
		if a.id.startswith('package:') != b.id.startswith('package:'):
			# If one of packages is native, do not compare full versions since
			# it is useless to compare native and 0install version revisions
			r = cmp(a.version[0], b.version[0])
			if r: return r
			# Othewise, prefer native package
			return cmp(a.id.startswith('package:'), b.id.startswith('package:'))
		else:
			r = cmp(a.version, b.version)
			if r: return r

		# Get best OS
		r = cmp(arch.os_ranks.get(b.os, None),
			arch.os_ranks.get(a.os, None))
		if r: return r

		# Get best machine
		r = cmp(arch.machine_ranks.get(b.machine, None),
			arch.machine_ranks.get(a.machine, None))
		if r: return r

		# Slightly prefer languages specialised to our country
		r = cmp(any(l in self.langs for l in a_langs),
			any(l in self.langs for l in b_langs))
		if r: return r

		# Slightly prefer cached versions
		if self.config.network_use == model.network_full:
			r = cmp(_get_cached(stores, a), _get_cached(stores, b))
			if r: return r

		return cmp(a.id, b.id)

	def solve(self, root_interface, root_arch, command_name = 'run', closest_match = False):
		# closest_match is used internally. It adds a lowest-ranked
		# by valid implementation to every interface, so we can always
		# select something. Useful for diagnostics.

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

		# Add a clause so that if requiring_impl_var is True then an implementation
		# matching 'dependency' must also be selected.
		# Must have already done add_iface on dependency.interface.
		def find_dependency_candidates(requiring_impl_var, dependency):
			dep_iface = iface_cache.get_interface(dependency.interface)
			dep_union = [sat.neg(requiring_impl_var)]	# Either requiring_impl_var is False, or ...
			for candidate in impls_for_iface[dep_iface]:
				for r in dependency.restrictions:
					if candidate.__class__ is not _DummyImpl and not r.meets_restriction(candidate):
						#warn("%s rejected due to %s", candidate.get_version(), r)
						if candidate.version is not None:
							break
				else:
					c_var = impl_to_var.get(candidate, None)
					if c_var is not None:
						dep_union.append(c_var)
					# else we filtered that version out, so ignore it

			assert dep_union
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
			if (self.config.network_use == model.network_offline or not impl.download_sources) and not _get_cached(self.config.stores, impl):
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
				except Exception, ex:
					warn(_("Failed to load feed %(feed)s for %(interface)s: %(exception)s"), {'feed': f, 'interface': iface, 'exception': ex})
					#raise

			impls.sort(lambda a, b: self.compare(iface, a, b, arch))

			impls_for_iface[iface] = filtered_impls = []

			my_extra_restrictions = self.extra_restrictions.get(iface, [])

			if self.record_details:
				self.details[iface] = [(impl, get_unusable_reason(impl, my_extra_restrictions, arch)) for impl in impls]

			rank = 1
			var_names = []
			for impl in impls:
				if is_unusable(impl, my_extra_restrictions, arch):
					continue

				filtered_impls.append(impl)

				assert impl not in impl_to_var
				v = problem.add_variable(ImplInfo(iface, impl, arch))
				impl_to_var[impl] = v
				rank += 1
				var_names.append(v)

				if impl.machine and impl.machine != 'src':
					impls_for_machine_group[machine_groups.get(impl.machine, 0)].append(v)

				for d in deps_in_use(impl, arch):
					debug(_("Considering dependency %s"), d)

					add_iface(d.interface, arch.child_arch)

					# Must choose one version of d if impl is selected
					find_dependency_candidates(v, d)

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
			one can be selected."""
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

				runner = command.get_runner()
				for d in deps_in_use(command, arch):
					if d is runner:
						# With a <runner>, we depend on a command rather than on an
						# implementation. This allows us to support recursive <runner>s, etc.
						debug(_("Considering command runner %s"), d)
						runner_command_name = _get_command_name(d)
						runner_vars = add_command_iface(d.interface, arch.child_arch, runner_command_name)

						if closest_match:
							dummy_command = problem.add_variable(None)
							runner_vars.append(dummy_command)
						# If the parent command is chosen, one of the candidate runner commands
						# must be too. If there aren't any, then this command is unselectable.
						problem.add_clause([sat.neg(command_var)] + runner_vars)
						if runner_vars:
							# Can't select more than one of them.
							group_clause_for_command[(d.interface, runner_command_name)] = problem.at_most_one(runner_vars)
					else:
						debug(_("Considering command dependency %s"), d)
						add_iface(d.interface, arch.child_arch)

					# Must choose one version of d if impl is selected
					find_dependency_candidates(command_var, d)

			# Tell the user why we couldn't use this version
			if self.record_details:
				def new_reason(impl, old_reason):
					if command_name in impl.commands:
						return old_reason
					return old_reason or (_('No %s command') % command_name)
				self.details[iface] = [(impl, new_reason(impl, reason)) for (impl, reason) in self.details[iface]]

			return var_names

		if command_name is None:
			add_iface(root_interface, root_arch)
		else:
			commands = add_command_iface(root_interface, root_arch, command_name)
			if commands:
				problem.add_clause(commands)		# At least one
				group_clause_for_command[(root_interface, command_name)] = problem.at_most_one(commands)
			else:
				# (note: might be because we haven't cached it yet)
				info("No %s <command> in %s", command_name, root_interface)

				impls = impls_for_iface[iface_cache.get_interface(root_interface)]
				if impls == [] or (len(impls) == 1 and isinstance(impls[0], _DummyImpl)):
					# There were no candidates at all.
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
					if dep.qdom.name == 'runner':
						dep_lit = find_undecided_command(dep.interface, _get_command_name(dep))
					else:
						dep_lit = find_undecided(dep.interface)
					if dep_lit is not None:
						return dep_lit
				return None

			seen = set()
			def find_undecided(uri):
				if uri in seen:
					return	# Break cycles
				seen.add(uri)

				group = group_clause_for[uri]
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

			for uri, group in group_clause_for.iteritems():
				if group.current is not None:
					lit_info = problem.get_varinfo_for_lit(group.current).obj
					if lit_info.is_dummy:
						sels[lit_info.iface.uri] = None
					else:
						impl = lit_info.impl

						deps = self.requires[lit_info.iface] = []
						for dep in deps_in_use(lit_info.impl, lit_info.arch):
							deps.append(dep)
	
						sels[lit_info.iface.uri] = selections.ImplSelection(lit_info.iface.uri, impl, deps)

			def add_command(iface, name):
				sel = sels.get(iface, None)
				if sel:
					command = sel.impl.commands[name]
					self.selections.commands.append(command)
					runner = command.get_runner()
					if runner:
						add_command(runner.metadata['interface'], _get_command_name(runner))

			if command_name is not None:
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
