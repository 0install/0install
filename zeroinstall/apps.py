"""
Support for managing apps (as created with "0install add").
@since: 1.9
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, SafeException, logger, DryRun
from zeroinstall.support import basedir, portable_rename
from zeroinstall.injector import namespaces, selections, qdom, model
import re, os, time, tempfile

# Avoid characters that are likely to cause problems (reject : and ; everywhere
# so that apps can be portable between POSIX and Windows).
valid_name = re.compile(r'''^[^./\\:=;'"][^/\\:=;'"]*$''')

def validate_name(name):
	if name == '0install':
		raise SafeException("Creating an app called '0install' would cause trouble; try e.g. '00install' instead")
	if valid_name.match(name): return
	raise SafeException("Invalid application name '{name}'".format(name = name))

def _export(name, value):
	"""Try to guess the command to set an environment variable."""
	shell = os.environ.get('SHELL', '?')
	if 'csh' in shell:
		return "setenv %s %s" % (name, value)
	return "export %s=%s" % (name, value)

def find_bin_dir(paths = None):
	"""Find the first writable path in the list (default $PATH),
	skipping /bin, /sbin and everything under /usr except /usr/local/bin"""
	if paths is None:
		paths = os.environ['PATH'].split(os.pathsep)
	for path in paths:
		if path.startswith('/usr/') and not path.startswith('/usr/local/bin'):
			# (/usr/local/bin is OK if we're running as root)
			pass
		elif path.startswith('/bin') or path.startswith('/sbin'):
			pass
		elif os.path.realpath(path).startswith(basedir.xdg_cache_home):
			pass # print "Skipping cache", first_path
		elif not os.access(path, os.W_OK):
			pass # print "No access", first_path
		else:
			break
	else:
		path = os.path.expanduser('~/bin/')
		logger.warn('%s is not in $PATH. Add it with:\n%s' % (path, _export('PATH', path + ':$PATH')))

		if not os.path.isdir(path):
			os.makedirs(path)
	return path

_command_template = """#!/bin/sh
exec 0install run {app} "$@"
"""

class AppScriptInfo:
	"""@since: 1.12"""
	name = None
	command = None

def parse_script_header(stream):
	"""If stream is a shell script for an application, return the app details.
	@param stream: the executable file's stream (will seek)
	@type stream: file-like object
	@return: the app details, if any
	@rtype: L{AppScriptInfo} | None
	@since: 1.12"""
	try:
		stream.seek(0)
		template_header = _command_template[:_command_template.index("{app}")]
		actual_header = stream.read(len(template_header))
		stream.seek(0)
		if template_header == actual_header:
			# If it's a launcher script, it should be quite short!
			rest = stream.read()
			line = rest.split('\n')[1]
		else:
			return None
	except UnicodeDecodeError as ex:
		logger.info("Not an app script '%s': %s", stream, ex)
		return None

	info = AppScriptInfo()
	info.name = line.split()[3]
	return info

class App:
	def __init__(self, config, path):
		self.config = config
		self.path = path

	def set_selections(self, sels, set_last_checked = True):
		"""Store a new set of selections. We include today's date in the filename
		so that we keep a history of previous selections (max one per day), in case
		we want to to roll back later."""
		date = time.strftime('%Y-%m-%d')
		sels_file = os.path.join(self.path, 'selections-{date}.xml'.format(date = date))
		dom = sels.toDOM()

		if self.config.handler.dry_run:
			print(_("[dry-run] would write selections to {file}").format(file = sels_file))
		else:
			tmp = tempfile.NamedTemporaryFile(prefix = 'selections.xml-', dir = self.path, delete = False, mode = 'wt')
			try:
				dom.writexml(tmp, addindent="  ", newl="\n", encoding = 'utf-8')
			except:
				tmp.close()
				os.unlink(tmp.name)
				raise
			tmp.close()
			portable_rename(tmp.name, sels_file)

		sels_latest = os.path.join(self.path, 'selections.xml')
		if self.config.handler.dry_run:
			print(_("[dry-run] would update {link} to point to new selections file").format(link = sels_latest))
		else:
			if os.path.exists(sels_latest):
				os.unlink(sels_latest)
			os.symlink(os.path.basename(sels_file), sels_latest)

		if set_last_checked:
			self.set_last_checked()

	def get_selections(self, snapshot_date = None, may_update = False):
		"""Load the selections.
		@param may_update: whether to check for updates
		@type may_update: bool
		@param snapshot_date: get a historical snapshot
		@type snapshot_date: (as returned by L{get_history}) | None
		@return: the selections
		@rtype: L{selections.Selections}"""
		if snapshot_date:
			sels_file = os.path.join(self.path, 'selections-' + snapshot_date + '.xml')
		else:
			sels_file = os.path.join(self.path, 'selections.xml')
		with open(sels_file, 'rb') as stream:
			sels = selections.Selections(qdom.parse(stream))

		if may_update:
			sels = self._check_for_updates(sels)

		return sels

	def get_history(self):
		"""Get the dates of the available snapshots, starting with the most recent.
		@rtype: [str]"""
		date_re = re.compile('selections-(\d\d\d\d-\d\d-\d\d).xml')
		snapshots = []
		for f in os.listdir(self.path):
			match = date_re.match(f)
			if match:
				snapshots.append(match.group(1))
		snapshots.sort(reverse = True)
		return snapshots

	def download_selections(self, sels):
		"""Download any missing implementations.
		@return: a blocker which resolves when all needed implementations are available
		@rtype: L{tasks.Blocker} | None"""
		return sels.download_missing(self.config)	# TODO: package impls

	def _check_for_updates(self, sels):
		"""Check whether the selections need to be updated.
		If any input feeds have changed, we re-run the solver. If the
		new selections require a download, we schedule one in the
		background and return the old selections. Otherwise, we return the
		new selections. If we can select better versions without downloading,
		we update the app's selections and return the new selections.
		We also schedule a background update from time-to-time anyway.
		@return: the selections to use
		@rtype: L{selections.Selections}"""
		need_solve = False		# Rerun solver (cached feeds have changed)
		need_update = False		# Update over the network

		utime = self._get_mtime('last-checked', warn_if_missing = True)
		last_solve = max(self._get_mtime('last-solve', warn_if_missing = False), utime)

		# Ideally, this would return all the files which were inputs into the solver's
		# decision. Currently, we approximate with:
		# - the previously selected feed files (local or cached)
		# - configuration files for the selected interfaces
		# - the global configuration
		# We currently ignore feeds and interfaces which were
		# considered but not selected.
		# Can yield None (ignored), paths or (path, mtime) tuples.
		# If this throws an exception, we will log it and resolve anyway.
		def get_inputs():
			for sel in sels.selections.values():
				logger.info("Checking %s", sel.feed)
				feed = iface_cache.get_feed(sel.feed)
				if not feed:
					raise IOError("Input %s missing; update" % sel.feed)
				else:
					if feed.local_path:
						yield feed.local_path
					else:
						yield (feed.url, feed.last_modified)

				# Per-feed configuration
				yield basedir.load_first_config(namespaces.config_site, namespaces.config_prog,
								   'interfaces', model._pretty_escape(sel.interface))

			# Global configuration
			yield basedir.load_first_config(namespaces.config_site, namespaces.config_prog, 'global')

		# If any of the feeds we used have been updated since the last check, do a quick re-solve
		iface_cache = self.config.iface_cache
		try:
			for item in get_inputs():
				if not item: continue
				if isinstance(item, tuple):
					path, mtime = item
				else:
					path = item
					mtime = os.stat(path).st_mtime

				if mtime and mtime > last_solve:
					logger.info("Triggering update to %s because %s has changed", self, path)
					need_solve = True
					break
		except Exception as ex:
			logger.info("Error checking modification times: %s", ex)
			need_solve = True
			need_update = True

		# Is it time for a background update anyway?
		if not need_update:
			staleness = time.time() - utime
			logger.info("Staleness of app %s is %d hours", self, staleness / (60 * 60))
			freshness_threshold = self.config.freshness
			if freshness_threshold > 0 and staleness >= freshness_threshold:
				need_update = True

		if need_solve:
			from zeroinstall.injector.driver import Driver
			driver = Driver(config = self.config, requirements = self.get_requirements())
			if driver.need_download():
				# Continue with the current (hopefully cached) selections while we download
				need_update = True
			else:
				old_sels = sels
				sels = driver.solver.selections
				from zeroinstall.support import xmltools
				if not xmltools.nodes_equal(sels.toDOM(), old_sels.toDOM()):
					self.set_selections(sels, set_last_checked = False)
			self._touch('last-solve')

		# If we tried to check within the last hour, don't try again.
		if need_update:
			last_check_attempt = self._get_mtime('last-check-attempt', warn_if_missing = False)
			if last_check_attempt and last_check_attempt + 60 * 60 > time.time():
				logger.info("Tried to check within last hour; not trying again now")
				need_update = False

		if need_update:
			self.set_last_check_attempt()
			from zeroinstall.injector import background
			r = self.get_requirements()
			background.spawn_background_update2(r, False, self)

		return sels

	def set_requirements(self, requirements):
		reqs_file = os.path.join(self.path, 'requirements.json')
		if self.config.handler.dry_run:
			print(_("[dry-run] would write {file}").format(file = reqs_file))
		else:
			import json
			tmp = tempfile.NamedTemporaryFile(prefix = 'tmp-requirements-', dir = self.path, delete = False, mode = 'wt')
			try:
				json.dump(dict((key, getattr(requirements, key)) for key in requirements.__slots__), tmp)
			except:
				tmp.close()
				os.unlink(tmp.name)
				raise
			tmp.close()

			portable_rename(tmp.name, reqs_file)

	def get_requirements(self):
		import json
		from zeroinstall.injector import requirements
		r = requirements.Requirements(None)
		reqs_file = os.path.join(self.path, 'requirements.json')
		with open(reqs_file, 'rt') as stream:
			values = json.load(stream)

		# Update old before/not-before values
		before = values.pop('before', None)
		not_before = values.pop('not_before', None)
		if before or not_before:
			assert not values.extra_restrictions
			expr = (not_before or '') + '..'
			if before:
				expr += '!' + before
			values['extra_restrictions'] = {values['interface_uri']: expr}

		for k, v in values.items():
			setattr(r, k, v)
		return r

	def set_last_check_attempt(self):
		self._touch('last-check-attempt')

	def set_last_checked(self):
		self._touch('last-checked')

	def _touch(self, name):
		timestamp_path = os.path.join(self.path, name)
		if self.config.handler.dry_run:
			pass #print(_("[dry-run] would update timestamp file {file}").format(file = timestamp_path))
		else:
			fd = os.open(timestamp_path, os.O_WRONLY | os.O_CREAT, 0o644)
			os.close(fd)
			os.utime(timestamp_path, None)	# In case file already exists

	def _get_mtime(self, name, warn_if_missing = True):
		timestamp_path = os.path.join(self.path, name)
		try:
			return os.stat(timestamp_path).st_mtime
		except Exception as ex:
			if warn_if_missing:
				logger.warn("Failed to get time-stamp of %s: %s", timestamp_path, ex)
			return 0

	def get_last_checked(self):
		"""Get the time of the last successful check for updates.
		@return: the timestamp (or None on error)
		@rtype: float | None"""
		return self._get_mtime('last-checked', warn_if_missing = True)

	def get_last_check_attempt(self):
		"""Get the time of the last attempted check.
		@return: the timestamp, or None if we updated successfully.
		@rtype: float | None"""
		last_check_attempt = self._get_mtime('last-check-attempt', warn_if_missing = False)
		if last_check_attempt:
			last_checked = self.get_last_checked()

			if last_checked < last_check_attempt:
				return last_check_attempt
		return None

	def destroy(self):
		# Check for shell command
		# TODO: remember which commands we own instead of guessing
		name = self.get_name()
		bin_dir = find_bin_dir()
		launcher = os.path.join(bin_dir, name)
		expanded_template = _command_template.format(app = name)
		if os.path.exists(launcher) and os.path.getsize(launcher) == len(expanded_template):
			with open(launcher, 'r') as stream:
				contents = stream.read()
			if contents == expanded_template:
				if self.config.handler.dry_run:
					print(_("[dry-run] would delete launcher script {file}").format(file = launcher))
				else:
					os.unlink(launcher)

		if self.config.handler.dry_run:
			print(_("[dry-run] would delete directory {path}").format(path = self.path))
		else:
			# Remove the app itself
			import shutil
			shutil.rmtree(self.path)

	def integrate_shell(self, name):
		# TODO: remember which commands we create
		if not valid_name.match(name):
			raise SafeException("Invalid shell command name '{name}'".format(name = name))
		bin_dir = find_bin_dir()
		launcher = os.path.join(bin_dir, name)
		if os.path.exists(launcher):
			raise SafeException("Command already exists: {path}".format(path = launcher))

		if self.config.handler.dry_run:
			print(_("[dry-run] would write launcher script {path}").format(path = launcher))
		else:
			with open(launcher, 'w') as stream:
				stream.write(_command_template.format(app = self.get_name()))
				# Make new script executable
				os.chmod(launcher, 0o111 | os.fstat(stream.fileno()).st_mode)

	def get_name(self):
		return os.path.basename(self.path)

	def __str__(self):
		return '<app ' + self.get_name() + '>'

class AppManager:
	def __init__(self, config):
		self.config = config

	def create_app(self, name, requirements):
		validate_name(name)

		apps_dir = basedir.save_config_path(namespaces.config_site, "apps")
		app_dir = os.path.join(apps_dir, name)
		if os.path.isdir(app_dir):
			raise SafeException(_("Application '{name}' already exists: {path}").format(name = name, path = app_dir))

		if self.config.handler.dry_run:
			print(_("[dry-run] would create directory {path}").format(path = app_dir))
		else:
			os.mkdir(app_dir)

		app = App(self.config, app_dir)
		app.set_requirements(requirements)
		app.set_last_checked()

		return app

	def lookup_app(self, name, missing_ok = False):
		"""Get the App for name.
		Returns None if name is not an application (doesn't exist or is not a valid name).
		Since / and : are not valid name characters, it is generally safe to try this
		before calling L{injector.model.canonical_iface_uri}."""
		if not valid_name.match(name):
			if missing_ok:
				return None
			else:
				raise SafeException("Invalid application name '{name}'".format(name = name))
		app_dir = basedir.load_first_config(namespaces.config_site, "apps", name)
		if app_dir:
			return App(self.config, app_dir)
		if missing_ok:
			return None
		else:
			raise SafeException("No such application '{name}'".format(name = name))
