# Build on a really old system to avoid glibc symbol version problems.
FROM ocaml/opam:debian-10-ocaml-4.14
RUN sudo apt-get update && sudo apt-get -y install ca-certificates build-essential libglib2.0-dev libgtk-3-dev m4 pkg-config libexpat1-dev unzip gnupg wget --no-install-recommends
WORKDIR /src
RUN sudo chown opam /src
RUN wget https://www.openssl.org/source/openssl-1.1.1q.tar.gz -O openssl.tgz
RUN tar xf openssl.tgz
# Install openssl from source without dynamic libraries. This is the easiest way to force it to be linked statically.
RUN cd openssl-1.1.1q && ./config no-dgram no-dso no-dynamic-engine no-engine no-shared no-tests && make && sudo make install
RUN sudo ln -sf /usr/bin/opam-2.1 /usr/bin/opam
RUN opam install yojson xmlm ounit lwt_react cohttp-lwt-unix lwt_ssl obus lablgtk3 lwt_glib sha dune
COPY --chown=opam . /src/
RUN opam exec -- make
RUN ldd /src/dist/files/0install
RUN strip /src/dist/files/0install
