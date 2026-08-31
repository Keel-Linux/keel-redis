Redis - Open Source, In-memory Data Structure Store
===================================================

`Redis`_ is an in-memory database, cache and message broker. It supports
strings, hashes, lists, sets, sorted sets, streams and other data structures.
Redis also provides replication, scripting, transactions, on-disk persistence,
high availability through `Redis Sentinel`_ and partitioning through
`Redis Cluster`_. Sentinel requires the optional Debian `redis-sentinel`_
package.

This appliance includes all the standard features in `TurnKey Core`_,
and on top of that:

- Redis configuration:

    - Redis Server and its command-line tools come from Debian Trixie and use
      normal APT security updates.
    - First boot generates a strong Redis password. View it from Confconsole or
      run ``turnkey-redis-pw get`` as root.
    - First boot lets you keep Redis on localhost, bind all interfaces or enter
      a local address. Remote deployments should restrict TCP port 6379 to
      trusted clients with the firewall.
    - Debian's default RDB persistence remains enabled.

    - Includes the `Redis Commander`_ browser interface at
      ``https://<appliance>/redis-commander/``.

- HTTPS protects the landing page and Redis Commander management interface.
- Postfix MTA (bound to localhost) to allow sending of email from web
  applications.

Supervised Redis Commander update
---------------------------------

Always ensure that you have a current and tested backup before performing an
upgrade. Test the update on a development server before updating production.::

    su - node -c "cd /opt/tklweb-cp && npm install redis-commander@latest"
    systemctl restart pm2-node

The npm lock file records registry integrity hashes. Redis Server itself is
updated through APT.

Credentials *(passwords set at first boot)*
-------------------------------------------

- Webmin, SSH: username **root**
- Redis Commander: username **admin**

.. _Redis: https://redis.io/docs/latest/
.. _Redis Sentinel: https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/
.. _redis-sentinel: https://packages.debian.org/trixie/redis-sentinel
.. _Redis Cluster: https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/
.. _TurnKey Core: https://www.turnkeylinux.org/core
.. _Redis Commander: https://github.com/joeferner/redis-commander
