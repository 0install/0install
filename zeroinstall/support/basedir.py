"""
Support code for the freedesktop.org basedir spec.

This module provides functions for locating configuration files.

@see: U{http://freedesktop.org/wiki/Standards/basedir-spec}

@var home: The value of $HOME (or '/' if not set). If we're running as root and
$HOME isn't owned by root, then this will be root's home from /etc/passwd
instead.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os

home = os.environ.get('HOME', '/')

try:
	_euid = os.geteuid()
except AttributeError:
	pass	# Windows?
else:
	if _euid == 0:
		# We're running as root. Ensure that $HOME really is root's home,
		# not the user's home, or we're likely to fill it will unreadable
		# root-owned files.
		home_owner = os.stat(home).st_uid
		if home_owner != 0:
			import pwd
			from logging import info
			old_home = home
			home = pwd.getpwuid(0).pw_dir or '/'
			info(_("$HOME (%(home)s) is owned by user %(user)d, but we are root (0). Using %(root_home)s instead."), {'home': old_home, 'user': home_owner, 'root_home': home})
			del old_home
			del home_owner

portable_base = os.environ.get('ZEROINSTALL_PORTABLE_BASE')
if portable_base:
	xdg_data_dirs = [os.path.join(portable_base, "data")]
	xdg_cache_dirs = [os.path.join(portable_base, "cache")]
	xdg_config_dirs = [os.path.join(portable_base, "config")]
else:
	if os.name == "nt":
		from win32com.shell import shell, shellcon
		appData = shell.SHGetFolderPath(0, shellcon.CSIDL_APPDATA, 0, 0)
		localAppData = shell.SHGetFolderPath(0, shellcon.CSIDL_LOCAL_APPDATA, 0, 0)
		commonAppData = shell.SHGetFolderPath(0, shellcon.CSIDL_COMMON_APPDATA, 0, 0)

		_default_paths = {
			'DATA' : [appData, commonAppData],
			'CACHE' : [localAppData, commonAppData],
			'CONFIG' : [appData, commonAppData],
		}
	else:
		_default_paths = {
			'DATA' : [os.path.join(home, '.local', 'share'), '/usr/local/share', '/usr/share'],
			'CACHE' : [os.path.join(home, '.cache'), '/var/cache'],
			'CONFIG' : [os.path.join(home, '.config'), '/etc/xdg'],
		}

	def _get_path(home_var, dirs_var, default_paths):
		paths = default_paths

		x = os.environ.get(home_var, None)
		if x is not None:
			paths[0] = x

		x = os.environ.get(dirs_var, None)
		if x is not None:
			paths[1:] = filter(None, x.split(os.path.pathsep))

		return paths

	xdg_data_dirs = _get_path('XDG_DATA_HOME', 'XDG_DATA_DIRS', _default_paths['DATA'])
	xdg_cache_dirs = _get_path('XDG_CACHE_HOME', 'XDG_CACHE_DIRS', _default_paths['CACHE'])
	xdg_config_dirs = _get_path('XDG_CONFIG_HOME', 'XDG_CONFIG_DIRS', _default_paths['CONFIG'])

# Maybe we should get rid of these?
xdg_data_home = xdg_data_dirs[0]
xdg_cache_home = xdg_cache_dirs[0]
xdg_config_home = xdg_config_dirs[0]

def save_config_path(*resource):
	"""Ensure $XDG_CONFIG_HOME/<resource>/ exists, and return its path.
	'resource' should normally be the name of your application. Use this
	when SAVING configuration settings. Use the xdg_config_dirs variable
	for loading."""
	resource = os.path.join(*resource)
	assert not os.path.isabs(resource)
	path = os.path.join(xdg_config_home, resource)
	if not os.path.isdir(path):
		os.makedirs(path, 0o700)
	return path

def load_config_paths(*resource):
	"""Returns an iterator which gives each directory named 'resource' in the
	configuration search path. Information provided by earlier directories should
	take precedence over later ones (ie, the user's config dir comes first)."""
	resource = os.path.join(*resource)
	for config_dir in xdg_config_dirs:
		path = os.path.join(config_dir, resource)
		if os.path.exists(path): yield path

def load_first_config(*resource):
	"""Returns the first result from load_config_paths, or None if there is nothing
	to load."""
	for x in load_config_paths(*resource):
		return x
	return None

def save_cache_path(*resource):
	"""Ensure $XDG_CACHE_HOME/<resource>/ exists, and return its path.
	'resource' should normally be the name of your application."""
	resource = os.path.join(*resource)
	assert not os.path.isabs(resource)
	path = os.path.join(xdg_cache_home, resource)
	if not os.path.isdir(path):
		os.makedirs(path, 0o700)
	return path

def load_cache_paths(*resource):
	"""Returns an iterator which gives each directory named 'resource' in the
	cache search path. Information provided by earlier directories should
	take precedence over later ones (ie, the user's cache dir comes first)."""
	resource = os.path.join(*resource)
	for cache_dir in xdg_cache_dirs:
		path = os.path.join(cache_dir, resource)
		if os.path.exists(path): yield path

def load_first_cache(*resource):
	"""Returns the first result from load_cache_paths, or None if there is nothing
	to load."""
	for x in load_cache_paths(*resource):
		return x
	return None

def load_data_paths(*resource):
	"""Returns an iterator which gives each directory named 'resource' in the
	shared data search path. Information provided by earlier directories should
	take precedence over later ones.
	@since: 0.28"""
	resource = os.path.join(*resource)
	for data_dir in xdg_data_dirs:
		path = os.path.join(data_dir, resource)
		if os.path.exists(path): yield path

def load_first_data(*resource):
	"""Returns the first result from load_data_paths, or None if there is nothing
	to load.
	@since: 0.28"""
	for x in load_data_paths(*resource):
		return x
	return None
