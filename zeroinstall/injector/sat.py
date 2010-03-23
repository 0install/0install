# Copyright (C) 2010, Thomas Leonard
# See the README file for details, or visit http://0install.net.

# The design of this solver is very heavily based on the one described in
# the MiniSat paper "An Extensible SAT-solver [extended version 1.2]"
# http://minisat.se/Papers.html
#
# The main differences are:
#
# - We care about which solution we find (not use "satisfiable" or "not").
# - We take care to be deterministic (always select the same versions given
#   the same input). We do not do random restarts, etc.
# - We add an AtMostOneClause (the paper suggests this in the Excercises, and
#   it's very useful for our purposes).
# - We don't currently do conflict-driven learning.

# Also, as this is a work-in-progress, we don't support back-tracking yet!

import tempfile, subprocess, os, sys
from logging import warn

def debug(msg, *args):
	pass #print "SAT:", msg % args

# variables are numbered from 0
# literals have the same number as the corresponding variable,
# except they for negatives they are (-1-v):
#
# Variable     Literal     not(Literal)
# 0	       0	   -1
# 1	       1	   -2
def neg(lit):
	return -1 - lit

def watch_index(lit):
	if lit >= 0:
		return lit * 2
	return neg(lit) * 2 + 1

def makeAtMostOneClause(solver):
	class AtMostOneClause:
		def __init__(self, lits):
			"""Preferred literals come first."""
			self.lits = lits

			# The single literal from our set that is True.
			# We store this explicitly because the decider needs to know quickly.
			self.current = None
		
		# Remove ourself from solver
		def remove(self):
			raise "help" #solver.watches.remove(index(neg(lits[0]))]

		# Simplify ourself and return True if we are no longer needed,
		# or False if we are.
		def simplify(self):
			# TODO
			return False

		def propagate(self, lit):
			# value[lit] has just become True
			assert solver.lit_value(lit) == True
			assert lit >= 0

			debug("%s: noticed %s has become True" % (self, solver.name_lit(lit)))

			# One is already selected
			if self.current is not None:
				debug("CONFLICT: already selected %s" % self.current)
				return False

			self.current = lit

			# Re-add ourselves to the watch list.
			# (we we won't get any more notifications unless we backtrack,
			# in which case we'd need to get back on the list anyway)
			solver.watch_lit(lit, self)

			count = 0
			for l in self.lits:
				value = solver.lit_value(l)
				#debug("Value of %s is %s" % (solver.name_lit(l), value))
				if value is True:
					count += 1
					if count > 1:
						debug("CONFLICT: already selected %s" % self.current)
						return False
				if value is None:
					# Since one of our lits is already true, all unknown ones
					# can be set to False.
					if not solver.enqueue(neg(l), self):
						debug("CONFLICT: enqueue failed for %s", solver.name_lit(neg(l)))
						return False	# Conflict; abort

			return True

		def undo(self, lit):
			assert lit == self.current
			self.current = None

		# Why is lit True?
		def cacl_reason(self, lit):
			raise Exception("why is %d set?" % lit)

		def best_undecided(self):
			debug("best_undecided: %s" % (solver.name_lits(self.lits)))
			for lit in self.lits:
				#debug("%s = %s" % (solver.name_lit(lit), solver.lit_value(lit)))
				if solver.lit_value(lit) is None:
					return lit
			return None

		def __repr__(self):
			return "<lone: %s>" % (', '.join(solver.name_lits(self.lits)))

	return AtMostOneClause

