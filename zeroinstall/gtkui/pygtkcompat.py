# -*- Mode: Python; py-indent-offset: 4 -*-
# vim: tabstop=4 shiftwidth=4 expandtab
#
# Copyright (C) 2011-2012 Johan Dahlin <johan@gnome.org>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301
# USA

"""
PyGTK compatibility layer.

This modules goes a little bit longer to maintain PyGTK compatibility than
the normal overrides system.

It is recommended to not depend on this layer, but only use it as an
intermediate step when porting your application to PyGI.

Compatibility might never be 100%, but the aim is to make it possible to run
a well behaved PyGTK application mostly unmodified on top of PyGI.

"""

import sys
import warnings

try:
    # Python 3
    from collections import UserList
    from imp import reload
    UserList  # pyflakes
except ImportError:
    # Python 2 ships that in a different module
    from UserList import UserList
    UserList  # pyflakes

import gi
from gi.repository import GObject


def _install_enums(module, dest=None, strip=''):
    if dest is None:
        dest = module
    modname = dest.__name__.rsplit('.', 1)[1].upper()
    for attr in dir(module):
        try:
            obj = getattr(module, attr, None)
        except:
            continue
        try:
            if issubclass(obj, GObject.GEnum):
                for value, enum in obj.__enum_values__.items():
                    name = enum.value_name
                    name = name.replace(modname + '_', '')
                    if strip and name.startswith(strip):
                        name = name[len(strip):]
                    setattr(dest, name, enum)
        except TypeError:
            continue
        try:
            if issubclass(obj, GObject.GFlags):
                for value, flag in obj.__flags_values__.items():
                    name = flag.value_names[-1].replace(modname + '_', '')
                    setattr(dest, name, flag)
        except TypeError:
            continue


def enable():
    # gobject
    from gi.repository import GLib
    sys.modules['glib'] = GLib

    # gobject
    from gi.repository import GObject
    sys.modules['gobject'] = GObject
    #from gi._gobject import propertyhelper
    #sys.modules['gobject.propertyhelper'] = propertyhelper

    # gio
    from gi.repository import Gio
    sys.modules['gio'] = Gio

_unset = object()


