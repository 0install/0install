"""
Chooses a set of components to make a running program.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os, tempfile, subprocess, sys, locale
from logging import debug, warn, info

from zeroinstall.zerostore import BadDigest, NotStored

from zeroinstall.injector.arch import machine_groups
from zeroinstall.injector import model, sat

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
	@type selections: {L{model.Interface}: Implementation}
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

	def solve(self, root_interface, arch):
		"""Get the best implementation of root_interface and all of its dependencies.
		@param root_interface: the URI of the program to be solved
		@type root_interface: str
		@param arch: the desired target architecture
		@type arch: L{arch.Architecture}
		@postcondition: self.ready, self.selections and self.feeds_used are updated"""
		raise NotImplementedError("Abstract")

class SATSolver(Solver):
	"""Converts the problem to a set of pseudo-boolean constraints and uses a PB solver to solve them.
	@ivar langs: the preferred languages (e.g. ["es_ES", "en"]). Initialised to the current locale.
	@type langs: str"""
	def __init__(self, network_use, iface_cache, stores, extra_restrictions = None):
		"""
		@param network_use: how much use to make of the network
		@type network_use: L{model.network_levels}
		@param iface_cache: a cache of feeds containing information about available versions
		@type iface_cache: L{iface_cache.IfaceCache}
		@param stores: a cached of implementations (affects choice when offline or when minimising network use)
		@type stores: L{zerostore.Stores}
		@param extra_restrictions: extra restrictions on the chosen implementations
		@type extra_restrictions: {L{model.Interface}: [L{model.Restriction}]}
		"""
		Solver.__init__(self)
		self.network_use = network_use
		self.iface_cache = iface_cache
		self.stores = stores
		self.help_with_testing = False
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

		stores = self.stores
		if self.network_use != model.network_full:
			r = cmp(_get_cached(stores, a), _get_cached(stores, b))
			if r: return r

		# Packages that require admin access to install come last
		r = cmp(b.requires_root_install, a.requires_root_install)
		if r: return r

		# Stability
		stab_policy = interface.stability_policy
		if not stab_policy:
			if self.help_with_testing: stab_policy = model.testing
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
		if self.network_use == model.network_full:
			r = cmp(_get_cached(stores, a), _get_cached(stores, b))
			if r: return r

		return cmp(a.id, b.id)

	def solve(self, root_interface, root_arch, closest_match = False):
		# closest_match is used internally. It adds a lowest-ranked
		# by valid implementation to every interface, so we can always
		# select something. Useful for diagnostics.

		# TODO: We need some way to figure out which feeds to include.
		# Currently, we include any feed referenced from anywhere but
		# this is probably too much. We could insert a dummy optimial
		# implementation in stale/uncached feeds and see whether it
		# selects that.

		feeds_added = set()
		problem = sat.Solver()

		impl_to_var = {}	# Impl -> sat var
		self.feeds_used = set()
		self.requires = {}
		self.ready = False
		self.details = self.record_details and {}

		self.selections = None

		ifaces_processed = set()

		impls_for_machine_group = {0 : []}		# Machine group (e.g. "64") to [impl] in that group
		for machine_group in machine_groups.values():
			impls_for_machine_group[machine_group] = []

		impls_for_iface = {}	# Iface -> [impl]

		group_clause_for = {}	# Iface URI -> AtMostOneClause | bool

		def find_dependency_candidates(requiring_impl_var, dependency):
			dep_iface = self.iface_cache.get_interface(dependency.interface)
			dep_union = [sat.neg(requiring_impl_var)]
			for candidate in impls_for_iface[dep_iface]:
				for r in dependency.restrictions:
					if not r.meets_restriction(candidate):
						#warn("%s rejected due to %s", candidate.get_version(), r)
						if candidate.version is not None:
							break
						# else it's the dummy version that matches everything
				else:
					c_var = impl_to_var.get(candidate, None)
					if c_var is not None:
						dep_union.append(c_var)
					# else we filtered that version out, so ignore it
			if dep_union:
				problem.add_clause(dep_union)
			else:
				problem.assign(requiring_impl_var, 0)

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
			if (self.network_use == model.network_offline or not impl.download_sources) and not _get_cached(self.stores, impl):
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

			# Note: we only look one level deep here. Maybe we should recurse further?
			feeds = iface.extra_feeds
			main_feed = self.iface_cache.get_feed(iface.uri)
			if main_feed:
				feeds = feeds + main_feed.feeds

			for f in feeds:
				# Note: when searching for src, None is not in machine_ranks
				if f.os in arch.os_ranks and \
				   (f.machine is None or f.machine in arch.machine_ranks):
					yield f.uri
				else:
					debug(_("Skipping '%(feed)s'; unsupported architecture %(os)s-%(machine)s"),
						{'feed': f, 'os': f.os, 'machine': f.machine})

		def add_iface(uri, arch):
			"""Name implementations from feed, assign costs and assert that one one can be selected."""
			if uri in ifaces_processed: return
			ifaces_processed.add(uri)
			iface_name = 'i%d' % len(ifaces_processed)

			iface = self.iface_cache.get_interface(uri)

			impls = []
			for f in usable_feeds(iface, arch):
				self.feeds_used.add(f)
				debug(_("Processing feed %s"), f)

				try:
					feed = self.iface_cache.get_feed(f)
					if feed is None: continue
					if feed.name and iface.uri != feed.url and iface.uri not in feed.feed_for:
						info(_("Missing <feed-for> for '%(uri)s' in '%(feed)s'"), {'uri': iface.uri, 'feed': f})

					if feed.implementations:
						impls.extend(feed.implementations.values())
				except Exception, ex:
					warn(_("Failed to load feed %(feed)s for %(interface)s: %(exception)s"), {'feed': f, 'interface': iface, 'exception': ex})

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

				for d in impl.requires:
					debug(_("Considering dependency %s"), d)
					use = d.metadata.get("use", None)
					if use not in arch.use:
						info("Skipping dependency; use='%s' not in %s", use, arch.use)
						continue

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

		add_iface(root_interface, root_arch)

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

				for dep in lit_info.impl.requires:
					use = dep.metadata.get("use", None)
					if use not in lit_info.arch.use:
						continue
					dep_lit = find_undecided(dep.interface)
					if dep_lit is not None:
						return dep_lit

				# This whole sub-tree is decided
				return None

			best = find_undecided(root_interface)
			if best is not None:
				return best

			# If we're chosen everything we need, we can probably
			# set everything else to False.
			for group in group_clause_for.values() + [m_groups_clause]:
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
			self.solve(root_interface, root_arch, closest_match = True)
		else:
			self.ready = ready and not closest_match
			self.selections = {}

			for uri, group in group_clause_for.iteritems():
				if group.current is not None:
					lit_info = problem.get_varinfo_for_lit(group.current).obj
					if lit_info.is_dummy:
						self.selections[lit_info.iface] = None
					else:
						self.selections[lit_info.iface] = lit_info.impl
						deps = self.requires[lit_info.iface] = []
						for dep in lit_info.impl.requires:
							use = dep.metadata.get("use", None)
							if use not in lit_info.arch.use:
								continue
							deps.append(dep)


DefaultSolver = SATSolver