def makeUnionClause(solver):
	class UnionClause:
		def __init__(self, lits):
			self.lits = lits
		
		# Remove ourself from solver
		def remove(self):
			raise "help" #solver.watches.remove(index(neg(lits[0]))]

		# Simplify ourself and return True if we are no longer needed,
		# or False if we are.
		def simplify(self):
			new_lits = []
			for l in self.lits:
				value = solver.lit_value(l)
				if value == True:
					# (... or True or ...) = True
					return True
				elif value == None:
					new_lits.append(l)
			self.lits = new_lits
			return False

		# Try to infer new facts.
		# We can do this only when all of our literals are False except one,
		# which is undecided. That is,
		#   False... or X or False... = True  =>  X = True
		#
		# To get notified when this happens, we tell the solver to
		# watch two of our undecided literals. Watching two undecided
		# literals is sufficient. When one changes we check the state
		# again. If we still have two or more undecided then we switch
		# to watching them, otherwise we propagate.
		#
		# Returns False on conflict.
		def propagate(self, lit):
			# value[get(lit)] has just become False

			debug("%s: noticed %s has become False" % (self, solver.name_lit(neg(lit))))

			# For simplicity, only handle the case where self.lits[1]
			# is the one that just got set to False, so that:
			# - value[lits[0]] = undecided (None)
			# - value[lits[1]] = False
			# If it's the other way around, just swap them before we start.
			if self.lits[0] == neg(lit):
				self.lits[0], self.lits[1] = self.lits[1], self.lits[0]

			if solver.lit_value(self.lits[0]) == True:
				# We're already satisfied. Do nothing.
				solver.watch_lit(lit, self)
				return True

			# Find a new literal to watch now that lits[1] is resolved,
			# swap it with lits[1], and start watching it.
			for i in range(2, len(self.lits)):
				value = solver.lit_value(self.lits[i])
				if value != False:
					# Could be None or True. If it's True then we've already done our job,
					# so this means we don't get notified unless we backtrack, which is fine.
					self.lits[1], self.lits[i] = self.lits[i], self.lits[1]
					solver.watch_lit(self.lits[1], self)	# ??
					return True

			# Only lits[0], is now undefined.
			solver.watch_lit(lit, self)
			return solver.enqueue(self.lits[0], self)

		def undo(self, lit): pass

		# Why is lit True?
		def cacl_reason(self, lit):
			raise Exception("why is %d set?" % lit)

		def __repr__(self):
			return "<some: %s>" % (', '.join(solver.name_lits(self.lits)))
	return UnionClause

# Using an array of VarInfo objects is less efficient than using multiple arrays, but
# easier for me to understand.
class VarInfo(object):
	__slots__ = ['value', 'reason', 'level', 'undo', 'obj']
	def __init__(self, obj):
		self.value = None		# True/False/None
		self.reason = None		# The constraint that implied our value, if True or False
		self.level = -1			# The decision level at which we got a value (when not None)
		self.undo = None		# Constraints to update if we become unbound (by backtracking)
		self.obj = obj			# The object this corresponds to (for our caller and for debugging)
	
	def __repr__(self):
		return '%s=%s' % (self.name, self.value)

	@property
	def name(self):
		return str(self.obj)