def enable_gtk(version='2.0'):
    # set the default encoding like PyGTK
    reload(sys)
    if sys.version_info < (3, 0):
        sys.setdefaultencoding('utf-8')

    # atk
    gi.require_version('Atk', '1.0')
    from gi.repository import Atk
    sys.modules['atk'] = Atk
    _install_enums(Atk)

    # pango
    gi.require_version('Pango', '1.0')
    from gi.repository import Pango
    sys.modules['pango'] = Pango
    _install_enums(Pango)

    # pangocairo
    gi.require_version('PangoCairo', '1.0')
    from gi.repository import PangoCairo
    sys.modules['pangocairo'] = PangoCairo

    # gdk
    gi.require_version('Gdk', version)
    gi.require_version('GdkPixbuf', '2.0')
    from gi.repository import Gdk
    from gi.repository import GdkPixbuf
    sys.modules['gtk.gdk'] = Gdk
    _install_enums(Gdk)
    _install_enums(GdkPixbuf, dest=Gdk)
    Gdk._2BUTTON_PRESS = 5
    Gdk.BUTTON_PRESS = 4

    Gdk.screen_get_default = Gdk.Screen.get_default
    Gdk.Pixbuf = GdkPixbuf.Pixbuf
    Gdk.pixbuf_new_from_file = GdkPixbuf.Pixbuf.new_from_file
    Gdk.PixbufLoader = GdkPixbuf.PixbufLoader.new_with_type

    orig_get_formats = GdkPixbuf.Pixbuf.get_formats

    def get_formats():
        formats = orig_get_formats()
        result = []

        def make_dict(format_):
            result = {}
            result['description'] = format_.get_description()
            result['name'] = format_.get_name()
            result['mime_types'] = format_.get_mime_types()
            result['extensions'] = format_.get_extensions()
            return result

        for format_ in formats:
            result.append(make_dict(format_))
        return result

    Gdk.pixbuf_get_formats = get_formats

    orig_get_frame_extents = Gdk.Window.get_frame_extents

    def get_frame_extents(window):
        try:
            try:
                rect = Gdk.Rectangle(0, 0, 0, 0)
            except TypeError:
                rect = Gdk.Rectangle()
            orig_get_frame_extents(window, rect)
        except TypeError:
            rect = orig_get_frame_extents(window)
        return rect
    Gdk.Window.get_frame_extents = get_frame_extents

    orig_get_origin = Gdk.Window.get_origin

    def get_origin(self):
        return orig_get_origin(self)[1:]
    Gdk.Window.get_origin = get_origin

    Gdk.screen_width = Gdk.Screen.width
    Gdk.screen_height = Gdk.Screen.height

    # gtk
    gi.require_version('Gtk', version)
    from gi.repository import Gtk
    sys.modules['gtk'] = Gtk
    Gtk.gdk = Gdk

    Gtk.pygtk_version = (2, 99, 0)

    Gtk.gtk_version = (Gtk.MAJOR_VERSION,
                       Gtk.MINOR_VERSION,
                       Gtk.MICRO_VERSION)
    _install_enums(Gtk)

    # Action

    def set_tool_item_type(menuaction, gtype):
        warnings.warn('set_tool_item_type() is not supported',
                      DeprecationWarning, stacklevel=2)
    Gtk.Action.set_tool_item_type = classmethod(set_tool_item_type)

    # Alignment

    orig_Alignment = Gtk.Alignment

    class Alignment(orig_Alignment):
        def __init__(self, xalign=0.0, yalign=0.0, xscale=0.0, yscale=0.0):
            orig_Alignment.__init__(self)
            self.props.xalign = xalign
            self.props.yalign = yalign
            self.props.xscale = xscale
            self.props.yscale = yscale

    Gtk.Alignment = Alignment

    # Box

    orig_pack_end = Gtk.Box.pack_end

    def pack_end(self, child, expand=True, fill=True, padding=0):
        orig_pack_end(self, child, expand, fill, padding)
    Gtk.Box.pack_end = pack_end

    orig_pack_start = Gtk.Box.pack_start

    def pack_start(self, child, expand=True, fill=True, padding=0):
        orig_pack_start(self, child, expand, fill, padding)
    Gtk.Box.pack_start = pack_start

    # TreeViewColumn

    orig_tree_view_column_pack_end = Gtk.TreeViewColumn.pack_end

    def tree_view_column_pack_end(self, cell, expand=True):
        orig_tree_view_column_pack_end(self, cell, expand)
    Gtk.TreeViewColumn.pack_end = tree_view_column_pack_end

    orig_tree_view_column_pack_start = Gtk.TreeViewColumn.pack_start

    def tree_view_column_pack_start(self, cell, expand=True):
        orig_tree_view_column_pack_start(self, cell, expand)
    Gtk.TreeViewColumn.pack_start = tree_view_column_pack_start

    # TreeView

    def insert_column_with_attributes(view, position, title, cell, *args, **kwargs):
        pass
    Gtk.TreeView.insert_column_with_attributes = insert_column_with_attributes

    # CellLayout

    orig_cell_pack_end = Gtk.CellLayout.pack_end

    def cell_pack_end(self, cell, expand=True):
        orig_cell_pack_end(self, cell, expand)
    Gtk.CellLayout.pack_end = cell_pack_end

    orig_cell_pack_start = Gtk.CellLayout.pack_start

    def cell_pack_start(self, cell, expand=True):
        orig_cell_pack_start(self, cell, expand)
    Gtk.CellLayout.pack_start = cell_pack_start

    orig_set_cell_data_func = Gtk.CellLayout.set_cell_data_func

    def set_cell_data_func(self, cell, func, user_data=_unset):
        def callback(*args):
            if args[-1] == _unset:
                args = args[:-1]
            return func(*args)
        orig_set_cell_data_func(self, cell, callback, user_data)
    Gtk.CellLayout.set_cell_data_func = set_cell_data_func

    # CellRenderer

    class GenericCellRenderer(Gtk.CellRenderer):
        pass
    Gtk.GenericCellRenderer = GenericCellRenderer

    # ComboBox

    orig_combo_row_separator_func = Gtk.ComboBox.set_row_separator_func

    def combo_row_separator_func(self, func, user_data=_unset):
        def callback(*args):
            if args[-1] == _unset:
                args = args[:-1]
            return func(*args)
        orig_combo_row_separator_func(self, callback, user_data)
    Gtk.ComboBox.set_row_separator_func = combo_row_separator_func

    # ComboBoxEntry

    class ComboBoxEntry(Gtk.ComboBox):
        def __init__(self, **kwds):
            Gtk.ComboBox.__init__(self, has_entry=True, **kwds)

        def set_text_column(self, text_column):
            self.set_entry_text_column(text_column)

        def get_text_column(self):
            return self.get_entry_text_column()
    Gtk.ComboBoxEntry = ComboBoxEntry

    def combo_box_entry_new():
        return Gtk.ComboBoxEntry()
    Gtk.combo_box_entry_new = combo_box_entry_new

    def combo_box_entry_new_with_model(model):
        return Gtk.ComboBoxEntry(model=model)
    Gtk.combo_box_entry_new_with_model = combo_box_entry_new_with_model

    # Container

    def install_child_property(container, flag, pspec):
        warnings.warn('install_child_property() is not supported',
                      DeprecationWarning, stacklevel=2)
    Gtk.Container.install_child_property = classmethod(install_child_property)

    def new_text():
        combo = Gtk.ComboBox()
        model = Gtk.ListStore(str)
        combo.set_model(model)
        combo.set_entry_text_column(0)
        return combo
    Gtk.combo_box_new_text = new_text

    def append_text(self, text):
        model = self.get_model()
        model.append([text])
    Gtk.ComboBox.append_text = append_text
    Gtk.expander_new_with_mnemonic = Gtk.Expander.new_with_mnemonic
    Gtk.icon_theme_get_default = Gtk.IconTheme.get_default
    Gtk.image_new_from_pixbuf = Gtk.Image.new_from_pixbuf
    Gtk.image_new_from_stock = Gtk.Image.new_from_stock
    Gtk.image_new_from_animation = Gtk.Image.new_from_animation
    Gtk.image_new_from_icon_set = Gtk.Image.new_from_icon_set
    Gtk.image_new_from_file = Gtk.Image.new_from_file
    Gtk.settings_get_default = Gtk.Settings.get_default
    Gtk.window_set_default_icon = Gtk.Window.set_default_icon
    Gtk.clipboard_get = Gtk.Clipboard.get

    #AccelGroup
    Gtk.AccelGroup.connect_group = Gtk.AccelGroup.connect

    #StatusIcon
    Gtk.status_icon_position_menu = Gtk.StatusIcon.position_menu
    Gtk.StatusIcon.set_tooltip = Gtk.StatusIcon.set_tooltip_text

    # Scale

    orig_HScale = Gtk.HScale
    orig_VScale = Gtk.VScale

    class HScale(orig_HScale):
        def __init__(self, adjustment=None):
            orig_HScale.__init__(self, adjustment=adjustment)
    Gtk.HScale = HScale

    class VScale(orig_VScale):
        def __init__(self, adjustment=None):
            orig_VScale.__init__(self, adjustment=adjustment)
    Gtk.VScale = VScale

    Gtk.stock_add = lambda items: None

    # Widget

    Gtk.widget_get_default_direction = Gtk.Widget.get_default_direction
    orig_size_request = Gtk.Widget.size_request

    def size_request(widget):
        class SizeRequest(UserList):
            def __init__(self, req):
                self.height = req.height
                self.width = req.width
                UserList.__init__(self, [self.width, self.height])
        return SizeRequest(orig_size_request(widget))
    Gtk.Widget.size_request = size_request
    Gtk.Widget.hide_all = Gtk.Widget.hide

    class BaseGetter(object):
        def __init__(self, context):
            self.context = context

        def __getitem__(self, state):
            color = self.context.get_background_color(state)
            return Gdk.Color(red=int(color.red * 65535),
                             green=int(color.green * 65535),
                             blue=int(color.blue * 65535))

    class Styles(object):
        def __init__(self, widget):
            context = widget.get_style_context()
            self.base = BaseGetter(context)
            self.black = Gdk.Color(red=0, green=0, blue=0)

    class StyleDescriptor(object):
        def __get__(self, instance, class_):
            return Styles(instance)
    Gtk.Widget.style = StyleDescriptor()

    # gtk.unixprint

    class UnixPrint(object):
        pass
    unixprint = UnixPrint()
    sys.modules['gtkunixprint'] = unixprint

    # gtk.keysyms

    class Keysyms(object):
        pass
    keysyms = Keysyms()
    sys.modules['gtk.keysyms'] = keysyms
    Gtk.keysyms = keysyms
    for name in dir(Gdk):
        if name.startswith('KEY_'):
            target = name[4:]
            if target[0] in '0123456789':
                target = '_' + target
            value = getattr(Gdk, name)
            setattr(keysyms, target, value)

    Gtk.TreePath.__len__ = lambda path: path.get_depth()

