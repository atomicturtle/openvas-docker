FROM docker.io/rockylinux/rockylinux:10

LABEL maintainer="Support <support@atomicorp.com>"
LABEL description="Self-contained Greenbone Vulnerability Management (GVM) Scanner on Rocky Linux 10"

# Expose Web Interface (HTTPS default 443, GSAD default 9392)
EXPOSE 443 9392

# Data volumes for database, feeds, and plugins
VOLUME ["/var/lib/gvm", "/var/lib/openvas", "/var/lib/pgsql"]

# Install dependencies, EPEL, CRB, Atomicorp repository, and GVM suite
RUN dnf install -y --enablerepo=crb epel-release wget procps-ng sudo && \
    /usr/bin/crb enable && \
    NON_INT=1 wget -q -O - https://updates.atomicorp.com/installers/atomic | sh && \
    dnf install -y --enablerepo=atomic-testing gvm && \
    dnf install -y --enablerepo=atomic-testing gvm-tools python3-gvm 2>/dev/null || true && \
    dnf clean all && \
    rm -rf /var/cache/dnf/* /tmp/* /var/tmp/*

# Add entrypoint startup script
COPY run.sh /run.sh
RUN chmod 755 /run.sh

ENTRYPOINT ["/run.sh"]
