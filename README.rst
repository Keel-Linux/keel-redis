keel-redis
==========

Redis database layer for Keel appliances, built on ``core``. Compatible with
TurnKey Linux appliances, and corresponding to the upstream appliance
`turnkeylinux-apps/redis <https://github.com/turnkeylinux-apps/redis>`_ for
the database half of what that appliance is::

    git clone --branch v1.0.2 \
        https://github.com/keel-linux/unit-redis.git unit.d/redis
    bt-layer redis --parent core

The server comes from the ``unit.d/redis`` component: `keel-linux/unit-redis
<https://github.com/keel-linux/unit-redis>`_ carries its plan, its overlay
and its conf script, fab applies it, and ``bt-layer`` records it in the layer
manifest as ``units redis@1.0.2``. Materialising ``unit.d`` from the pin is
the assembly step decision 0010 names as work of the project and does not
exist yet, so the clone above is that step for now; ``unit.d/`` is ignored by
git here.

It is a layer, not a product: any appliance that needs Redis is built on it,
so the server is fetched, configured and measured once. Nothing is stopping
it being run on its own; it boots, it listens on loopback, and Webmin
administers the machine around it.

Redis is the third of the three engines decision 0013 settled on, and the one
where the topology modes are cheapest: replication is one directive,
``replicaof`` with ``masterauth``; failover has ``redis-sentinel``, packaged
beside the server; and sharding is native in Redis Cluster with no extra
package at all, where PostgreSQL has none packaged and MariaDB needs Spider.
**None of that is in this layer.** This is the standalone appliance, and the
modes come next, in their own issue, on the reading this layer makes
possible.

What is in it
-------------

======================================  ====================================
``Makefile``                            the component under ``unit.d``, this overlay, the firewall ports, the verified build time archive
``plan/main``                           the client and the project packages; the server is the component's plan
``conf.d/main``                         the checks on what the component did, and the project package upgrade
``conf.d/zz-project-packages``          what is installed, checked against the archive rather than against a literal version
``bin/keel-archive-check``              the copy of the project archive in the build tree, proved to be the live one and verified with gpgv
``keel/instance.example.yaml``          the instance description an operator starts from
``tests/``                              bats for the shell, ``boot-test.sh`` for the machine
======================================  ====================================

Webmin comes from ``core`` and answers on 12321. Debian 13 packages
``webmin-mysql`` and ``webmin-postgresql`` and **no equivalent for Redis**,
so unlike the other two database layers this one adds no module, and says so
in three places rather than leaving a silence: here, in ``conf.d/main``,
which fails the build the day one is packaged, and in the boot test, which
checks the machine offers none.

What the declared secret means here
-----------------------------------

An instance description declares the secret once::

    secrets:
      db_password:
        file: /etc/keel/secrets/db_password

It renders to ``DB_PASS``, the same variable the MariaDB and PostgreSQL
hooks read. On those engines it is a database account's password. **Redis has
no database account.** Its secret is one of two things, and the vocabulary of
decision 0013 leaves both open: ``requirepass``, which is the password of the
built in ``default`` user, or an ACL user with a password of its own.

This layer's component uses **an ACL user**, named ``admin``
(``app.options.db_user`` renames it), so a client authenticates with a user
name and that password::

    REDISCLI_AUTH=$(cat /etc/keel/secrets/db_password) \
        redis-cli -h ::1 -p 6379 --user admin PING

Two consequences an operator will meet, and both are the reason for the
choice rather than side effects of it:

- **The server answers ``INFO`` to anybody who can reach it, and no key to
  anybody without the secret.** ``keel inspect`` reads
  ``database.server.role`` from ``INFO replication`` and ``INFO cluster``,
  and it never reads a secret to get past a refusal. With ``requirepass``
  set, this appliance could not say that it is ``standalone``, and it could
  not later say that it is a ``primary`` or a ``replica`` either, which is
  the whole of what the next issue is built on. So ``default`` is left with
  exactly one command, ``INFO``, no key and no channel.
