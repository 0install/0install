"""
Internal implementation of a SAT solver, used by L{solver.SATSolver}.
This is not part of the public API.
"""

# Copyright (C) 2010, Thomas Leonard
# See the README file for details, or visit http://0install.net.

# The design of this solver is very heavily based on the one described in
# the MiniSat paper "An Extensible SAT-solver [extended version 1.2]"
# http://minisat.se/Papers.html
#
# The main differences are:
#
# - We care about which solution we find (not just "satisfiable" or "not").
# - We take care to be deterministic (always select the same versions given
#   the same input). We do not do random restarts, etc.
# - We add an AtMostOneClause (the paper suggests this in the Excercises, and
#   it's very useful for our purposes).

def debug(msg, *args):
	return
	print "SAT:", msg % args

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

		def propagate(self, lit):
			# Re-add ourselves to the watch list.
			# (we we won't get any more notifications unless we backtrack,
			# in which case we'd need to get back on the list anyway)
			solver.watch_lit(lit, self)

			# value[lit] has just become True
			assert solver.lit_value(lit) == True
			assert lit >= 0

			#debug("%s: noticed %s has become True" % (self, solver.name_lit(lit)))

			# If we already propagated successfully when the first
			# one was set then we set all the others to False and
			# anyone trying to set one True will get rejected. And
			# if we didn't propagate yet, current will still be
			# None, even if we now have a conflict (which we'll
			# detect below).
			assert self.current is None

			self.current = lit

			# If we later backtrace, call our undo function to unset current
			solver.get_varinfo_for_lit(lit).undo.append(self)

			for l in self.lits:
				value = solver.lit_value(l)
				#debug("Value of %s is %s" % (solver.name_lit(l), value))
				if value is True and l is not lit:
					# Due to queuing, we might get called with current = None
					# and two versions already selected.
					debug("CONFLICT: already selected %s" % solver.name_lit(l))
					return False
				if value is None:
					# Since one of our lits is already true, all unknown ones
					# can be set to False.
					if not solver.enqueue(neg(l), self):
						debug("CONFLICT: enqueue failed for %s", solver.name_lit(neg(l)))
						return False	# Conflict; abort

			return True

		def undo(self, lit):
			debug("(backtracking: no longer selected %s)" % solver.name_lit(lit))
			assert lit == self.current
			self.current = None

		# Why is lit True?
		# Or, why are we causing a conflict (if lit is None)?
		def cacl_reason(self, lit):
			if lit is None:
				# Find two True literals
				trues = []
				for l in self.lits:
					if solver.lit_value(l) is True:
						trues.append(l)
						if len(trues) == 2: return trues
			else:
				for l in self.lits:
					if l is not lit and solver.lit_value(l) is True:
						return [l]
				# Find one True literal
			assert 0	# don't know why!

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

			#debug("%s: noticed %s has become False" % (self, solver.name_lit(neg(lit))))

			# For simplicity, only handle the case where self.lits[1]
			# is the one that just got set to False, so that:
			# - value[lits[0]] = None | True
			# - value[lits[1]] = False
			# If it's the other way around, just swap them before we start.
			if self.lits[0] == neg(lit):
				self.lits[0], self.lits[1] = self.lits[1], self.lits[0]

			if solver.lit_value(self.lits[0]) == True:
				# We're already satisfied. Do nothing.
				solver.watch_lit(lit, self)
				return True

			assert solver.lit_value(self.lits[1]) == False

			# Find a new literal to watch now that lits[1] is resolved,
			# swap it with lits[1], and start watching it.
			for i in range(2, len(self.lits)):
				value = solver.lit_value(self.lits[i])
				if value != False:
					# Could be None or True. If it's True then we've already done our job,
					# so this means we don't get notified unless we backtrack, which is fine.
					self.lits[1], self.lits[i] = self.lits[i], self.lits[1]
					solver.watch_lit(neg(self.lits[1]), self)
					return True

			# Only lits[0], is now undefined.
			solver.watch_lit(lit, self)
			return solver.enqueue(self.lits[0], self)

		def undo(self, lit): pass

		# Why is lit True?
		# Or, why are we causing a conflict (if lit is None)?
		def cacl_reason(self, lit):
			assert lit is None or lit is self.lits[0]

			# The cause is everything except lit.
			return [neg(l) for l in self.lits if l is not lit]

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
		self.undo = []			# Constraints to update if we become unbound (by backtracking)
		self.obj = obj			# The object this corresponds to (for our caller and for debugging)
	
	def __repr__(self):
		return '%s=%s' % (self.name, self.value)

	@property
	def name(self):
		return str(self.obj)

