#!/bin/bash
MYBUILDROOT=$(pwd)
MYBUILDDIR=ffbog-v2023.1
MYBUILDSITEREPO=https://github.com/ffgtso/site-ffbog-v2023.2.git
DOCKERIMAGE=gluon-docker:v2023.1

if [ ! -d ${MYBUILDDIR} ]; then
    mkdir ${MYBUILDDIR}
    if [ -e baserelease.txt ]; then
	mv baserelease.txt ${MYBUILDDIR}/
    fi
    if [ -e buildnumber.txt ]; then
	mv buildnumber.txt ${MYBUILDDIR}/
    fi
fi

cd ${MYBUILDDIR}

# Preparations ...
# Prep counters for RELEASE number

if [ ! -e baserelease.txt ]; then
    echo "1.6.0~" >baserelease.txt
fi

if [ ! -e buildnumber.txt ]; then
    echo "0" >buildnumber.txt
fi
if [ -d ffgt_packages-v2020.1 ]; then
    /bin/rm -rf ffgt_packages-v2020.1
fi

# Get our package repos's current commit — we build always our latest and greatest code ;)

git clone https://github.com/wusel42/ffgt_packages-v2020.1.git || exit 1
if [ -d ffgt_packages-v2020.1 ]; then
  PKGLIVECOMMIT="`(cd ffgt_packages-v2020.1; git rev-parse HEAD)`"
  /bin/rm -rf ffgt_packages-v2020.1
else
  echo
  echo "There a glitch in the Matrix, aborting."
  echo
  exit 1
fi

# Now clone or update the site repo used to/in site-ffgt

if [ ! -d site-ffgt ]; then
    git clone ${MYBUILDSITEREPO} site-ffgt || exit 1
else
    (cd site-ffgt && git stash && git pull || exit 1)
    RC=$?
    if [ $RC -ne 0 ]; then
        echo
	echo "git pull failed, aborting."
	echo
	exit $RC
    fi
fi

# FIXME: BASEPATH==MYBUILDDIR, right?
BASEPATH="$(pwd)"

# Compute build environment

MYBUILDNBR="`cat buildnumber.txt`"
RELEASE="`cat baserelease.txt`${MYBUILDNBR}"

export RELEASE
export GLUON_RELEASE="${RELEASE}"
export GLUON_AUTOUPDATER_BRANCH=stable
export GLUON_AUTOUPDATER_ENABLED=1
export GLUON_LANGS="de en"
export AVAILCORES="$(grep ^processor </proc/cpuinfo | wc -l)"
export USEnCORES=$(expr ${AVAILCORES} \* 3)
if [ -z "${USEnCORES}" ]; then
    export USEnCORES=4
fi
export JOBS=${USEnCORES}

# Build documentation

export STARTTIME="$(date +%s)"
export SOURCE_DATE_EPOCH="${STARTTIME}"

echo "Build for ${RELEASE} started at $(date) on $(uname -n)." >/tmp/build-${RELEASE}.txt
echo >>/tmp/build-${RELEASE}.txt
lscpu >>/tmp/build-${RELEASE}.txt
echo >>/tmp/build-${RELEASE}.txt
free -h >>/tmp/build-${RELEASE}.txt
echo >>/tmp/build-${RELEASE}.txt
cat /dev/null >/tmp/build-${RELEASE}.log

# Enter site directory to prepare the build (download & patch Gluon)

cd site-ffgt

# Patch PACKAGES_FFGT_COMMIT

sed -e "s/PACKAGES_FFGT_COMMIT=.*$/PACKAGES_FFGT_COMMIT=${PKGLIVECOMMIT}/" -i modules

# Temporary files (logs) created during Docker runs

if [ ! -d build_tmp ]; then
  mkdir build_tmp
fi

# Create a sourceable file with the environment variables

cat <<EOF >docker-build-env
export RELEASE=${RELEASE}
export GLUON_RELEASE=${RELEASE}
export GLUON_AUTOUPDATER_BRANCH=stable
export GLUON_AUTOUPDATER_ENABLED=1
export GLUON_LANGS="de en"
export JOBS=${USEnCORES}
EOF

# Docker builds in /gluon which is ${MYBUILDROOT}, so adjust paths ...

INDOCKERPATH=$(pwd | sed -e s%${MYBUILDROOT}%/gluon%g)

# Create Docker script to prepare our source tree (download & patch Gluon)

cat <<EOF >docker-build.sh
#!/bin/bash

cd $(pwd | sed -e s%${MYBUILDROOT}%/gluon%g)

