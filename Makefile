# keel-redis: Redis, and nothing that serves a web page.
# Compatible with TurnKey Linux appliances: this is the database half of
# turnkeylinux-apps/redis, built as a layer on core so that any appliance
# that needs Redis is built on it instead of installing its own.
#
#     git clone --branch v1.0.4 \
#         https://github.com/keel-linux/unit-redis.git unit.d/redis
#     bt-layer redis --parent core
#
# What it deliberately leaves out, and why, is in README.rst: Redis Commander
# needs a web server and a Node.js runtime, and which of each differs by
# context, so it arrives with a web stack, not with the database.
#
# The server is the unit.d/redis component (keel-linux/unit-redis), which fab
# resolves and applies on its own and bt-layer records in the layer manifest
# as "units redis@<version>", so a layer built on this one applies it once
# and a layer built on that one does not apply it again. Decision 0013 is
# why: a database is a component, not a parent layer.

# The recipe's own overlay reaches the tree twice, here and again as
# ROOT_OVERLAY after the units, so a file of this overlay still wins over a
# file of the component. No path is in both today, and tests/unit.bats of
# unit-redis lists what the component ships.
COMMON_OVERLAYS += $(CURDIR)/overlay

# Webmin comes from core and answers on 12321. Nothing here serves a web
# page, so 80 and 443 stay shut: 6379 is Redis, 12321 the panel, 12320 the
# web shell core carries.
#
# 6379 is open in the firewall and the server listens on loopback only
# (unit-redis, 10-keel-bind.conf), which is deliberate and is the same
# arrangement keel-mariadb ships: the port an operator would have to open to
# use the console's cloud modes is not also a second thing to remember, and
# nothing answers on it until the bind list says so.
WEBMIN_FW_TCP_INCOMING = 22 6379 12320 12321

include $(FAB_PATH)/common/mk/turnkey.mk

# The project's own packages (inithooks, confconsole, keel) come from the
# Keel archive, archive.keellinux.org, like every other Keel package: the
# parent layer carries its source and the 990 pin (common's
# overlays/turnkey.d/keel-apt, Keel-Linux/common#30), and a build with
# KEEL_APT_TRACK=testing reads trixie-testing as well (common#32). There is
# no build time archive any more. The build host's staging distribution held
# versions far older than the archive's, and pinned at 1001 it would have
# downgraded the layer to them.
#
# conf.d/main upgrades the three and then proves, with bin/keel-project-
# packages, that each is installed at apt's candidate and that the candidate
# is the Keel archive's, in the suite of the track. The check runs inside the
# tree while its apt lists are still there, so it is copied in before the
# conf scripts run and conf.d/main removes it again.
KEEL_BUILD_TOOLS ?= /usr/local/lib/keel-build
define _keel_root.patched/pre

	install -D -m 755 $(CURDIR)/bin/keel-project-packages $O/root.patched$(KEEL_BUILD_TOOLS)/keel-project-packages;
endef
root.patched/pre += $(_keel_root.patched/pre)
