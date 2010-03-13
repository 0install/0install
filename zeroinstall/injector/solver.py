"""
Chooses a set of components to make a running program.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os, tempfile, subprocess
from logging import debug, warn, info

from zeroinstall.zerostore import BadDigest, NotStored

from zeroinstall.injector.arch import machine_groups
from zeroinstall.injector import model

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

class PBSolver(Solver):
	"""Converts the problem to a set of pseudo-boolean constraints and uses a PB solver to solve them."""
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

	def solve(self, root_interface, root_arch):
		# TODO: We need some way to figure out which feeds to include.
		# Currently, we include any feed referenced from anywhere but
		# this is probably too much. We could insert a dummy optimial
		# implementation in stale/uncached feeds and see whether it
		# selects that.

		feeds_added = set()
		problem = []

		# 10 points cost for selecting 32-bit binaries (when we could have
		# chosen 64-bits).
		costs = {"m0": 10}	# f1_0 -> 2

		feed_names = {}	# Feed -> "f1"
		impl_names = {}	# Impl -> "f1_0"
		self.feeds_used = set()
		name_to_impl = {}	# "f1_0" -> (Iface, Impl)
		self.selections = {}
		self.requires = {}
		self.ready = False
		self.details = self.record_details and {}

		comment_problem = False	# debugging only

		def feed_name(feed):
			name = feed_names.get(feed, None)
			if name: return name
			feed_names[feed] = name = "f%d" % (len(feed_names))
			if comment_problem:
				problem.append("* feed %s is now known as %s" % (feed, name))
			self.feeds_used.add(feed.url)
			return name

		def get_cached(impl):
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
					path = self.stores.lookup_any(impl.digests)
					assert path
					return True
				except BadDigest:
					return False
				except NotStored:
					return False

		ifaces_processed = set()

		impls_for_machine_group = {0 : []}		# Machine group (e.g. "64") to [impl] in that group
		for machine_group in machine_groups.values():
			impls_for_machine_group[machine_group] = []

		def find_dependency_candidates(requiring_impl, dependency):
			dep_iface = self.iface_cache.get_interface(dependency.interface)
			# TODO: version restrictions
			dep_exprs = []
			for candidate in dep_iface.implementations.values():
				c_name = impl_names.get(candidate, None)
				if c_name:
					dep_exprs.append("1 * " + c_name)
				# else we filtered that version out, so ignore it
			if comment_problem:
				problem.append("* %s requires %s" % (requiring_impl, dependency))
			if dep_exprs:
				problem.append(("-1 * " + requiring_impl) + " + " + " + ".join(dep_exprs) + " >= 0")
			else:
				problem.append("1 * " + requiring_impl + " = 0")

		def is_unusable(impl, arch):
			"""@return: whether this implementation is unusable.
			@rtype: bool"""
			return get_unusable_reason(impl, arch) != None

		def get_unusable_reason(impl, arch):
			"""
			@param impl: Implementation to test.
			@return: The reason why this impl is unusable, or None if it's OK.
			@rtype: str"""
			stability = impl.get_stability()
			if stability <= model.buggy:
				return stability.name
			if self.network_use == model.network_offline and not get_cached(impl):
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

			for f in iface.feeds:
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

			iface = self.iface_cache.get_interface(uri)

			impls = []
			for f in usable_feeds(iface, arch):
				self.feeds_used.add(f)
				debug(_("Processing feed %s"), f)

				try:
					feed = self.iface_cache.get_interface(f)._main_feed
					if not feed.last_modified: continue	# DummyFeed
					if feed.name and iface.uri != feed.url and iface.uri not in feed.feed_for:
						info(_("Missing <feed-for> for '%(uri)s' in '%(feed)s'"), {'uri': iface.uri, 'feed': f})

					if feed.implementations:
						impls.extend(feed.implementations.values())
				except Exception, ex:
					warn(_("Failed to load feed %(feed)s for %(interface)s: %(exception)s"), {'feed': f, 'interface': iface, 'exception': str(ex)})

			impls.sort()

			if self.record_details:
				self.details[iface] = [(impl, get_unusable_reason(impl, arch)) for impl in impls]

			rank = 1
			exprs = []
			for impl in impls:
				if is_unusable(impl, arch):
					continue

				name = feed_name(impl.feed) + "_" + str(rank)
				assert impl not in impl_names
				impl_names[impl] = name
				name_to_impl[name] = (iface, impl)
				costs[name] = rank
				rank += 1
				exprs.append('1 * ' + name)

				if impl.machine and impl.machine != 'src':
					impls_for_machine_group[machine_groups.get(impl.machine, 0)].append(name)

				self.requires[iface] = selected_requires = []
				for d in impl.requires:
					debug(_("Considering dependency %s"), d)
					use = d.metadata.get("use", None)
					if use not in arch.use:
						info("Skipping dependency; use='%s' not in %s", use, arch.use)
						continue

					add_iface(d.interface, arch.child_arch)
					selected_requires.append(d)

					# Must choose one version of d if impl is selected
					find_dependency_candidates(name, d)

			# Only one implementation of this interface can be selected
			if uri == root_interface:
				if comment_problem:
					problem.append("* select 1 of root " + uri)
				if exprs:
					problem.append(" + ".join(exprs) + " = 1")
				else:
					problem.append("1 * impossible = 2")
			elif exprs:
				if comment_problem:
					problem.append("* select at most 1 of " + uri)
				problem.append(" + ".join(exprs) + " <= 1")

		add_iface(root_interface, root_arch)

		# Require m<group> to be true if we select an implementation in that group
		exprs = []
		for machine_group, impls in impls_for_machine_group.iteritems():
			if impls:
				if comment_problem:
					problem.append("* define machine group %d" % machine_group)
				problem.append(' + '.join("1 * " + impl for impl in impls) + ' - %d * m%d <= 0' % (len(impls), machine_group))
			exprs.append('1 * m%d' % machine_group)
		if exprs:
			if comment_problem:
				problem.append("* select implementations from at most one machine group")
			problem.append(' + '.join(exprs) + ' <= 1')

		prog_fd, tmp_name = tempfile.mkstemp(prefix = '0launch')
		try:
			stream = os.fdopen(prog_fd, 'wb')
			try:
				print >>stream, "min:", ' + '.join("%d * %s" % (cost, name) for name, cost in costs.iteritems()) + ";"
				for line in problem:
					print >>stream, line, ";"
			finally:
				stream.close()
			child = subprocess.Popen(['minisat+', tmp_name, '-v0'], stdout = subprocess.PIPE)
			data, used = child.communicate()
			for line in data.split('\n'):
				if line.startswith('v '):
					bits = line.split(' ')[1:]
					for bit in bits:
						if bit.startswith('f'):
							iface, impl = name_to_impl[bit]
							if comment_problem:
								print "%s (%s)" % (iface, impl.get_version())
							self.selections[iface] = impl
				elif line == "s OPTIMUM FOUND":
					if comment_problem:
						print line
					self.ready = True
				elif line == "s UNSATISFIABLE":
					pass
				elif line:
					warn("Unexpected output from solver: %s", line)
		finally:
			if comment_problem:
				print tmp_name
			else:
				os.unlink(tmp_name)

DefaultSolver = PBSolver

class StupidSolver(Solver):
	"""The standard (rather naive) Zero Install solver."""
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

	def solve(self, root_interface, arch):
		self.selections = {}
		self.requires = {}
		self.feeds_used = set()
		self.details = self.record_details and {}
		self._machine_group = None

		restrictions = {}
		debug(_("Solve! root = %s"), root_interface)
		def process(dep, arch):
			ready = True
			iface = self.iface_cache.get_interface(dep.interface)

			if iface in self.selections:
				debug("Interface requested twice; skipping second %s", iface)
				if dep.restrictions:
					warn("Interface requested twice; I've already chosen an implementation "
						"of '%s' but there are more restrictions! Ignoring the second set.", iface)
				return ready
			self.selections[iface] = None	# Avoid cycles
			self.requires[iface] = selected_requires = []

			assert iface not in restrictions
			restrictions[iface] = dep.restrictions

			impl = get_best_implementation(iface, arch)
			if impl:
				debug(_("Will use implementation %(implementation)s (version %(version)s)"), {'implementation': impl, 'version': impl.get_version()})
				self.selections[iface] = impl
				if self._machine_group is None and impl.machine and impl.machine != 'src':
					self._machine_group = machine_groups.get(impl.machine, 0)
					debug(_("Now restricted to architecture group %s"), self._machine_group)
				for d in impl.requires:
					debug(_("Considering dependency %s"), d)
					use = d.metadata.get("use", None)
					if use not in arch.use:
						info("Skipping dependency; use='%s' not in %s", use, arch.use)
						continue
					if not process(d, arch.child_arch):
						ready = False
					selected_requires.append(d)
			else:
				debug(_("No implementation chould be chosen yet"));
				ready = False

			return ready

		def get_best_implementation(iface, arch):
			debug(_("get_best_implementation(%(interface)s), with feeds: %(feeds)s"), {'interface': iface, 'feeds': iface.feeds})

			iface_restrictions = restrictions.get(iface, [])
			extra_restrictions = self.extra_restrictions.get(iface, None)
			if extra_restrictions:
				# Don't modify original
				iface_restrictions = iface_restrictions + extra_restrictions

			impls = []
			for f in usable_feeds(iface, arch):
				self.feeds_used.add(f)
				debug(_("Processing feed %s"), f)

				try:
					feed = self.iface_cache.get_interface(f)._main_feed
					if not feed.last_modified: continue	# DummyFeed
					if feed.name and iface.uri != feed.url and iface.uri not in feed.feed_for:
						info(_("Missing <feed-for> for '%(uri)s' in '%(feed)s'"), {'uri': iface.uri, 'feed': f})

					if feed.implementations:
						impls.extend(feed.implementations.values())
				except Exception, ex:
					warn(_("Failed to load feed %(feed)s for %(interface)s: %(exception)s"), {'feed': f, 'interface': iface, 'exception': str(ex)})

			if not impls:
				info(_("Interface %s has no implementations!"), iface)
				return None

			if self.record_details:
				# In details mode, rank all the implementations and then choose the best
				impls.sort(lambda a, b: compare(iface, a, b, iface_restrictions, arch))
				best = impls[0]
				self.details[iface] = [(impl, get_unusable_reason(impl, iface_restrictions, arch)) for impl in impls]
			else:
				# Otherwise, just choose the best without sorting
				best = impls[0]
				for x in impls[1:]:
					if compare(iface, x, best, iface_restrictions, arch) < 0:
						best = x
			unusable = get_unusable_reason(best, iface_restrictions, arch)
			if unusable:
				info(_("Best implementation of %(interface)s is %(best)s, but unusable (%(unusable)s)"), {'interface': iface, 'best': best, 'unusable': unusable})
				return None
			return best
		
		def compare(interface, b, a, iface_restrictions, arch):
			"""Compare a and b to see which would be chosen first.
			@param interface: The interface we are trying to resolve, which may
			not be the interface of a or b if they are from feeds.
			@rtype: int"""
			a_stab = a.get_stability()
			b_stab = b.get_stability()

			# Usable ones come first
			r = cmp(is_unusable(b, iface_restrictions, arch), is_unusable(a, iface_restrictions, arch))
			if r: return r

			# Preferred versions come first
			r = cmp(a_stab == model.preferred, b_stab == model.preferred)
			if r: return r

			if self.network_use != model.network_full:
				r = cmp(get_cached(a), get_cached(b))
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

			# Slightly prefer cached versions
			if self.network_use == model.network_full:
				r = cmp(get_cached(a), get_cached(b))
				if r: return r

			return cmp(a.id, b.id)
		
		def usable_feeds(iface, arch):
			"""Return all feeds for iface that support arch.
			@rtype: generator(ZeroInstallFeed)"""
			yield iface.uri

			for f in iface.feeds:
				# Note: when searching for src, None is not in machine_ranks
				if f.os in arch.os_ranks and \
				   (f.machine is None or f.machine in arch.machine_ranks):
					yield f.uri
				else:
					debug(_("Skipping '%(feed)s'; unsupported architecture %(os)s-%(machine)s"),
						{'feed': f, 'os': f.os, 'machine': f.machine})
		
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
			@note: The restrictions are for the interface being requested, not the interface
			of the implementation; they may be different when feeds are being used."""
			machine = impl.machine
			if machine and self._machine_group is not None:
				if machine_groups.get(machine, 0) != self._machine_group:
					return _("Incompatible with another selection from a different architecture group")

			for r in restrictions:
				if not r.meets_restriction(impl):
					return _("Incompatible with another selected implementation")
			stability = impl.get_stability()
			if stability <= model.buggy:
				return stability.name
			if self.network_use == model.network_offline and not get_cached(impl):
				return _("Not cached and we are off-line")
			if impl.os not in arch.os_ranks:
				return _("Unsupported OS")
			# When looking for source code, we need to known if we're
			# looking at an implementation of the root interface, even if
			# it's from a feed, hence the sneaky restrictions identity check.
			if machine not in arch.machine_ranks:
				if machine == 'src':
					return _("Source code")
				return _("Unsupported machine type")
			return None

		def get_cached(impl):
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
					path = self.stores.lookup_any(impl.digests)
					assert path
					return True
				except BadDigest:
					return False
				except NotStored:
					return False

		self.ready = process(model.InterfaceDependency(root_interface), arch)