. $(pwd | sed -e s%${MYBUILDROOT}%/gluon%g)/docker-build-env
make gluon-prepare output-clean 2>&1 | tee make-prepare.log
EOF
chmod +x docker-build.sh
docker run -it --hostname gluon.docker --rm -u "$(id -u):$(id -g)" --volume="${MYBUILDROOT}:/gluon" -e HOME=/gluon ${DOCKERIMAGE} ${INDOCKERPATH}/docker-build.sh
RC=$?
if [ $RC -ne 0 ]; then
  echo "Error running make in docker, RC $RC." | tee -a make.log
  exit $RC
fi

# Link gluon-build/site to ${MYBUILDROOT}, relative from site-ffgt/gluon-build

if [ ! -e gluon-build/site ]; then
  ln -s ../../site-ffgt gluon-build/site
fi

# We count the builds ...

echo "1" >lfdtgtnr

# FIXME, reduce to 1 target due to the fucking Gluon/OpenWrt build errors ...
echo "ath79-generic" > build-targets.list

if [ ! -e build-targets.list ]; then
  echo "$0: missing my build-targets.list, aborting."
  exit 1
fi

# The build loop: We maintain build-targets.list with all targets we are interessted in.
# Each target is build within our Docker container, inside $(pwd)/gluon-build (with
# $(pwd) being ${MYBUILDROOT}/site-ffgt), just as suppessted in Gluon's documentation.

for target in $(cat build-targets.list)
do
  cat <<EOF >docker-build.sh
#!/bin/bash

cd $(pwd | sed -e s%${MYBUILDROOT}%/gluon%g)/gluon-build

. $(pwd | sed -e s%${MYBUILDROOT}%/gluon%g)/docker-build-env
make -j \${JOBS} V=sc GLUON_TARGET=${target} 2>&1 | tee ../build_${target}.log
EOF
  chmod +x docker-build.sh

  echo "Starting Docker based build for ${target} ..."
  date +%s >lastbuildstart;
  docker run -it --hostname gluon.docker --rm -u "$(id -u):$(id -g)" --volume="${MYBUILDROOT}:/gluon" -e HOME=/gluon ${DOCKERIMAGE} ${INDOCKERPATH}/docker-build.sh
  RC=$?
  ./log_status.sh "$target" $RC

  if [ $RC -ne 0 ]; then
    echo "Error running build of $target in docker, RC $RC." | tee -a make.log
    exit $RC
  fi
  lfdtgtnr=$(expr ${lfdtgtnr} + 1)
done

# After we've successfully build the stuff (did we?), notify & upload

FFGTPKGCOMMIT="$(cd gluon-build/openwrt/feeds/ffgt 2>/dev/null; git rev-parse HEAD 2>/dev/null)"
FFGTSITECOMMIT="$(git rev-parse HEAD)"
GLUONBASECOMMIT="$(cd gluon-build ; git rev-parse HEAD)"

NumImg=$(ls -lh output/images/factory/ 2>/dev/null | grep gluon- | wc -l)

ENDTIME="$(date +%s)"
BUILDMINS="$(expr ${ENDTIME} - ${STARTTIME} | awk '{printf("%.0f", $1/60);}')"

export RELEASE
export NumImg
export BUILDMINS
(echo "From: technik@guetersloh.freifunk.net (FFGT Technik)" ; \
echo "To: wusel@4830.org" ; \
echo "Content-Type: text/plain; charset=utf-8" ; \
echo "Subject: Buildstatus $RELEASE" ; \
echo "Message-ID: <fwbuild.$(date +%s)@$(uname -n)>"; \
echo "MIME-Version: 1.0"; \
echo ; \
echo "Ein Firmwarebuild wurde beendet, ${NumImg} Factory-Images erstellt." ; \
echo ; \
echo "Laufzeit: ${BUILDMINS} Minuten (${USEnCORES}/${AVAILCORES} CPU-Kern(e))." ; \
echo ; \
cat /tmp/build-${RELEASE}.txt ; \
echo ; \
cat build_tmp/build-${RELEASE}.log) | /usr/sbin/sendmail "wusel@uu.org" #replies+fw-buildlog@forum.freifunk-kreisgt.de

