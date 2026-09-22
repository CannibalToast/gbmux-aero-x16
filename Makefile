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
	install -Dm644 gbmux-acpower.conf $(DESTDIR)/etc/gbmux-acpower.conf
	install -Dm644 README.md $(DESTDIR)$(PREFIX)/share/doc/gbmux/README.md
	install -Dm644 apparmor/usr.sbin.gbmux $(DESTDIR)$(PREFIX)/share/doc/gbmux/apparmor/usr.sbin.gbmux
	install -Dm644 examples/gbmux.sudoers $(DESTDIR)$(PREFIX)/share/doc/gbmux/examples/gbmux.sudoers
ifndef DESTDIR
	udevadm control --reload || true
	systemctl daemon-reload || true
	if [ -d /sys/bus/wmi/devices ] && ls -d /sys/bus/wmi/devices/ABBC0F75-* >/dev/null 2>&1; then \
		systemctl enable gbmux-acpower.service || true; \
	else \
		echo "gbmux: Gigabyte WMI GUID ABBC0F75 not present — not enabling gbmux-acpower.service"; \
	fi
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
	install -m644 debian/conffiles $(PKG)/DEBIAN/
	install -m755 debian/postinst debian/prerm $(PKG)/DEBIAN/
	dpkg-deb --root-owner-group --build $(PKG)

test:
	bash tests/run.sh

.PHONY: install uninstall deb test
