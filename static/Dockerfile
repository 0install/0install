# Build on a really old system to avoid glibc symbol version problems.
FROM ubuntu:14.04
RUN sudo apt-get update && sudo apt-get -y install ca-certificates build-essential libglib2.0-dev libgtk2.0-dev m4 pkg-config libexpat1-dev unzip gnupg wget --no-install-recommends
WORKDIR /src
RUN wget https://www.openssl.org/source/openssl-1.1.1d.tar.gz -O openssl.tgz
RUN tar xf openssl.tgz
# Install openssl from source without dynamic libraries. This is the easiest way to force it to be linked statically.
RUN cd openssl-1.1.1d && ./config no-dgram no-dso no-dynamic-engine no-engine no-shared no-tests && make && sudo make install
RUN wget https://github.com/ocaml/opam/releases/download/2.0.5/opam-2.0.5-x86_64-linux -O /usr/local/bin/opam
RUN chmod a+x /usr/local/bin/opam
RUN opam init --compiler=4.08.1 --disable-sandboxing
ENV OPAMYES="1" OPAMERRLOGLEN="0"
RUN opam install yojson xmlm ounit lwt_react cohttp-lwt-unix lwt_ssl obus lablgtk lwt_glib sha dune
COPY . /src/
RUN opam exec -- make
RUN ldd /src/dist/files/0install
RUN strip /src/dist/files/0install
