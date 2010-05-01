"""
PackageKit integration.
"""

# Copyright (C) 2010, Aleksey Lim
# See the README file for details, or visit http://0install.net.

import os
import dbus
import locale
import logging
import dbus.mainloop.glib
from zeroinstall import _

from zeroinstall.support import tasks
from zeroinstall.injector import download

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
_logger_pk = logging.getLogger('packagekit')
_pending_resolves = {}
_installed = {}
_pk = None

def resolve(package_name, factory):
	if not _check():
		return None

	versions = {}

	def trigger(sender):
		for blocker, __ in _pending_resolves[package_name]:
			blocker.trigger()
		del _pending_resolves[package_name]

	def details_cb(sender):
		if sender.details:
			for id, info in versions.items():
				info.update(sender.details[id])
				for __, factory in _pending_resolves[package_name]:
					factory(id, info['version'], info['size'])
		else:
			_logger_pk.warn(_('Empty details for %s'), package_name)
		trigger(sender)

	def resolve_cb(sender):
		if sender.package:
			versions.update(sender.package)
			tran = _PackageKitTransaction(details_cb, trigger)
			tran.proxy.GetDetails(versions.keys())
		else:
			_logger_pk.warn(_('Empty resolve for %s'), package_name)
			trigger(sender)

	blocker = tasks.Blocker('PackageKit %s' % package_name)

	if package_name in _pending_resolves:
		_pending_resolves[package_name].append((blocker, factory))
	else:
		_logger_pk.debug(_('Ask for %s'), package_name)
		_pending_resolves[package_name] = [(blocker, factory)]
		tran = _PackageKitTransaction(resolve_cb, trigger)
		tran.proxy.Resolve('none', [package_name])

	return blocker

def exists(id):
	return id in _installed

class Download(download.Download):
	def __init__(self, url, hint):
		download.Download.__init__(self, url, hint)

		self._id = url
		self._impl = hint
		self._transaction = None
		self.expected_size = self._impl.size

	def start(self):
		assert self.status == download.download_starting
		assert self.downloaded is None

		def error_cb(sender):
			self.abort()

		def installed_cb(sender):
			_installed[self._id] = True
			self.status = download.download_complete
			self.downloaded.trigger()

		def install_packages():
			package_name = self._id[len('package:'):]
			self._transaction = _PackageKitTransaction(installed_cb, error_cb)
			self._transaction.compat_call('InstallPackages',
					[([package_name]), (False, [package_name])])

		_auth_wrapper(install_packages)

		self.status = download.download_fetching
		self.downloaded = tasks.Blocker('PackageKit install %s' % self._id)

	def abort(self):
		_logger_pk.debug(_('Cancel transaction'))
		self._transaction.proxy.Cancel()
		self.status = download.download_failed
		self.downloaded.trigger()

	def get_current_fraction(self):
		if self._transaction is None:
			return None
		(percentage, subpercentage_, elapsed_, remaining_) = \
				self._transaction.proxy.GetProgress()
		if percentage > 100:
			return None
		else:
			return float(percentage) / 100.

	def get_bytes_downloaded_so_far(self):
		fraction = self.get_current_fraction()
		if fraction is None:
			return 0
		else:
			return int(self.expected_size * fraction)

def _check():
	global _pk

	if _pk is not None:
		return _pk

	try:
		_pk = dbus.Interface(dbus.SystemBus().get_object(
					'org.freedesktop.PackageKit',
					'/org/freedesktop/PackageKit', False),
				'org.freedesktop.PackageKit')
	except:
		_logger_pk.info(_('PackageKit dbus service not found'))
		_pk = False
	else:
		_logger_pk.info(_('PackageKit dbus service found'))

	return _pk

def _auth_wrapper(method, *args):
	try:
		return method(*args)
	except dbus.exceptions.DBusException, e:
		if e.get_dbus_name() != \
				'org.freedesktop.PackageKit.Transaction.RefusedByPolicy':
			raise

		iface, auth = e.get_dbus_message().split()
		if not auth.startswith('auth_'):
			raise

		_logger_pk.debug(_('Authentication required for %s'), auth)

		pk_auth = dbus.SessionBus().get_object(
				'org.freedesktop.PolicyKit.AuthenticationAgent', '/',
				'org.gnome.PolicyKit.AuthorizationManager.SingleInstance')

		if not pk_auth.ObtainAuthorization(iface, dbus.UInt32(0),
				dbus.UInt32(os.getpid()), timeout=300):
			raise

		return method(*args)

class _PackageKitTransaction(object):
	def __init__(self, finished_cb=None, error_cb=None):
		self._finished_cb = finished_cb
		self._error_cb = error_cb
		self._error_code = None
		self.package = {}
		self.details = {}
		self.files = {}

		self.object = dbus.SystemBus().get_object(
				'org.freedesktop.PackageKit', _pk.GetTid(), False)
		self.proxy = dbus.Interface(self.object,
				'org.freedesktop.PackageKit.Transaction')

		for signal, cb in [('Finished', self.__finished_cb),
				   ('ErrorCode', self.__error_code_cb),
				   ('StatusChanged', self.__status_changed_cb),
				   ('Package', self.__package_cb),
				   ('Details', self.__details_cb),
				   ('Files', self.__files_cb)]:
			self.proxy.connect_to_signal(signal, cb)

		self.proxy.SetLocale(locale.getdefaultlocale()[0])

	def compat_call(self, method, arg_sets):
		dbus_method = self.proxy.get_dbus_method(method)
		for args in arg_sets:
			try:
				return dbus_method(*args)
			except dbus.exceptions.DBusException, e:
				if e.get_dbus_name() != \
						'org.freedesktop.DBus.Error.UnknownMethod':
					raise
		raise

	def __finished_cb(self, exit, runtime):
		_logger_pk.debug(_('Transaction finished: %s'), exit)
		if self._error_code is not None:
			self._error_cb(self)
		else:
			self._finished_cb(self)

	def __error_code_cb(self, code, details):
		_logger_pk.warn(_('Transaction failed: %s(%s)'), details, code)
		self._error_code = code

	def __package_cb(self, status, id, summary):
		from zeroinstall.injector.distro import try_cleanup_distro_version

		package_, version, arch_, repo_ = id.split(';')
		clean_version = try_cleanup_distro_version(version)
		if not clean_version:
			_logger_pk.warn(_("Can't parse distribution version '%(version)s' for package '%(package)s'"), {'version': version, 'package': package})
		package = {'version': clean_version,
				   'installed': (status == 'installed')}
		_logger_pk.debug(_('Package: %s %r'), id, package)
		self.package[str(id)] = package

	def __details_cb(self, id, licence, group, detail, url, size):
		details = {'licence': str(licence),
				   'group': str(group),
				   'detail': str(detail),
				   'url': str(url),
				   'size': long(size)}
		_logger_pk.debug(_('Details: %s %r'), id, details)
		self.details[id] = details

	def __files_cb(self, id, files):
		self.files[id] = files.split(';')

	def __status_changed_cb(self, status):
		pass
