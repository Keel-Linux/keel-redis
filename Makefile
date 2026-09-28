# keel-redis: Redis, and nothing that serves a web page.
# Compatible with TurnKey Linux appliances: this is the database half of
# turnkeylinux-apps/redis, built as a layer on core so that any appliance
# that needs Redis is built on it instead of installing its own.
#
#     git clone --branch v1.0.1 \
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
# build host's APT repository during the build only. The repository is copied
# into the bootstrap and the build verifies it there, the way an appliance
# verifies the release archive (tracker#7): the public half of the staging key
# is installed as a keyring, the source entry names it through signed-by,
# nothing in the tree says trusted=yes, and apt runs with --error-on=any, so a
# signature that cannot be checked fails the build instead of warning about it
# and carrying on. conf.d/zz-project-packages removes the copy of the archive,
# the source entry and the keyring from the image and leaves the future
# apt.keellinux.org entry in place, disabled.
#
# None of the three build time files is for an installed appliance, because
# the staging key signs whatever the build host produced. The removelist at
# common/removelists-final/turnkey takes all three out of the image as well,
# whatever a recipe does.
#
# This block is the fifth copy of itself, which is what tracker#8 is for: it
# belongs in keel-linux/common as mk/keel/staging-archive.mk plus
# bin/keel-archive-check, next to the removelist that already undoes it for
# every recipe at once. Until then the pattern is maintained in keel-mariadb
# and copied here unchanged, and the staging key's fingerprint is written
# down in one Makefile more.
KEEL_APT_REPO ?= /srv/keel-apt/repo
KEEL_APT_DIST ?= trixie-staging
# Beside the repository rather than inside it: bin/publish of keel-linux/apt
# installs the public half of whichever key it signed a distribution with
# here, so the key a build verifies with cannot drift from the key the archive
# was signed with.
KEEL_APT_KEYRING ?= /srv/keel-apt/keys/keel-staging-keyring.asc
# Where that key goes in the build tree, and which key has to be in it: the
# staging signing subkey (handbook decision 0011). A keyring is only a promise
# until the key inside it is named, so bin/keel-archive-check fails the build
# when the keyring it finds holds some other key.
KEEL_APT_KEYRING_PATH ?= /etc/apt/keyrings/keel-staging-keyring.asc
KEEL_APT_KEY ?= 8CFD1A4841448B2227341CEB202CACBD0E97090A
KEEL_STAGING_LIST ?= /etc/apt/sources.list.d/keel-staging.list
KEEL_ARCHIVE_CHECK = KEEL_ARCHIVE_KEY=$(KEEL_APT_KEY) \
	KEEL_ARCHIVE_KEYRING=$(KEEL_APT_KEYRING_PATH) \
	KEEL_ARCHIVE_LIST=$(KEEL_STAGING_LIST) \
	$(CURDIR)/bin/keel-archive-check $(KEEL_APT_REPO)

# The copy is made fresh and then proved: bin/keel-archive-check compares the
# copied package index with the live one, verifies the signature on the copied
# InRelease against the keyring, refuses any trusted=yes, and stops the build
# when one of them is wrong.
define _keel_bootstrap/post

	mkdir -p $O/bootstrap/srv/keel-apt/repo $O/bootstrap$(dir $(KEEL_APT_KEYRING_PATH));
	rm -rf $O/bootstrap/srv/keel-apt/repo/dists $O/bootstrap/srv/keel-apt/repo/pool;
	cp -a $(KEEL_APT_REPO)/dists $(KEEL_APT_REPO)/pool $O/bootstrap/srv/keel-apt/repo/;
	install -m 644 $(KEEL_APT_KEYRING) $O/bootstrap$(KEEL_APT_KEYRING_PATH);
	echo "deb [signed-by=$(KEEL_APT_KEYRING_PATH)] file:///srv/keel-apt/repo $(KEEL_APT_DIST) main" > $O/bootstrap$(KEEL_STAGING_LIST);
	$(KEEL_ARCHIVE_CHECK) $O/bootstrap $(KEEL_APT_DIST) $(FAB_ARCH) bootstrap;
	fab-chroot $O/bootstrap "apt-get update --error-on=any";
endef
bootstrap/post += $(_keel_bootstrap/post)

# bootstrap is a stamped target, so a second build of the same product reuses
# the copy the first one made and a check in bootstrap/post does not run at
# all. On 2026-09-26 "make clean" failed on a busy deck, the stamps survived,
# and the rebuild installed the packages the archive had held that morning
# without a word. So the tree that is about to be configured is checked on
# every build, whether or not this build made the bootstrap. That check
# verifies the signature with gpgv too, which is what proves this tree at a
# step where no apt-get update runs.
define _keel_root.patched/pre

	$(KEEL_ARCHIVE_CHECK) $O/root.patched $(KEEL_APT_DIST) $(FAB_ARCH) root.patched;
endef
root.patched/pre += $(_keel_root.patched/pre)
