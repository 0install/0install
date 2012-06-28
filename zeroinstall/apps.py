"""
Support for managing apps (as created with "0install add").
@since: 1.9
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, SafeException
from zeroinstall.support import basedir, portable_rename
from zeroinstall.injector import namespaces, selections, qdom
from logging import warn, info
import re, os, time, tempfile

# Avoid characters that are likely to cause problems (reject : and ; everywhere
# so that apps can be portable between POSIX and Windows).
valid_name = re.compile(r'''^[^./\\:=;'"][^/\\:=;'"]*$''')

def validate_name(name):
	if valid_name.match(name): return
	raise SafeException("Invalid application name '{name}'".format(name = name))

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
		return None

	return path

_command_template = """#!/bin/sh
exec 0install run {app} "$@"
"""

class App:
	def __init__(self, config, path):
		self.config = config
		self.path = path

	def set_selections(self, sels):
		"""Store a new set of selections. We include today's date in the filename
		so that we keep a history of previous selections (max one per day), in case
		we want to to roll back later."""
		date = time.strftime('%Y-%m-%d')
		sels_file = os.path.join(self.path, 'selections-{date}.xml'.format(date = date))
		dom = sels.toDOM()

		tmp = tempfile.NamedTemporaryFile(prefix = 'selections.xml-', dir = self.path, delete = False)
		try:
			dom.writexml(tmp, addindent="  ", newl="\n", encoding = 'utf-8')
		except:
			tmp.close()
			os.unlink(tmp.name)
			raise
		tmp.close()
		portable_rename(tmp.name, sels_file)

		sels_latest = os.path.join(self.path, 'selections.xml')
		if os.path.exists(sels_latest):
			os.unlink(sels_latest)
		os.symlink(os.path.basename(sels_file), sels_latest)

		self.set_last_checked()

	def get_selections(self, snapshot_date = None):
		"""Load the selections. Does not check whether they are cached, nor trigger updates.
		@param snapshot_date: get a historical snapshot
		@type snapshot_date: (as returned by L{get_history}) | None
		@return: the selections
		@rtype: L{selections.Selections}"""
		if snapshot_date:
			sels_file = os.path.join(self.path, 'selections-' + snapshot_date + '.xml')
		else:
			sels_file = os.path.join(self.path, 'selections.xml')
		with open(sels_file) as stream:
			return selections.Selections(qdom.parse(stream))

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
		"""Download any missing implementations in the given selections.
		If no downloads are needed, but we haven't checked for a while, start
		a background process to check for updates (but return None immediately).
		@return: a blocker which resolves when all needed implementations are available
		@rtype: L{tasks.Blocker} | None
		"""
		# Check the selections are still available
		blocker = sels.download_missing(self.config)	# TODO: package impls

		if blocker:
			return blocker
		else:
			# Nothing to download, but is it time for a background update?
			timestamp_path = os.path.join(self.path, 'last-checked')
			try:
				utime = os.stat(timestamp_path).st_mtime
				staleness = time.time() - utime
				info("Staleness of app %s is %d hours", self, staleness / (60 * 60))
				freshness_threshold = self.config.freshness
				need_update = freshness_threshold > 0 and staleness >= freshness_threshold

				if need_update:
					last_check_attempt_path = os.path.join(self.path, 'last-check-attempt')
					if os.path.exists(last_check_attempt_path):
						last_check_attempt = os.stat(last_check_attempt_path).st_mtime
						if last_check_attempt + 60 * 60 > time.time():
							info("Tried to check within last hour; not trying again now")
							need_update = False
			except Exception as ex:
				warn("Failed to get time-stamp of %s: %s", timestamp_path, ex)
				need_update = True

			if need_update:
				self.set_last_check_attempt()
				from zeroinstall.injector import background
				r = self.get_requirements()
				background.spawn_background_update2(r, True, self)

	def set_requirements(self, requirements):
		import json
		tmp = tempfile.NamedTemporaryFile(prefix = 'tmp-requirements-', dir = self.path, delete = False)
		try:
			json.dump(dict((key, getattr(requirements, key)) for key in requirements.__slots__), tmp)
		except:
			tmp.close()
			os.unlink(tmp.name)
			raise
		tmp.close()

		reqs_file = os.path.join(self.path, 'requirements.json')
		portable_rename(tmp.name, reqs_file)

	def get_requirements(self):
		import json
		from zeroinstall.injector import requirements
		r = requirements.Requirements(None)
		reqs_file = os.path.join(self.path, 'requirements.json')
		with open(reqs_file) as stream:
			values = json.load(stream)
		for k, v in values.items():
			setattr(r, k, v)
		return r

	def set_last_check_attempt(self):
		timestamp_path = os.path.join(self.path, 'last-check-attempt')
		fd = os.open(timestamp_path, os.O_WRONLY | os.O_CREAT, 0o644)
		os.close(fd)
		os.utime(timestamp_path, None)	# In case file already exists

	def get_last_checked(self):
		"""Get the time of the last successful check for updates.
		@return: the timestamp (or None on error)
		@rtype: float | None"""
		last_updated_path = os.path.join(self.path, 'last-checked')
		try:
			return os.stat(last_updated_path).st_mtime
		except Exception as ex:
			warn("Failed to get time-stamp of %s: %s", last_updated_path, ex)
			return None

	def get_last_check_attempt(self):
		"""Get the time of the last attempted check.
		@return: the timestamp, or None if we updated successfully.
		@rtype: float | None"""
		last_check_attempt_path = os.path.join(self.path, 'last-check-attempt')
		if os.path.exists(last_check_attempt_path):
			last_check_attempt = os.stat(last_check_attempt_path).st_mtime

			last_checked = self.get_last_checked()

			if last_checked < last_check_attempt:
				return last_check_attempt
		return None

	def set_last_checked(self):
		timestamp_path = os.path.join(self.path, 'last-checked')
		fd = os.open(timestamp_path, os.O_WRONLY | os.O_CREAT, 0o644)
		os.close(fd)
		os.utime(timestamp_path, None)	# In case file already exists

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
				#print "rm", launcher
				os.unlink(launcher)

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
