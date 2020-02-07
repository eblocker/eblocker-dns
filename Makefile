DNS_HOME = $(DESTDIR)/opt/eblocker-dns
INITD = $(DESTDIR)/etc/init.d
LOGROTATED = $(DESTDIR)/etc/logrotate.d
LIMITSD = $(DESTDIR)/etc/security/limits.d

build:
	bundle package --all

install:
	mkdir -p $(INITD)
	cp etc/init.d/eblocker-dns $(INITD)
	mkdir -p $(LIMITSD)
	cp etc/security/limits.d/eblocker-dns.conf $(LIMITSD)
	mkdir -p $(LOGROTATED)
	cp etc/logrotate.d/eblocker-dns $(LOGROTATED)
	mkdir -p $(DNS_HOME)
	cp -r .bundle $(DNS_HOME)
	cp -r bin  $(DNS_HOME)
	cp eblocker-dns.gemspec $(DNS_HOME)
	cp Gemfile $(DNS_HOME)
	cp Gemfile.lock $(DNS_HOME)
	cp -r lib $(DNS_HOME)
	mkdir -p $(DNS_HOME)/log
	cp -r README.md $(DNS_HOME)
	mkdir -p $(DNS_HOME)/run
	cp -r vendor $(DNS_HOME)

package:
	dpkg-buildpackage -us -uc
