PREFIX ?= /usr
VERSION := 1.0-1
PKG := pkg/gbmux_$(VERSION)_all

install:
	install -Dm755 gbmux $(DESTDIR)$(PREFIX)/sbin/gbmux
	install -Dm755 gbmux-setup $(DESTDIR)$(PREFIX)/sbin/gbmux-setup
	install -Dm755 gbmux-acpower $(DESTDIR)$(PREFIX)/lib/gbmux/gbmux-acpower
	install -Dm644 99-gbmux-acpower.rules $(DESTDIR)/etc/udev/rules.d/99-gbmux-acpower.rules
	install -Dm644 gbmux-acpower.service $(DESTDIR)/lib/systemd/system/gbmux-acpower.service
	install -Dm644 gbmux-nouveau.conf $(DESTDIR)/etc/modprobe.d/gbmux-nouveau.conf
	install -Dm644 README.md $(DESTDIR)$(PREFIX)/share/doc/gbmux/README.md
ifndef DESTDIR
	udevadm control --reload || true
	systemctl daemon-reload || true
	systemctl enable gbmux-acpower.service || true
endif

uninstall:
	systemctl disable --now gbmux-acpower.service || true
	rm -f $(DESTDIR)$(PREFIX)/sbin/gbmux $(DESTDIR)$(PREFIX)/sbin/gbmux-setup \
	      $(DESTDIR)$(PREFIX)/lib/gbmux/gbmux-acpower \
	      $(DESTDIR)/etc/udev/rules.d/99-gbmux-acpower.rules \
	      $(DESTDIR)/lib/systemd/system/gbmux-acpower.service \
	      $(DESTDIR)/etc/modprobe.d/gbmux-nouveau.conf
	rm -rf $(DESTDIR)$(PREFIX)/share/doc/gbmux $(DESTDIR)$(PREFIX)/lib/gbmux
ifndef DESTDIR
	udevadm control --reload || true
	systemctl daemon-reload || true
endif

deb:
	rm -rf $(PKG)
	$(MAKE) install DESTDIR=$(PKG) PREFIX=/usr
	mkdir -p $(PKG)/DEBIAN
	install -m644 debian/control $(PKG)/DEBIAN/
	install -m755 debian/postinst debian/prerm $(PKG)/DEBIAN/
	dpkg-deb --root-owner-group --build $(PKG)

.PHONY: install uninstall deb
