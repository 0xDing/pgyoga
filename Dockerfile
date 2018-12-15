FROM python:3.7.1-slim-stretch

# https://github.com/tianon/gosu/releases
ENV GOSU_VERSION 1.11
ENV PG_VERSION 11.1
ENV PGYOGA_VERSION 0.1
ENV PG_SHA256 90815e812874831e9a4bf6e1136bf73bc2c5a0464ef142e2dfea40cda206db08
RUN set -ex; \
    echo "deb http://deb.debian.org/debian stretch-backports main" >> /etc/apt/sources.list; \
    apt-get update; apt-get upgrade -y; \
	apt-get install -y --no-install-recommends \
			gnupg \
			dirmngr \
			lbzip2 \
			dpkg-dev

# explicitly set user/group IDs
RUN set -eux; \
	groupadd -r postgres --gid=999; \
# https://salsa.debian.org/postgresql/postgresql-common/blob/997d842ee744687d99a2b2d95c1083a2615c79e8/debian/postgresql-common.postinst#L32-35
	useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
# also create the postgres user's home directory with appropriate permissions
# see https://github.com/docker-library/postgres/issues/274
	mkdir -p /var/lib/postgresql; \
	chown -R postgres:postgres /var/lib/postgresql

# grab gosu for easy step-down from root
RUN set -x \
	&& apt-get install -y --no-install-recommends ca-certificates wget netbase \
	&& wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$(dpkg --print-architecture)" \
	&& wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$(dpkg --print-architecture).asc" \
	&& export GNUPGHOME="$(mktemp -d)" \
	&& gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 \
	&& gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu \
	&& { command -v gpgconf > /dev/null && gpgconf --kill all || :; } \
	&& rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc \
	&& chmod +x /usr/local/bin/gosu \
	&& gosu nobody true

# make the "en_US.UTF-8" locale so postgres will be utf-8 enabled by default
RUN set -eux; \
	if [ -f /etc/dpkg/dpkg.cfg.d/docker ]; then \
# if this file exists, we're likely in "debian:xxx-slim", and locales are thus being excluded so we need to remove that exclusion (since we need locales)
		grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
		sed -ri '/\/usr\/share\/locale/d' /etc/dpkg/dpkg.cfg.d/docker; \
		! grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
	fi; \
	apt-get install -y locales; \
	localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG en_US.utf8

# install "nss_wrapper" in case we need to fake "/etc/passwd" and "/etc/group" (especially for OpenShift)
# https://github.com/docker-library/postgres/issues/359
# https://cwrap.org/nss_wrapper.html
RUN set -eux; \
	apt-get install -y --no-install-recommends libnss-wrapper

RUN mkdir /docker-entrypoint-initdb.d

RUN set -ex; \
    apt-get install -y \
    pkg-config \
    llvm-6.0 \
    clang-6.0 \
    libicu-dev \
    libreadline-dev \
    zlib1g-dev \
    libssl-dev \
    libxml2-dev \
    libxslt1-dev \
    libipc-run-perl \
    libldap2-dev \
    gcc \

	&& wget -O postgresql.tar.bz2 "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2" \
    	&& echo "$PG_SHA256 *postgresql.tar.bz2" | sha256sum -c - \
    	&& mkdir -p /usr/src/postgresql \
    	&& tar \
    		--extract \
    		--file postgresql.tar.bz2 \
    		--directory /usr/src/postgresql \
    		--strip-components 1 \
    	&& rm postgresql.tar.bz2 \
    	&& cd /usr/src/postgresql \
    # update "DEFAULT_PGSOCKET_DIR" to "/var/run/postgresql" (matching Debian)
    # see https://anonscm.debian.org/git/pkg-postgresql/postgresql.git/tree/debian/patches/51-default-sockets-in-var.patch?id=8b539fcb3e093a521c095e70bdfa76887217b89f
    	&& awk '$1 == "#define" && $2 == "DEFAULT_PGSOCKET_DIR" && $3 == "\"/tmp\"" { $3 = "\"/var/run/postgresql\""; print; next } { print }' src/include/pg_config_manual.h > src/include/pg_config_manual.h.new \
    	&& grep '/var/run/postgresql' src/include/pg_config_manual.h.new \
    	&& mv src/include/pg_config_manual.h.new src/include/pg_config_manual.h \
    	&& gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
    # explicitly update autoconf config.guess and config.sub so they support more arches/libcs
    	&& wget -O config/config.guess 'https://git.savannah.gnu.org/cgit/config.git/plain/config.guess?id=7d3d27baf8107b630586c962c057e22149653deb' \
    	&& wget -O config/config.sub 'https://git.savannah.gnu.org/cgit/config.git/plain/config.sub?id=7d3d27baf8107b630586c962c057e22149653deb' \
    # configure options taken from:
    # https://anonscm.debian.org/cgit/pkg-postgresql/postgresql.git/tree/debian/rules?h=9.5
    	&& ./configure \
    		--build="$gnuArch" \
    		--with-extra-version="pgyoga-$PGYOGA_VERSION" \
    		--with-llvm \
    		--with-segsize=4 \
    # https://github.com/greenplum-db/gpdb/blob/bd9ddf388d15f57fef948b4a7d1ce374e0e67e64/configure.in
    	    --with-blocksize=32 \
    		--with-wal-blocksize=32 \
    # "/usr/src/postgresql/src/backend/access/common/tupconvert.c:105: undefined reference to `libintl_gettext'"
    #		--enable-nls \
    		--enable-integer-datetimes \
    		--enable-thread-safety \
    		--enable-tap-tests \
    # skip debugging info -- we want tiny size instead
    #		--enable-debug \
    		--disable-rpath \
    		--with-uuid=ossp \
    		--with-gnu-ld \
    		--with-pgport=15432 \
    		--with-system-tzdata=/usr/share/zoneinfo \
    		--prefix=/usr/local \
    		--with-includes=/usr/local/include \
    		--with-libraries=/usr/local/lib \
    # these make our image abnormally large (at least 100MB larger), which seems uncouth for an "Alpine" (ie, "small") variant :)
    #		--with-krb5 \
    #		--with-gssapi \
    		--with-ldap \
    #		--with-tcl \
    #		--with-perl \
    		--with-python \
    #		--with-pam \
    		--with-openssl \
    		--with-libxml \
    		--with-libxslt \
    		--with-icu \
    	&& make -j "$(nproc)" world \
    	&& make install-world \
    	&& make -C contrib install \
    	\
    	&& cd / \
    	&& rm -rf \
    		/usr/src/postgresql \
    		/usr/local/share/doc \
    		/usr/local/share/man \
    	&& find /usr/local -name '*.a' -delete

# make the sample config easier to munge (and "correct by default")
RUN sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/local/share/postgresql/postgresql.conf.sample

RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql && chmod 2777 /var/run/postgresql

ENV PGDATA /var/lib/postgresql/data
RUN mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 777 "$PGDATA" # this 777 will be replaced by 700 at runtime (allows semi-arbitrary "--user" values)
VOLUME /var/lib/postgresql/data

COPY docker-entrypoint.sh /usr/local/bin/
RUN ln -s usr/local/bin/docker-entrypoint.sh / # backwards compat
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 15432
CMD ["postgres"]
