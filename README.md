0install
========

Copyright Thomas Leonard and others, 2013

INTRODUCTION
------------

Zero Install is a decentralised cross-distribution software installation system
available under the LGPL. It allows software developers to publish programs
directly from their own web-sites, while supporting features familiar from
centralised distribution repositories such as shared libraries, automatic
updates and digital signatures. It is intended to complement, rather than
replace, the operating system's package management. 0install packages never
interfere with those provided by the distribution.

0install does not define a new packaging format; unmodified tarballs or zip
archives can be used. Instead, it defines an XML metadata format to describe
these packages and the dependencies between them. A single metadata file can be
used on multiple platforms (e.g. Ubuntu, Debian, Fedora, openSUSE, Mac OS X and
Windows), assuming binary or source archives are available that work on those
systems.

0install also has some interesting features not often found in traditional
package managers. For example, while it will share libraries whenever possible,
it can always install multiple versions of a package in parallel when there are
conflicting requirements. Installation is always side-effect-free (each package
is unpacked to its own directory and will not touch shared directories such as
/usr/bin), making it ideal for use with sandboxing technologies and
virtualisation.

The XML file describing the program's requirements can also be included in a
source-code repository, allowing full dependency handling for unreleased
developer versions. For example, a user can clone a Git repository and build
and test the program, automatically downloading newer versions of libraries
where necessary, without interfering with the versions of those libraries
installed by their distribution, which continue to be used for other software.

See [the 0install.net web-site](http://0install.net/) for full details.


INSTALLATION
------------

0install is written in OCaml. You will need the OCaml build tools and some
OCaml libraries to compile 0install.

The easiest way to get the dependencies is using [OPAM](http://opam.ocamlpro.com/):

    $ opam sw 4.04.0
    $ eval `opam config env`
    $ opam install yojson xmlm ounit lwt_react ocurl obus lablgtk lwt_glib sha

Note: some of these are optional:

- `obus` is used on Linux to add support for D-BUS notifications, installing
  native packages using PackageKit, and using NetworkManager to check
  the network status before doing background updates.
- `lablgtk` and `lwt_glib` provide a GTK GUI.

Alternatively, you can use your distribution's packages if you prefer (and if
they are new enough). For example, on Debian:

    $ sudo apt-get install gettext ocaml-nox ocaml-findlib libyojson-ocaml-dev \
       libxmlm-ocaml-dev camlp4-extra make liblwt-ocaml-dev libounit-ocaml-dev \
       libcurl-ocaml-dev libsha-ocaml-dev \
       libobus-ocaml-dev liblablgtk2-ocaml-dev liblwt-glib-ocaml-dev

On Fedora:

    $ su -c 'yum install gettext ocaml ocaml-findlib ocaml-yojson-devel \
       ocaml-biniou-devel ocaml-easy-format-devel ocaml-xmlm-devel ocaml-camlp4-devel \
       ocaml-lwt-devel ocaml-ounit-devel ocaml-curl-devel \
       ocaml-obus-devel ocaml-lablgtk-devel openssl-devel'

Either way, build and install by running this command in the top-level directory:

    $ make && sudo make install

You can also install just to your home directory (this doesn't require root
access):

    $ make && make install_home
    $ export PATH=$HOME/bin:$PATH

Logging out and back in again will ensure $PATH and the Applications menu get
updated correctly, on Ubuntu at least.

To try 0install without installing:

    $ make
    $ ./dist/files/0install --help

### Windows installation

A C# Windows version of 0install is available at [0install.de](http://0install.de/?lang=en).
This uses some of the OCaml code internally, but adds its own user interface and has better Windows integration.

To compile the OCaml version on Windows (which is currently only really useful if you want to build it for use with the C# code):

1. Install [OPAM for Windows](http://fdopen.github.io/opam-repository-mingw/installation/).
   I used the 64-bit graphical installer.
   Choose a mirror when prompted and select `gnupg` when prompted to select extra packages.
   When this completes, you will have OCaml and a package manager for installing OCaml libraries.

Run the newly installed `Cygwin64 Terminal` application and run these commands at the prompt:

    opam install depext-cygwinports depext
    opam depext 0install
    opam pin -y add -k git 0install .

Notes:

- The binary requires various DLLs to run. Use `cygcheck 0install.exe` to get a list of the ones
  you need and copy them from `/usr/x86_64-w64-mingw32/sys-root/mingw/bin` to the directory containing
  the 0install binary.

- The tests don't currently pass on Windows.

- The native OCaml code cannot currently cope with archives containing
  executable files (with the Unix X bit set) - you'll get the error
  `Incorrect manifest -- archive is corrupted`. When the OCaml version of 0install
  is run under the .NET version, the .NET version sets the environment variable
  `%ZEROINSTALL_EXTERNAL_FETCHER%` to a .NET helper process which does the
  unpacking correctly.

Patches to improve the situation are welcome.


TAB COMPLETION
--------------

A bash completion script is available in share/bash-completion. It can be
sourced from your .bashrc or added under /usr/share/bash-completion. Note that
you may have to install a separate "bash-completion" package on some systems.

For zsh users, copy the script in share/zsh/site-functions/ to a directory in
your $fpath (e.g. /usr/local/share/zsh/site-functions).

For fish-shell users, add the full path to share/fish/completions to
$fish_complete_path.

These completion scripts are installed automatically by "make install".


QUICK START
-----------

To install [Edit](http://rox.sourceforge.net/2005/interfaces/Edit) and name it 'rox-edit':

    $ 0install add rox-edit http://rox.sourceforge.net/2005/interfaces/Edit

To run it (use the name you chose above):

    $ rox-edit

When you run it, 0install will check how long it has been since it checked
for updates and will run a check in the background if it has been too long.
To check for updates manually:

    $ 0install update rox-edit
    http://rox.sourceforge.net/2005/interfaces/ROX-Lib: 2.0.5 -> 2.0.6

This shows that ROX-Lib, a library rox-edit uses, was upgraded.

If an upgrade stops a program from working, use "0install whatchanged".
This will tell you when the application was last upgraded and what changed, and
tells you how to revert to the previous version:

    $ 0install whatchanged rox-edit
    Last checked    : Tue Sep 25 09:45:19 2012
    Last update     : 2012-09-25
    Previous update : 2012-08-25
    
    http://rox.sourceforge.net/2005/interfaces/ROX-Lib: 2.0.5 -> 2.0.6
    
    To run using the previous selections, use:
    0install run /home/tal/.config/0install.net/apps/rox-edit/selections-2012-08-25.xml

To see where things have been stored:

    $ 0install show rox-edit
    - URI: http://rox.sourceforge.net/2005/interfaces/Edit
      Version: 2.2
      Path: /home/tal/.cache/0install.net/implementations/sha256=ba3b4953...c8ce3177f08c926bebafcf16b9
      - URI: http://rox.sourceforge.net/2005/interfaces/ROX-Lib
        Version: 2.0.6
        Path: /home/tal/.cache/0install.net/implementations/sha256=ccefa7b187...16b6d0ad67c4df6d0c06243e
      - URI: http://repo.roscidus.com/python/python
        Version: 2.7.3-4
        Path: (package:deb:python2.7:2.7.3-4:x86_64)

To view or change configuration settings:

    $ 0install config

For more information, see the man-page for 0install and [the 0install.net web-site](http://0install.net/).


CONDITIONS
----------

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307  USA


BUG REPORTS
-----------

Please report any bugs to [the mailing list](http://0install.net/support.html).
