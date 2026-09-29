ARG BASE_IMAGE
FROM ${BASE_IMAGE}

USER root
RUN set -eu; \
    curl --fail --silent --show-error --location \
      https://truststore.pki.rds.amazonaws.com/us-east-1/us-east-1-bundle.pem \
      --output /tmp/us-east-1-bundle.pem; \
    awk ' \
      /-----BEGIN CERTIFICATE-----/ { count++; file = sprintf("/tmp/rds-ca-%03d.pem", count) } \
      file != "" { print > file } \
      /-----END CERTIFICATE-----/ { close(file); file = "" } \
      END { if (count == 0) exit 1 } \
    ' /tmp/us-east-1-bundle.pem; \
    for certificate in /tmp/rds-ca-*.pem; do \
      alias="${certificate##*/}"; \
      keytool -importcert -noprompt -trustcacerts \
        -alias "$alias" \
        -file "$certificate" \
        -keystore /app/rds-ca.p12 \
        -storetype PKCS12 \
        -storepass changeit; \
    done; \
    chown openboxes:openboxes /app/rds-ca.p12; \
    rm -f /tmp/us-east-1-bundle.pem /tmp/rds-ca-*.pem

USER openboxes