- **Nothing on the machine can print the secret back.** An ACL rule takes the
  SHA-256 of a password, so ``/etc/redis/redis.conf.d/50-keel-secret.conf``
  holds a digest, ``root:redis 0640``. The upstream appliance wrote
  ``requirepass`` into ``/etc/redis/redis.conf``, which the package ships
  ``root:root 0644``, and shipped ``turnkey-redis-pw get`` and a confconsole
  plugin to print it out again into ``/root/redis_password.txt``. Neither
  tool is here, because neither has anything to read.

Before the first boot **the account does not exist**. ``keel-mariadb``
publishes its account with a password hash no input produces; the same shape
was tried here and Redis refuses it, because a user may be declared only
once across configuration files. So the account is declared once, by the
first boot, or not at all, and the property that mattered holds either way:
a layer is published once and reused by every appliance built on it, so a
password chosen at build time would be the same password everywhere, and a
random one would make the layer irreproducible (brief section 5.4).

One Redis behaviour is worth knowing before reading any of the checks:
**redis-cli exits 0 when the server answers with an error.** A wrong password
prints ``AUTH failed: WRONGPASS ...`` and exits 0. Every check in the
component, in this recipe and in the boot test therefore reads the answer.

The addresses
-------------

The server listens on ``::1`` and ``127.0.0.1``, as literal addresses, and on
nothing else. Debian ships ``bind 127.0.0.1 -::1``, where the dash marks the
address as optional, so a server that cannot bind ``::1`` starts anyway and
answers one family. A name is never used: Debian maps ``::1`` to
``ip6-localhost`` and never to ``localhost``, which is how the PostgreSQL
appliance shipped listening on IPv4 only (docs/traps.md).

The port is not opened to the network. This layer exists to be built on, and
the appliance above it is on the same machine. An appliance that really has
remote clients opens the port, says who may connect and terminates TLS; that
is a decision an appliance makes, and the console's cloud modes are where it
will be made.

What it deliberately leaves out
-------------------------------

Upstream's ``redis`` appliance also bundles **Redis Commander** on nginx with
a Node.js runtime and pm2, a landing page served by them,
``turnkey-redis-pw`` and a confconsole plugin that writes the Redis password
to ``/root/redis_password.txt``. None of that is here.

Redis Commander needs a web server and a Node.js runtime, and which of each
differs by context. Putting them in the database layer forces a choice that
the layers above would have to undo and make again, which is the same
argument that keeps Adminer out of ``keel-mariadb``. So Redis Commander
arrives with a web stack, if the maintainer wants that artefact: it would be
a different one, built on this layer.

The two password tools go for a different reason: they read ``requirepass``
out of a configuration file, and this appliance's configuration holds a
digest. A tool that cannot work is worse than no tool, and the secret an
operator needs is the file their own instance description points at.

Also not here: ``redis-sentinel``, which Debian packages beside the server,
and Redis Cluster, which needs no package. Both are modes.

Valkey
------

Debian 13 also ships ``valkey-server 8.1.1``, the fork made after Redis
changed its licence, and it is recorded in decision 0013 as the ready escape
if Redis tightens further. Everything this layer does is Valkey's too: Valkey
8.1 keeps the ACL vocabulary, the ``include`` semantics, the ``bind`` syntax
and the ``INFO`` sections that ``keel inspect`` reads. What differs is names,
not behaviour: ``/etc/valkey/valkey.conf``, ``valkey-server.service``,
``valkey-cli``. So one unit could serve both, with a variable naming the
flavour, and ``keel`` would need ``valkey-server`` added beside
``redis-server`` in its engine table. That is a change with its own issue,
not a line smuggled into this one. ``unit-redis``'s README sizes it.

Tests
-----

``tests/README.md`` has the detail. In short: ``tests/coverage.sh`` runs the
bats suite under kcov and gates the shell this layer writes;
``tests/boot-test.sh`` assembles the published layer, boots it headless from
an instance description that declares ``secrets.db_password`` from a file,
authenticates over IPv6 with that secret, writes and reads a key, is refused
a key without the secret, checks Webmin over IPv6, reads the role back off
the server with ``keel inspect``, and runs ``keel diff``.

The first boot hook, its library and the component's conf script are measured
in ``keel-linux/unit-redis``, which is where they live.