def enable_vte():
    gi.require_version('Vte', '0.0')
    from gi.repository import Vte
    sys.modules['vte'] = Vte


def enable_poppler():
    gi.require_version('Poppler', '0.18')
    from gi.repository import Poppler
    sys.modules['poppler'] = Poppler
    Poppler.pypoppler_version = (1, 0, 0)


def enable_webkit(version='1.0'):
    gi.require_version('WebKit', version)
    from gi.repository import WebKit
    sys.modules['webkit'] = WebKit
    WebKit.WebView.get_web_inspector = WebKit.WebView.get_inspector


def enable_gudev():
    gi.require_version('GUdev', '1.0')
    from gi.repository import GUdev
    sys.modules['gudev'] = GUdev


def enable_gst():
    gi.require_version('Gst', '0.10')
    from gi.repository import Gst
    sys.modules['gst'] = Gst
    _install_enums(Gst)
    Gst.registry_get_default = Gst.Registry.get_default
    Gst.element_register = Gst.Element.register
    Gst.element_factory_make = Gst.ElementFactory.make
    Gst.caps_new_any = Gst.Caps.new_any
    Gst.get_pygst_version = lambda: (0, 10, 19)
    Gst.get_gst_version = lambda: (0, 10, 40)

    from gi.repository import GstInterfaces
    sys.modules['gst.interfaces'] = GstInterfaces
    _install_enums(GstInterfaces)

    from gi.repository import GstAudio
    sys.modules['gst.audio'] = GstAudio
    _install_enums(GstAudio)

    from gi.repository import GstVideo
    sys.modules['gst.video'] = GstVideo
    _install_enums(GstVideo)

    from gi.repository import GstBase
    sys.modules['gst.base'] = GstBase
    _install_enums(GstBase)

    Gst.BaseTransform = GstBase.BaseTransform
    Gst.BaseSink = GstBase.BaseSink

    from gi.repository import GstController
    sys.modules['gst.controller'] = GstController
    _install_enums(GstController, dest=Gst)

    from gi.repository import GstPbutils
    sys.modules['gst.pbutils'] = GstPbutils
    _install_enums(GstPbutils)


def enable_goocanvas():
    gi.require_version('GooCanvas', '2.0')
    from gi.repository import GooCanvas
    sys.modules['goocanvas'] = GooCanvas
    _install_enums(GooCanvas, strip='GOO_CANVAS_')
    GooCanvas.ItemSimple = GooCanvas.CanvasItemSimple
    GooCanvas.Item = GooCanvas.CanvasItem
    GooCanvas.Image = GooCanvas.CanvasImage
    GooCanvas.Group = GooCanvas.CanvasGroup
    GooCanvas.Rect = GooCanvas.CanvasRect
