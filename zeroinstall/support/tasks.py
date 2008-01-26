"""The tasks module provides a simple light-weight alternative to threads.

When you have a long-running job you will want to run it in the background,
while the user does other things. There are four ways to do this:

- Use a new thread for each task.
- Use callbacks from an idle handler.
- Use a recursive mainloop.
- Use this module.

Using threads causes a number of problems. Some builds of pygtk/python don't
support them, they introduce race conditions, often lead to many subtle
bugs, and they require lots of resources (you probably wouldn't want 10,000
threads running at once). In particular, two threads can run at exactly the
same time (perhaps on different processors), so you have to be really careful
that they don't both try to update the same variable at the same time. This
requires lots of messy locking, which is hard to get right.

Callbacks work within a single thread. For example, you open a dialog box and
then tell the system to call one function if it's closed, and another if the
user clicks OK, etc. The function that opened the box then returns, and the
system calls one of the given callback functions later. Callbacks only
execute one at a time, so you don't have to worry about race conditions.
However, they are often very awkward to program with, because you have to
save state somewhere and then pass it to the functions when they're called.

A recursive mainloop only works with nested tasks (you can create a
sub-task, but the main task can't continue until the sub-task has
finished). We use these for, eg, rox.alert() boxes since you don't
normally want to do anything else until the box is closed, but it is not
appropriate for long-running jobs.

Tasks use python's generator API to provide a more pleasant interface to
callbacks. See the Task class (below) for more information.
"""

import gobject

# The list of Blockers whose event has happened, in the order they were
# triggered
_run_queue = []

class Blocker:
	"""A Blocker object starts life with 'happened = False'. Tasks can
	ask to be suspended until 'happened = True'. The value is changed
	by a call to trigger().

	Example:

	kettle_boiled = tasks.Blocker()

	def make_tea():
		print "Get cup"
		print "Add tea leaves"
		yield kettle_boiled
		print "Pour water into cup"
		print "Brew..."
		yield tasks.TimeoutBlocker(120)
		print "Add milk"
		print "Ready!"

	tasks.Task(make_tea())

	# elsewhere, later...
		print "Kettle boiled!"
		kettle_boiled.trigger()
	
	You can also yield a list of Blockers. Your function will resume
	after any one of them is triggered. Use blocker.happened to
	find out which one(s). Yielding a Blocker that has already
	happened is the same as yielding None (gives any other Tasks a
	chance to run, and then continues).
	"""

	def __init__(self):
		self.happened = False		# False until event triggered
		self._zero_lib_tasks = set()	# Tasks waiting on this blocker

	def trigger(self):
		"""The event has happened. Note that this cannot be undone;
		instead, create a new Blocker to handle the next occurance
		of the event."""
		if self.happened: return	# Already triggered
		self.happened = True
		#assert self not in _run_queue	# Slow
		if not _run_queue:
			_schedule()
		_run_queue.append(self)
	
	def add_task(self, task):
		"""Called by the schedular when a Task yields this
		Blocker. If you override this method, be sure to still
		call this method with Blocker.add_task(self)!"""
		self._zero_lib_tasks.add(task)
	
	def remove_task(self, task):
		"""Called by the schedular when a Task that was waiting for
		this blocker is resumed."""
		self._zero_lib_tasks.remove(task)

class IdleBlocker(Blocker):
	"""An IdleBlocker blocks until a task starts waiting on it, then
	immediately triggers. An instance of this class is used internally
	when a Task yields None."""
	def add_task(self, task):
		"""Also calls trigger."""
		Blocker.add_task(self, task)
		self.trigger()

class TimeoutBlocker(Blocker):
	"""Triggers after a set number of seconds."""
	def __init__(self, timeout):
		"""Trigger after 'timeout' seconds (may be a fraction)."""
		Blocker.__init__(self)
		gobject.timeout_add(long(timeout * 1000), self._timeout)
	
	def _timeout(self):
		self.trigger()

def _io_callback(src, cond, blocker):
	blocker.trigger()
	return False