NumImg=$(ls -lh output/images/factory/ 2>/dev/null | grep gluon- | wc -l)
if [ ${NumImg} -gt 0 ]; then
    echo -ni "" >output/images/factory/ffgt-firmware-buildinfo-${RELEASE}
    echo "Release: ${RELEASE}" >>output/images/factory/ffgt-firmware-buildinfo-${RELEASE}
    echo "PACKAGES_FFGT_PACKAGES_COMMIT=${FFGTPKGCOMMIT}" >>output/images/factory/ffgt-firmware-buildinfo-${RELEASE}
    if [ "$PKGLIVECOMMIT" != "${FFGTPKGCOMMIT}" ]; then
        echo "WARN_PACKAGES_FFGT_PACKAGES: commit used to build: ${FFGTPKGCOMMIT} / commit expected: ${PKGLIVECOMMIT}" >>output/images/factory/ffgt-firmware-buildinfo-${RELEASE}
    fi
    echo "FFGT_SITE_COMMIT=${FFGTSITECOMMIT}" >>output/images/factory/ffgt-firmware-buildinfo-${RELEASE}
    echo "GLUON_BASE_COMMIT=${GLUONBASECOMMIT}" >>output/images/factory/ffgt-firmware-buildinfo-${RELEASE}
    echo "Buildslave: ${NODE_NAME:-`uname -n`}" >>output/images/factory/ffgt-firmware-buildinfo-${RELEASE}
    echo "Buildjob: ${JOB_URL:-$$}" >>output/images/factory/ffgt-firmware-buildinfo-${RELEASE}
    echo "Buildtime: ${BUILDMINS} minutes @ ${USEnCORES} core(s)" | tee --append output/images/factory/ffgt-firmware-buildinfo-${RELEASE}
    #echo $RELEASE >/tmp/build-2023.1-release.txt

    sed -e "s%@@RELEASE@@%${RELEASE}%g" <ReleaseNotes >output/images/factory/ReleaseNotes-${RELEASE}
    cat output/images/factory/ffgt-firmware-buildinfo-${RELEASE} >>output/images/factory/ReleaseNotes-${RELEASE}

    export RELEASE
    (echo "From: technik@guetersloh.freifunk.net (FFGT Technik)" ; \
     echo "To: replies+fw-buildlog@forum.freifunk-kreisgt.de" ; \
     echo "Content-Type: text/plain; charset=utf-8" ; \
     echo "Subject: Neuer Firmwarebuild - $RELEASE - fertig" ; \
     echo ; \
     echo "Unsere Firmware-Seite [1] wird sich binnen 15 Minuten aktualisieren." ; \
     echo ; \
     cat build_tmp/build-${RELEASE}.log ; \
     echo ; \
     echo "*Erstellte sysupgrade-Firmwares:*" ; \
     echo "<pre>" ; \
     ls -lh output/images/sysupgrade/ | grep gluon- ; \
     echo "</pre>" ; \
     echo ; \
     echo "Laufzeit: ${BUILDMINS} Minuten (${USEnCORES}/${AVAILCORES} CPU-Kern(e))." ; \
     echo ; \
     echo "[1] http://firmware.4830.org/") | /usr/sbin/sendmail wusel@uu.org #replies+fw-buildlog@forum.freifunk-kreisgt.de

    if [ -e ${MYBUILDROOT}/secret-build ]; then
      gluon-build/contrib/sign.sh ${MYBUILDROOT}/secret-build output/images/sysupgrade/tng.manifest 
      gluon-build/contrib/sign.sh ${MYBUILDROOT}/secret-build output/images/sysupgrade/rawhide.manifest 
      gluon-build/contrib/sign.sh ${MYBUILDROOT}/secret-build output/images/sysupgrade/experimental.manifest
      gluon-build/contrib/sign.sh ${MYBUILDROOT}/secret-build output/images/sysupgrade/testing.manifest
      gluon-build/contrib/sign.sh ${MYBUILDROOT}/secret-build output/images/sysupgrade/stable.manifest
      gluon-build/contrib/sign.sh ${MYBUILDROOT}/secret-build output/images/sysupgrade/master.manifest
    fi  
    
    cp -p output/images/sysupgrade/rawhide.manifest output/images/sysupgrade/rawhide.manifest-$RELEASE
    cp -p output/images/sysupgrade/master.manifest output/images/sysupgrade/master.manifest-$RELEASE
    cp -p output/images/sysupgrade/tng.manifest output/images/sysupgrade/tng.manifest-$RELEASE
    mv output/images/sysupgrade/experimental.manifest output/images/sysupgrade/experimental.manifest-$RELEASE
    mv output/images/sysupgrade/testing.manifest output/images/sysupgrade/testing.manifest-$RELEASE
    mv output/images/sysupgrade/stable.manifest output/images/sysupgrade/stable.manifest-$RELEASE

    chmod g+w output/images/factory output/images/sysupgrade
    rsync -av --progress output/packages/ 192.251.226.116:/firmware/packages/
    rsync -av --progress output/images/ 192.251.226.116:/firmware/tng/
    #rsync -av --omit-dir-times output/images/* /firmware/rawhide/
    #rsync -av --omit-dir-times output/packages /firmware/
fi

cd "${BASEPATH}"
MYBUILDNBR="`cat buildnumber.txt`"
MYBUILDNBR="`expr ${MYBUILDNBR} + 1`"
echo "${MYBUILDNBR}" >buildnumber.txt