class Solver(object):
	def __init__(self):
		# Constraints
		self.constrs = []		# Constraints set by our user	XXX - do we ever use this?
		self.learnt = []		# Constraints we learnt while solving
		# order?

		# Propagation
		self.watches = []		# watches[2i,2i+1] = constraints to check when literal[i] becomes True/False
		self.propQ = []			# propagation queue

		# Assignments
		self.assigns = []		# [VarInfo]
		self.trail = []			# order of assignments
		self.trail_lim = []		# decision levels

		self.toplevel_conflict = False

		self.makeAtMostOneClause = makeAtMostOneClause(self)
		self.makeUnionClause = makeUnionClause(self)
	
	def get_decision_level(self):
		return len(self.trail_lim)

	def add_variable(self, obj):
		index = len(self.assigns)

		self.watches += [[], []]	# Add watch lists for X and not(X)
		self.assigns.append(VarInfo(obj))
		return index

	# lit is now True
	# reason is the clause that is asserting this
	# Returns False if this immediately causes a conflict.
	def enqueue(self, lit, reason):
		debug("%s => %s" % (reason, self.name_lit(lit)))
		old_value = self.lit_value(lit)
		if old_value is not None:
			if old_value is False:
				# Conflict
				return False
			else:
				# Already set
				return True

		if lit < 0:
			var_info = self.assigns[neg(lit)]
			var_info.value = False
		else:
			var_info = self.assigns[lit]
			var_info.value = True
		var_info.level = self.get_decision_level()
		var_info.reason = reason

		self.trail.append(lit)
		self.propQ.append(lit)

		return True
	
	# Process the propQ.
	# Returns None when done, or the clause that caused a conflict.
	def propagate(self):
		debug("propagate: queue length = %d", len(self.propQ))
		while self.propQ:
			lit = self.propQ[0]
			del self.propQ[0]
			var_info = self.get_varinfo_for_lit(lit)
			wi = watch_index(lit)
			watches = self.watches[wi]
			self.watches[wi] = []

			debug("%s -> True : watches: %s" % (self.name_lit(lit), watches))

			# Notifiy all watchers
			for i in range(len(watches)):
				clause = watches[i]
				if not clause.propagate(lit):
					# Conflict

					# Re-add remaining watches
					self.watches[wi] += watches[i+1:]
					
					# No point processing the rest of the queue as
					# we'll have to backtrack now.
					self.propQ = []

					return clause
		return None
	
	def impossible(self):
		self.toplevel_conflict = True

	def get_varinfo_for_lit(self, lit):
		if lit >= 0:
			return self.assigns[lit]
		else:
			return self.assigns[neg(lit)]
	
	def lit_value(self, lit):
		if lit >= 0:
			value = self.assigns[lit].value
			return value
		else:
			v = -1 - lit
			value = self.assigns[v].value
			if value is None:
				return None
			else:
				return not value
	
	# Call cb when lit becomes True
	def watch_lit(self, lit, cb):
		#debug("%s is watching for %s to become True" % (cb, self.name_lit(lit)))
		self.watches[watch_index(lit)].append(cb)

	# Returns the new clause if one was added, True if none was added
	# because this clause is trivially True, or False if the clause is
	# False.
	def _add_clause(self, lits, learnt):
		assert len(lits) > 1
		clause = self.makeUnionClause(lits)
		clause.learnt = learnt
		self.constrs.append(clause)

		if learnt:
			# TODO: pick a second undecided literal and move to lits[1]
			raise Exception("todo")

		# Watch the first two literals in the clause (both must be
		# undefined at this point).
		for lit in lits[:2]:
			self.watch_lit(neg(lit), clause)

		return clause

	def name_lits(self, lst):
		return [self.name_lit(l) for l in lst]

	# For nicer debug messages
	def name_lit(self, lit):
		if lit >= 0:
			return self.assigns[lit].name
		return "not(%s)" % self.assigns[neg(lit)].name
	
	def add_clause(self, lits):
		# Public interface. Only used before the solve starts.
		assert lits

		debug("add_clause: %s" % self.name_lits(lits))

		if any(self.lit_value(l) == True for l in lits):
			# Trivially true already.
			return True
		lit_set = set(lits)
		for l in lits:
			if neg(l) in lit_set:
				# X or not(X) is always True.
				return True
		# Remove duplicates and values known to be False
		lits = [l for l in lit_set if self.lit_value(l) != False]

		if not lits:
			self.toplevel_conflict = True
			return False
		elif len(lits) == 1:
			# A clause with only a single literal is represented
			# as an assignment rather than as a clause.
			return self.enqueue(lits[0], reason = "top-level")

		return self._add_clause(lits, learnt = False)

	def at_most_one(self, lits):
		assert lits

		debug("at_most_one: %s" % self.name_lits(lits))

		# If we have zero or one literals then we're trivially true
		# and not really needed for the solve. However, Zero Install
		# monitors these objects to find out what was selected, so
		# keep even trivial ones around for that.
		#
		#if len(lits) < 2:
		#	return True	# Trivially true

		# Ensure no duplicates
		assert len(set(lits)) == len(lits), lits

		# Ignore any literals already known to be False.
		# If any are True then they're enqueued and we'll process them
		# soon.
		lits = [l for l in lits if self.lit_value(l) != False]

		clause = self.makeAtMostOneClause(lits)

		self.constrs.append(clause)

		for lit in lits:
			self.watch_lit(lit, clause)

		return clause

	def analyse(self, clause):
		debug("Why did %s make us fail?" % clause)
		raise Exception("not implemented")

	def run_solver(self, decide):
		# Check whether we detected a trivial problem
		# during setup.
		if self.toplevel_conflict:
			return False

		while True:
			# Use logical deduction to simplify the clauses
			# and assign literals where there is only one possibility.
			conflicting_clause = self.propagate()
			if not conflicting_clause:
				debug("new state: %s", self.assigns)
				if all(info.value != None for info in self.assigns):
					# Everything is assigned without conflicts
					debug("SUCCESS!")
					return True
				else:
					# Pick a variable and try assigning it one way.
					# If it leads to a conflict, we'll backtrack and
					# try it the other way.
					lit = decide()
					if lit is None:
						debug("decide -> None")
						return False
					assert self.lit_value(lit) is None
					self.trail_lim.append(len(self.trail))
					r = self.enqueue(lit, reason = "considering")
					assert r is True
			else:
				# Figure out the root cause of this failure.
				if self.get_decision_level() == 0:
					self.toplevel_conflict = True
				else:
					learnt_clause, backtrack_level = self.analyse(conflicting_clause)
					self.record(learnt_clause)

				if self.toplevel_conflict:
					# The whole problem is logically impossible.
					return False
				else:
					# An assignment we decided to try was
					# wrong. Go back.
					self.backtrack()

		return ready, selected