class InputBlocker(Blocker):
	"""Triggers when os.read(stream) would not block."""
	_tag = None
	_stream = None
	def __init__(self, stream):
		Blocker.__init__(self)
		self._stream = stream
	
	def add_task(self, task):
		Blocker.add_task(self, task)
		if self._tag is None:
			self._tag = gobject.io_add_watch(self._stream, gobject.IO_IN | gobject.IO_HUP,
				_io_callback, self)
	
	def remove_task(self, task):
		Blocker.remove_task(self, task)
		if not self._zero_lib_tasks:
			gobject.source_remove(self._tag)
			self._tag = None

class OutputBlocker(Blocker):
	"""Triggers when os.write(stream) would not block."""
	_tag = None
	_stream = None
	def __init__(self, stream):
		Blocker.__init__(self)
		self._stream = stream
	
	def add_task(self, task):
		Blocker.add_task(self, task)
		if self._tag is None:
			self._tag = gobject.io_add_watch(self._stream, gobject.IO_OUT | gobject.IO_HUP,
				_io_callback, self)
	
	def remove_task(self, task):
		Blocker.remove_task(self, task)
		if not self._zero_lib_tasks:
			gobject.source_remove(self._tag)
			self._tag = None

_idle_blocker = IdleBlocker()

class Task:
	"""Create a new Task when you have some long running function to
	run in the background, but which needs to do work in 'chunks'.
	Example:

	from zeroinstall import tasks
	def my_task(start):
		for x in range(start, start + 5):
			print "x =", x
			yield None

	tasks.Task(my_task(0))
	tasks.Task(my_task(10))
	
	mainloop()

	Yielding None gives up control of the processor to another Task,
	causing the sequence printed to be interleaved. You can also yield a
	Blocker (or a list of Blockers) if you want to wait for some
	particular event before resuming (see the Blocker class for details).
	"""

	def __init__(self, iterator, name = None):
		"""Call iterator.next() from a glib idle function. This function
		can yield Blocker() objects to suspend processing while waiting
		for events. name is used only for debugging."""
		assert iterator.next, "Object passed is not an iterator!"
		self.next = iterator.next
		self.name = name
		self.finished = Blocker()
		# Block new task on the idle handler...
		_idle_blocker.add_task(self)
		self._zero_blockers = (_idle_blocker,)
	
	def _resume(self):
		# Remove from our blockers' queues
		for blocker in self._zero_blockers:
			blocker.remove_task(self)
		# Resume the task
		try:
			new_blockers = self.next()
		except StopIteration:
			# Task ended
			self.finished.trigger()
			return
		except Exception, ex:
			# Task crashed
			warn("Exception from task '%s': %s", self.name, ex)
			import traceback
			traceback.print_exc()
			self.finished.trigger()
			return
		if new_blockers is None:
			# Just give up control briefly
			new_blockers = (_idle_blocker,)
		else:
			if isinstance(new_blockers, Blocker):
				# Wrap a single yielded blocker into a list
				new_blockers = (new_blockers,)
			# Are we blocking on something that already happened?
			for blocker in new_blockers:
				if blocker.happened:
					new_blockers = (_idle_blocker,)
					break
		# Add to new blockers' queues
		for blocker in new_blockers:
			blocker.add_task(self)
		self._zero_blockers = new_blockers
	
	def __repr__(self):
		if self.name is None:
			return "[Task]"
		return "[Task '%s']" % self.name

# Must append to _run_queue right after calling this!
def _schedule():
	assert not _run_queue
	gobject.idle_add(_handle_run_queue)

def _handle_run_queue():
	global _idle_blocker
	assert _run_queue

	next = _run_queue[0]
	assert next.happened

	if next is _idle_blocker:
		# Since this blocker will never run again, create a
		# new one for future idling.
		_idle_blocker = IdleBlocker()
	
	tasks = frozenset(next._zero_lib_tasks)
	#print "Resume", tasks
	for task in tasks:
		# Run 'task'.
		task._resume()
	
	del _run_queue[0]

	if _run_queue:
		return True
	return False
