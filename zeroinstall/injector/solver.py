"""
Chooses a set of components to make a running program.

This class is intended to replace L{policy.Policy}.
"""

from logging import debug, warn, info

import selections
import model

# Copyright (C) 2008, Thomas Leonard
# See the README file for details, or visit http://0install.net.

class Solver(object):
	"""Chooses a set of implementations to satisfy the requirements of a program and its user.
	Typical use:
	 1. Create a Solver object and configure it
	 2. Call L{solve}.
	 3. If any of the returned feeds_used are stale or missing, you may like to start downloading them
	 4. If it is 'ready' then you can download and run the chosen versions.
	"""
	__slots__ = []

	def __init__(self):
		pass
	
	def solve(self, root_interface, feed_cache, arch):
		"""Get the best implementation of root_interface and all of its dependencies.
		@param root_interface: the URI of the program to be solved
		@type root_interface: str
		@param feed_cache: a cache of feeds containing information about available versions
		@type feed_cache: L{iface_cache.IfaceCache}
		@param arch: the desired target architecture
		@type arch: L{arch.Architecture}
		@return: ready, selections, feeds_used
		@rtype: (bool, Selections, [str])"""
		raise NotImplementedError("Abstract")

class DefaultSolver(Solver):
	def __init__(self, network_use, root_restrictions = None):
		self.network_use = network_use
		self.help_with_testing = False
		self.root_restrictions = root_restrictions or []

	def solve(self, root_interface, feed_cache, arch):
		ready = True
		chosen = {}
		feeds_used = set()

		restrictions = {}
		debug("Solve! root = %s", root_interface)
		def process(dep, arch):
			iface = feed_cache.get_interface(dep.interface)

			if iface in chosen:
				debug("Interface requested twice; skipping second %s", iface)
				if dep.restrictions:
					warn("Interface requested twice; I've already chosen an implementation "
						"of '%s' but there are more restrictions! Ignoring the second set.", iface)
				return
			chosen[iface.uri] = None	# Avoid cycles

			assert iface not in restrictions
			restrictions[iface] = dep.restrictions

			impl = get_best_implementation(iface, arch)
			if impl:
				debug("Will use implementation %s (version %s)", impl, impl.get_version())
				chosen[iface.uri] = impl
				for d in impl.requires:
					debug("Considering dependency %s", d)
					process(d, arch.child_arch)
			else:
				debug("No implementation chould be chosen yet");
				ready = False
			return arch

		def get_best_implementation(iface, arch):
			impls = []
			for f in usable_feeds(iface, arch):
				feeds_used.add(f.url)
				debug("Processing feed %s", f)
				try:
					if f.implementations:
						impls.extend(f.implementations.values())
				except Exception, ex:
					warn("Failed to load feed %s for %s: %s", f, iface, str(ex))
					raise

			debug("get_best_implementation(%s), with feeds: %s", iface, iface.feeds)

			if not impls:
				info("Interface %s has no implementations!", iface)
				return None
			best = impls[0]
			for x in impls[1:]:
				if compare(iface, x, best) < 0:
					best = x
			unusable = get_unusable_reason(best, restrictions.get(iface, []), arch)
			if unusable:
				info("Best implementation of %s is %s, but unusable (%s)", iface, best, unusable)
				return None
			return best
		
		def compare(interface, b, a):
			"""Compare a and b to see which would be chosen first.
			@param interface: The interface we are trying to resolve, which may
			not be the interface of a or b if they are from feeds.
			@rtype: int"""
			iface_restrictions = restrictions.get(interface, [])

			a_stab = a.get_stability()
			b_stab = b.get_stability()

			# Usable ones come first
			r = cmp(is_unusable(b, iface_restrictions, arch), is_unusable(a, iface_restrictions, arch))
			if r: return r

			# Preferred versions come first
			r = cmp(a_stab == model.preferred, b_stab == model.preferred)
			if r: return r

			if self.network_use != model.network_full:
				r = cmp(self.get_cached(a), self.get_cached(b))
				if r: return r

			# Stability
			stab_policy = interface.stability_policy
			if not stab_policy:
				if self.help_with_testing: stab_policy = model.testing
				else: stab_policy = model.stable

			if a_stab >= stab_policy: a_stab = preferred
			if b_stab >= stab_policy: b_stab = preferred

			r = cmp(a_stab, b_stab)
			if r: return r
			
			# Newer versions come before older ones
			r = cmp(a.version, b.version)
			if r: return r

			# Get best OS
			r = cmp(arch.os_ranks.get(a.os, None),
				arch.os_ranks.get(b.os, None))
			if r: return r

			# Get best machine
			r = cmp(arch.machine_ranks.get(a.machine, None),
				arch.machine_ranks.get(b.machine, None))
			if r: return r

			# Slightly prefer cached versions
			if self.network_use == model.network_full:
				r = cmp(self.get_cached(a), self.get_cached(b))
				if r: return r

			return cmp(a.id, b.id)
		
		def usable_feeds(iface, arch):
			"""Return all feeds for iface that support arch.
			@rtype: generator(ZeroInstallFeed)"""
			yield iface._main_feed

			for f in iface.feeds:
				if f.os in arch.os_ranks and f.machine in arch.machine_ranks:
					feed_iface = feed_cache.get_interface(f.uri)
					if feed_iface.name and iface.uri not in feed_iface.feed_for:
						warn("Missing <feed-for> for '%s' in '%s'", iface.uri, f.uri)
					yield feed_iface._main_feed
				else:
					debug("Skipping '%s'; unsupported architecture %s-%s",
						f, f.os, f.machine)
		
		def get_ranked_implementations(self, iface):
			"""Get all implementations from all feeds, in order.
			@type iface: Interface
			@return: a sorted list of implementations.
			@rtype: [model.Implementation]"""
			impls = iface.implementations.values()
			for f in self.usable_feeds(iface):
				feed_iface = iface_cache.get_interface(f.uri)
				if feed_iface.implementations:
					impls.extend(feed_iface.implementations.values())
			impls.sort(lambda a, b: compare(iface, a, b))
			return impls
		
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
			for r in restrictions:
				if not r.meets_restriction(impl):
					return "Incompatible with another selected implementation"
			stability = impl.get_stability()
			if stability <= model.buggy:
				return stability.name
			if self.network_use == model.network_offline and not self.get_cached(impl):
				return "Not cached and we are off-line"
			if impl.os not in arch.os_ranks:
				return "Unsupported OS"
			# When looking for source code, we need to known if we're
			# looking at an implementation of the root interface, even if
			# it's from a feed, hence the sneaky restrictions identity check.
			if impl.machine not in arch.machine_ranks:
				if impl.machine == 'src':
					return "Source code"
				return "Unsupported machine type"
			return None

		process(model.InterfaceDependency(root_interface, restrictions = self.root_restrictions), arch)

		return (ready, selections.Selections(chosen), feeds_used)

	def get_cached(self, impl):
		"""Check whether an implementation is available locally.
		@type impl: model.Implementation
		@rtype: bool
		"""
		if isinstance(impl, model.DistributionImplementation):
			return impl.installed
		if impl.id.startswith('/'):
			return os.path.exists(impl.id)
		else:
			try:
				path = self.get_implementation_path(impl)
				assert path
				return True
			except:
				pass # OK
		return False
