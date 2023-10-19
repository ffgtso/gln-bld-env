# gln-bld-env
Stuff to build our Gluon-based firmwares

Example:

$ cd docker
$ docker build --no-cache --force-rm --quiet --file ./Dockerfile_v2023.1 -t gluon-docker:v2023.1 .
$ cd ..
$ vi mk-ffbog-2023_2-docker.sh # edit MYBUILDDIR, MYBUILDSITEREPO, DOCKERIMAGE
$ cd ..
$ time ./mk-ffbog-2023_2-docker.sh
