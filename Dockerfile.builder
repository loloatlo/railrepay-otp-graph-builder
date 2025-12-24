FROM eclipse-temurin:21-jdk-alpine

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    python3 \
    jq \
    coreutils

# Install gcloud CLI
RUN curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts --install-dir=/opt
ENV PATH="/opt/google-cloud-sdk/bin:${PATH}"

# Download OTP JAR
ARG OTP_VERSION=2.6.0
RUN curl -sSL "https://repo1.maven.org/maven2/org/opentripplanner/otp/${OTP_VERSION}/otp-${OTP_VERSION}-shaded.jar" \
    -o /opt/otp.jar

# Copy build scripts
COPY extract-service-date.py /opt/
COPY build-graph.sh /opt/
COPY validate-graph.sh /opt/
COPY config/ /opt/config/
RUN chmod +x /opt/*.sh /opt/*.py

# Create directories
RUN mkdir -p /var/otp/graphs/default /var/otp/build

WORKDIR /var/otp

ENTRYPOINT ["/opt/build-graph.sh"]