class SATProblem(object):
	def __init__(self):
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
		debug("add_variable('%s')", obj)
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
				# Already set (shouldn't happen)
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

	# Pop most recent assignment from self.trail
	def undo_one(self):
		lit = self.trail[-1]
		debug("(pop %s)", self.name_lit(lit))
		var_info = self.get_varinfo_for_lit(lit)
		var_info.value = None
		var_info.reason = None
		var_info.level = -1
		self.trail.pop()

		while var_info.undo:
			var_info.undo.pop().undo(lit)
	
	def cancel(self):
		n_this_level = len(self.trail) - self.trail_lim[-1]
		debug("backtracking from level %d (%d assignments)" %
				(self.get_decision_level(), n_this_level))
		while n_this_level != 0:
			self.undo_one()
			n_this_level -= 1
		self.trail_lim.pop()

	def cancel_until(self, level):
		while self.get_decision_level() > level:
			self.cancel()
	
	# Process the propQ.
	# Returns None when done, or the clause that caused a conflict.
	def propagate(self):
		#debug("propagate: queue length = %d", len(self.propQ))
		while self.propQ:
			lit = self.propQ[0]
			del self.propQ[0]
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
		if not lits:
			assert not learnt
			self.toplevel_conflict = True
			return False
		elif len(lits) == 1:
			# A clause with only a single literal is represented
			# as an assignment rather than as a clause.
			if learnt:
				reason = "learnt"
			else:
				reason = "top-level"
			return self.enqueue(lits[0], reason)

		clause = self.makeUnionClause(lits)
		clause.learnt = learnt

		if learnt:
			# lits[0] is None because we just backtracked.
			# Start watching the next literal that we will
			# backtrack over.
			best_level = -1
			best_i = 1
			for i in range(1, len(lits)):
				level = self.get_varinfo_for_lit(lits[i]).level
				if level > best_level:
					best_level = level
					best_i = i
			lits[1], lits[best_i] = lits[best_i], lits[1]

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

		debug("add_clause([%s])" % ', '.join(self.name_lits(lits)))

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

		retval = self._add_clause(lits, learnt = False)
		if not retval:
			self.toplevel_conflict = True
		return retval

	def at_most_one(self, lits):
		assert lits

		debug("at_most_one(%s)" % ', '.join(self.name_lits(lits)))

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

		for lit in lits:
			self.watch_lit(lit, clause)

		return clause

	def analyse(self, cause):
		# After trying some assignments, we've discovered a conflict.
		# e.g.
		# - we selected A then B then C
		# - from A, B, C we got X, Y
		# - we have a rule: not(A) or not(X) or not(Y)
		#
		# The simplest thing to do would be:
		# 1. add the rule "not(A) or not(B) or not(C)"
		# 2. unassign C
		#
		# Then we we'd deduce not(C) and we could try something else.
		# However, that would be inefficient. We want to learn a more
		# general rule that will help us with the rest of the problem.
		#
		# We take the clause that caused the conflict ("cause") and
		# ask it for its cause. In this case:
		#
		#  A and X and Y => conflict
		#
		# Since X and Y followed logically from A, B, C there's no
		# point learning this rule; we need to know to avoid A, B, C
		# *before* choosing C. We ask the two variables deduced at the
		# current level (X and Y) what caused them, and work backwards.
		# e.g.
		#
		#  X: A and C => X
		#  Y: C => Y
		#
		# Combining these, we get the cause of the conflict in terms of
		# things we knew before the current decision level:
		#
		#  A and X and Y => conflict
		#  A and (A and C) and (C) => conflict
		#  A and C => conflict
		#
		# We can then learn (record) the more general rule:
		#
		#  not(A) or not(C)
		#
		# Then, in future, whenever A is selected we can remove C and
		# everything that depends on it from consideration.


		learnt = [None]		# The general rule we're learning
		btlevel = 0		# The deepest decision in learnt
		p = None		# The literal we want to expand now
		seen = set()		# The variables involved in the conflict

		counter = 0

		while True:
			# cause is the reason why p is True (i.e. it enqueued it).
			# The first time, p is None, which requests the reason
			# why it is conflicting.
			if p is None:
				debug("Why did %s make us fail?" % cause)
				p_reason = cause.cacl_reason(p)
				debug("Because: %s => conflict" % (' and '.join(self.name_lits(p_reason))))
			else:
				debug("Why did %s lead to %s?" % (cause, self.name_lit(p)))
				p_reason = cause.cacl_reason(p)
				debug("Because: %s => %s" % (' and '.join(self.name_lits(p_reason)), self.name_lit(p)))

			# p_reason is in the form (A and B and ...)
			# p_reason => p

			# Check each of the variables in p_reason that we haven't
			# already considered:
			# - if the variable was assigned at the current level,
			#   mark it for expansion
			# - otherwise, add it to learnt

			for lit in p_reason:
				var_info = self.get_varinfo_for_lit(lit)
				if var_info not in seen:
					seen.add(var_info)
					if var_info.level == self.get_decision_level():
						# We deduced this var since the last decision.
						# It must be in self.trail, so we'll get to it
						# soon. Remember not to stop until we've processed it.
						counter += 1
					elif var_info.level > 0:
						# We won't expand lit, just remember it.
						# (we could expand it if it's not a decision, but
						# apparently not doing so is useful)
						learnt.append(neg(lit))
						btlevel = max(btlevel, var_info.level)
				# else we already considered the cause of this assignment

			# At this point, counter is the number of assigned
			# variables in self.trail at the current decision level that
			# we've seen. That is, the number left to process. Pop
			# the next one off self.trail (as well as any unrelated
			# variables before it; everything up to the previous
			# decision has to go anyway).

			# On the first time round the loop, we must find the
			# conflict depends on at least one assignment at the
			# current level. Otherwise, simply setting the decision
			# variable caused a clause to conflict, in which case
			# the clause should have asserted not(decision-variable)
			# before we ever made the decision.
			# On later times round the loop, counter was already >
			# 0 before we started iterating over p_reason.
			assert counter > 0

			while True:
				p = self.trail[-1]
				var_info = self.get_varinfo_for_lit(p)
				cause = var_info.reason
				self.undo_one()
				if var_info in seen:
					break
				debug("(irrelevant)")
			counter -= 1

			if counter <= 0:
				assert counter == 0
				# If counter = 0 then we still have one more
				# literal (p) at the current level that we
				# could expand. However, apparently it's best
				# to leave this unprocessed (says the minisat
				# paper).
				break

		# p is the literal we decided to stop processing on. It's either
		# a derived variable at the current level, or the decision that
		# led to this level. Since we're not going to expand it, add it
		# directly to the learnt clause.
		learnt[0] = neg(p)

		debug("Learnt: %s" % (' or '.join(self.name_lits(learnt))))

		return learnt, btlevel

	def run_solver(self, decide):
		# Check whether we detected a trivial problem
		# during setup.
		if self.toplevel_conflict:
			debug("FAIL: toplevel_conflict before starting solve!")
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
					#print "TRYING:", self.name_lit(lit)
					assert lit is not None, "decide function returned None!"
					assert self.lit_value(lit) is None
					self.trail_lim.append(len(self.trail))
					r = self.enqueue(lit, reason = "considering")
					assert r is True
			else:
				if self.get_decision_level() == 0:
					debug("FAIL: conflict found at top level")
					return False
				else:
					# Figure out the root cause of this failure.
					learnt, backtrack_level = self.analyse(conflicting_clause)

					self.cancel_until(backtrack_level)

					c = self._add_clause(learnt, learnt = True)

					if c is not True:
						# Everything except the first literal in learnt is known to
						# be False, so the first must be True.
						e = self.enqueue(learnt[0], c)
						assert e is True
